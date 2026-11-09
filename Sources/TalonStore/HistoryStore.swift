import Foundation
import GRDB
import Synchronization
import TalonCore
import TalonModel

/// Tiered history in SQLite, owned by talond alone.
///
/// | table     | resolution | content                         | kept     |
/// |-----------|------------|---------------------------------|----------|
/// | sys_10s   | 10 s       | avg per system series           | 7 days   |
/// | sys_1m    | 1 min      | min / avg / max per series      | 90 days  |
/// | sys_1h    | 1 h        | min / avg / max per series      | forever  |
/// | app_1m    | 1 min      | top apps + "other"              | 30 days  |
/// | app_1h    | 1 h        | top apps + "other"              | forever  |
/// | event     | —          | caps, freezes, kills, pressure  | forever  |
///
/// The last hour at 1 s lives only in daemon RAM. Values are integer-scaled (see
/// `SystemSeries.storageScale`), tables append at the right edge of one B-tree, there are no
/// secondary indexes, and the daemon commits at most once a minute — so a tool meant to protect
/// the SSD writes tens of MB a day, not GB.
public final class HistoryStore: Sendable {
    public struct Retention: Sendable {
        public var tenSeconds: TimeInterval = 7 * 86_400
        public var minute: TimeInterval = 90 * 86_400
        public var appMinute: TimeInterval = 30 * 86_400
        public init() {}
    }

    private let writer: any DatabaseWriter
    public let path: String?
    public let retention: Retention
    private let appIDs = Mutex<[String: Int64]>([:])

    /// A file-backed store (WAL, synchronous=NORMAL). Creates the directory if needed.
    public convenience init(path: String, retention: Retention = Retention()) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var config = Configuration()
        config.label = "talon.history"
        config.prepareDatabase { db in
            try db.execute(sql: """
                PRAGMA synchronous = NORMAL;
                PRAGMA journal_size_limit = 8388608;
                PRAGMA temp_store = MEMORY;
                """)
        }
        try self.init(writer: DatabasePool(path: path, configuration: config), path: path, retention: retention)
    }

    /// An in-memory store, for tests.
    public static func inMemory(retention: Retention = Retention()) throws -> HistoryStore {
        try HistoryStore(writer: DatabaseQueue(), path: nil, retention: retention)
    }

    private init(writer: any DatabaseWriter, path: String?, retention: Retention) throws {
        self.writer = writer
        self.path = path
        self.retention = retention
        try Self.migrator.migrate(writer)
        try writer.write { try Self.ensureSeriesColumns($0) }
    }

    // MARK: - Schema

    static func column(_ s: SystemSeries) -> String {
        s.rawValue.reduce(into: "") { out, c in
            if c.isUppercase { out += "_" + c.lowercased() } else { out.append(c) }
        }
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE app (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, name TEXT NOT NULL);
                CREATE TABLE sys_10s (ts INTEGER PRIMARY KEY);
                CREATE TABLE sys_1m (ts INTEGER PRIMARY KEY, n INTEGER NOT NULL);
                CREATE TABLE sys_1h (ts INTEGER PRIMARY KEY, n INTEGER NOT NULL);
                CREATE TABLE app_1m (ts INTEGER NOT NULL, app_id INTEGER NOT NULL, n INTEGER NOT NULL,
                    mem_avg INTEGER, mem_max INTEGER, cpu_ms INTEGER NOT NULL, written_kib INTEGER NOT NULL,
                    PRIMARY KEY (ts, app_id)) WITHOUT ROWID;
                CREATE TABLE app_1h (ts INTEGER NOT NULL, app_id INTEGER NOT NULL, n INTEGER NOT NULL,
                    mem_avg INTEGER, mem_max INTEGER, cpu_ms INTEGER NOT NULL, written_kib INTEGER NOT NULL,
                    PRIMARY KEY (ts, app_id)) WITHOUT ROWID;
                CREATE TABLE event (id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, kind TEXT NOT NULL,
                    pid INTEGER, app_key TEXT, message TEXT NOT NULL);
                """)
        }
        m.registerMigration("v2-ceilings") { db in
            try db.execute(sql: "CREATE TABLE ceiling (id TEXT PRIMARY KEY, body BLOB NOT NULL)")
        }
        m.registerMigration("v3-health") { db in
            try db.execute(sql: "CREATE TABLE health_daily (day TEXT PRIMARY KEY, body BLOB NOT NULL)")
        }
        return m
    }

    // MARK: - Daily health

    /// One row per day; refreshing the same day overwrites it, so the row holds that day's last reading.
    public func record(_ h: HealthDay) throws {
        let body = try JSONEncoder().encode(h)
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO health_daily (day, body) VALUES (?, ?)", arguments: [h.day, body])
        }
    }

    public func healthDays(limit: Int) throws -> [HealthDay] {
        try writer.read { db in
            try Data.fetchAll(db, sql: "SELECT body FROM health_daily ORDER BY day DESC LIMIT ?", arguments: [limit])
                .compactMap { try? JSONDecoder().decode(HealthDay.self, from: $0) }
        }.reversed()
    }

    // MARK: - Per-app history

    /// One app's buckets: averages for memory, CPU and write rate per bucket, plus the memory peak.
    public func appHistory(key: String, from: TimeInterval, to: TimeInterval, hourly: Bool) throws -> [AppPoint] {
        let table = hourly ? "app_1h" : "app_1m"
        let period: Double = hourly ? 3600 : 60
        return try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.ts, t.mem_avg, t.mem_max, t.cpu_ms, t.written_kib FROM \(table) t JOIN app a ON a.id = t.app_id
                WHERE a.key = ? AND t.ts >= ? AND t.ts <= ? ORDER BY t.ts
                """, arguments: [key, Int64(from), Int64(to)]).map { r in
                AppPoint(time: TimeInterval(r[0] as Int64), memoryAverage: Double(r[1] as Int64? ?? 0) * 1024,
                         memoryPeak: Double(r[2] as Int64? ?? 0) * 1024,
                         cpuPercent: Double(r[3] as Int64) / 1000 / period * 100,
                         writeRate: Double(r[4] as Int64) * 1024 / period)
            }
        }
    }

    // MARK: - Ceilings

    public func loadCeilings() throws -> [Ceiling] {
        try writer.read { db in
            try Data.fetchAll(db, sql: "SELECT body FROM ceiling").compactMap { try? JSONDecoder().decode(Ceiling.self, from: $0) }
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ c: Ceiling) throws {
        let body = try JSONEncoder().encode(c)
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO ceiling (id, body) VALUES (?, ?)", arguments: [c.id.uuidString, body])
        }
    }

    public func deleteCeiling(_ id: UUID) throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM ceiling WHERE id = ?", arguments: [id.uuidString]) }
    }

    /// System series are columns. New `SystemSeries` cases get their columns added here, so the
    /// enum is the single source of truth and old databases upgrade in place.
    private static func ensureSeriesColumns(_ db: Database) throws {
        for (table, suffixes) in [("sys_10s", [""]), ("sys_1m", ["_min", "_avg", "_max"]), ("sys_1h", ["_min", "_avg", "_max"])] {
            let existing = Set(try db.columns(in: table).map(\.name))
            for s in SystemSeries.allCases {
                for suffix in suffixes where !existing.contains(column(s) + suffix) {
                    try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column(s) + suffix) INTEGER")
                }
            }
        }
    }

    // MARK: - Writing

    private static func scaled(_ v: Double, _ s: SystemSeries) -> Int64? {
        v.isFinite ? Int64((v * s.storageScale).rounded()) : nil
    }

    private static func unscaled(_ v: Int64?, _ s: SystemSeries) -> Double {
        v.map { Double($0) / s.storageScale } ?? .nan
    }

    /// Everything one flush produces, in one transaction. Buckets that already exist (a daemon
    /// restart mid-bucket) are merged, not replaced.
    public func write(tenSeconds: [SystemBucket], minutes: [SystemBucket], hours: [SystemBucket],
                      appMinutes: [AppBucket], appHours: [AppBucket]) throws {
        guard !(tenSeconds.isEmpty && minutes.isEmpty && hours.isEmpty && appMinutes.isEmpty && appHours.isEmpty) else { return }
        try writer.write { db in
            if !tenSeconds.isEmpty {
                let cols = SystemSeries.allCases.map(Self.column)
                let stmt = try db.cachedStatement(sql: "INSERT OR REPLACE INTO sys_10s (ts, \(cols.joined(separator: ", "))) VALUES (?\(String(repeating: ", ?", count: cols.count)))")
                for b in tenSeconds {
                    var args: [(any DatabaseValueConvertible)?] = [Int64(b.start)]
                    for s in SystemSeries.allCases { args.append(Self.scaled(b[s].avg, s)) }
                    try stmt.execute(arguments: StatementArguments(args))
                }
            }
            for (table, buckets) in [("sys_1m", minutes), ("sys_1h", hours)] where !buckets.isEmpty {
                let stmt = try db.cachedStatement(sql: Self.systemUpsertSQL(table))
                for b in buckets {
                    let n = b.stats.map(\.count).max() ?? 0
                    guard n > 0 else { continue }
                    var args: [(any DatabaseValueConvertible)?] = [Int64(b.start), n]
                    for s in SystemSeries.allCases {
                        let a = b[s]
                        args += [Self.scaled(a.minOrNaN, s), Self.scaled(a.avg, s), Self.scaled(a.maxOrNaN, s)]
                    }
                    try stmt.execute(arguments: StatementArguments(args))
                }
            }
            for (table, buckets) in [("app_1m", appMinutes), ("app_1h", appHours)] where !buckets.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO \(table) (ts, app_id, n, mem_avg, mem_max, cpu_ms, written_kib) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (ts, app_id) DO UPDATE SET
                      n = n + excluded.n,
                      mem_avg = CAST(round((coalesce(mem_avg, 0) * n + coalesce(excluded.mem_avg, 0) * excluded.n) * 1.0 / (n + excluded.n)) AS INTEGER),
                      mem_max = max(coalesce(mem_max, 0), coalesce(excluded.mem_max, 0)),
                      cpu_ms = cpu_ms + excluded.cpu_ms,
                      written_kib = written_kib + excluded.written_kib
                    """)
                for b in buckets {
                    for (key, st) in b.apps {
                        let id = try self.appID(db, key: key, name: st.name)
                        let kib = { (v: Double) -> Int64? in v.isFinite ? Int64((v / 1024).rounded()) : nil }
                        try stmt.execute(arguments: [Int64(b.start), id, max(st.memory.count, 1), kib(st.memory.avg),
                                                     kib(st.memory.maxOrNaN), Int64((st.cpuSeconds * 1000).rounded()),
                                                     Int64((st.bytesWritten / 1024).rounded())])
                    }
                }
            }
        }
    }

    private static func systemUpsertSQL(_ table: String) -> String {
        let cols = SystemSeries.allCases.map(column)
        let names = cols.flatMap { ["\($0)_min", "\($0)_avg", "\($0)_max"] }
        let sets = cols.map { c in
            """
            \(c)_min = min(coalesce(\(c)_min, excluded.\(c)_min), coalesce(excluded.\(c)_min, \(c)_min)),
            \(c)_max = max(coalesce(\(c)_max, excluded.\(c)_max), coalesce(excluded.\(c)_max, \(c)_max)),
            \(c)_avg = coalesce(CAST(round((\(c)_avg * n + excluded.\(c)_avg * excluded.n) * 1.0 / (n + excluded.n)) AS INTEGER), \(c)_avg, excluded.\(c)_avg)
            """
        }
        return """
            INSERT INTO \(table) (ts, n, \(names.joined(separator: ", "))) VALUES (?, ?\(String(repeating: ", ?", count: names.count)))
            ON CONFLICT (ts) DO UPDATE SET n = n + excluded.n, \(sets.joined(separator: ",\n"))
            """
    }

    private func appID(_ db: Database, key: String, name: String) throws -> Int64 {
        if let id = appIDs.withLock({ $0[key] }) { return id }
        try db.execute(sql: "INSERT INTO app (key, name) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET name = excluded.name",
                       arguments: [key, name])
        let id = try Int64.fetchOne(db, sql: "SELECT id FROM app WHERE key = ?", arguments: [key])!
        appIDs.withLock { $0[key] = id }
        return id
    }

    /// Events are rare and matter: committed immediately, never batched.
    public func record(_ e: TalonEvent) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO event (ts, kind, pid, app_key, message) VALUES (?, ?, ?, ?, ?)",
                           arguments: [Int64(e.time), e.kind.rawValue, e.pid, e.appKey, e.message])
        }
    }

    /// Drops rows past each tier's retention. Hourly tiers and events are kept forever.
    public func prune(now: TimeInterval = Date().timeIntervalSince1970) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sys_10s WHERE ts < ?", arguments: [Int64(now - retention.tenSeconds)])
            try db.execute(sql: "DELETE FROM sys_1m WHERE ts < ?", arguments: [Int64(now - retention.minute)])
            try db.execute(sql: "DELETE FROM app_1m WHERE ts < ?", arguments: [Int64(now - retention.appMinute)])
        }
    }

    // MARK: - Reading

    /// The finest stored tier that still covers `range`.
    public func tier(for range: TimeInterval) -> HistoryTier {
        range <= 48 * 3600 ? .tenSeconds : range <= retention.minute ? .minute : .hour
    }

    public func history(_ series: SystemSeries, from: TimeInterval, to: TimeInterval, tier: HistoryTier) throws -> [HistoryPoint] {
        let c = Self.column(series)
        return try writer.read { db in
            switch tier {
            case .live, .tenSeconds:
                return try Row.fetchAll(db, sql: "SELECT ts, \(c) FROM sys_10s WHERE ts >= ? AND ts <= ? ORDER BY ts",
                                        arguments: [Int64(from), Int64(to)]).map { row in
                    let v = Self.unscaled(row[1], series)
                    return HistoryPoint(time: TimeInterval(row[0] as Int64), min: v, avg: v, max: v)
                }
            case .minute, .hour:
                let table = tier == .minute ? "sys_1m" : "sys_1h"
                return try Row.fetchAll(db, sql: "SELECT ts, \(c)_min, \(c)_avg, \(c)_max FROM \(table) WHERE ts >= ? AND ts <= ? ORDER BY ts",
                                        arguments: [Int64(from), Int64(to)]).map { row in
                    HistoryPoint(time: TimeInterval(row[0] as Int64), min: Self.unscaled(row[1], series),
                                 avg: Self.unscaled(row[2], series), max: Self.unscaled(row[3], series))
                }
            }
        }
    }

    public func topApps(from: TimeInterval, by metric: AppMetric, limit: Int) throws -> [AppTotal] {
        let table = Date().timeIntervalSince1970 - from <= retention.appMinute ? "app_1m" : "app_1h"
        let order = switch metric { case .cpu: "cpu"; case .memory: "peak"; case .disk: "written" }
        return try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.key, a.name, sum(t.cpu_ms) AS cpu, max(t.mem_max) AS peak,
                       sum(t.mem_avg * t.n) * 1.0 / max(sum(t.n), 1) AS avgmem, sum(t.written_kib) AS written
                FROM \(table) t JOIN app a ON a.id = t.app_id
                WHERE t.ts >= ? GROUP BY t.app_id ORDER BY \(order) DESC LIMIT ?
                """, arguments: [Int64(from), limit]).map { r in
                AppTotal(key: r["key"], name: r["name"], cpuSeconds: Double(r["cpu"] as Int64? ?? 0) / 1000,
                         memoryPeak: UInt64(max(0, r["peak"] as Int64? ?? 0)) * 1024,
                         memoryAverage: UInt64(max(0, (r["avgmem"] as Double? ?? 0) * 1024)),
                         bytesWritten: UInt64(max(0, r["written"] as Int64? ?? 0)) * 1024)
            }
        }
    }

    public func events(from: TimeInterval, limit: Int) throws -> [TalonEvent] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT ts, kind, pid, app_key, message FROM event WHERE ts >= ? ORDER BY ts DESC LIMIT ?",
                             arguments: [Int64(from), limit]).compactMap { r in
                guard let kind = TalonEvent.Kind(rawValue: r["kind"]) else { return nil }
                return TalonEvent(time: TimeInterval(r["ts"] as Int64), kind: kind, pid: r["pid"], appKey: r["app_key"],
                                  message: r["message"])
            }
        }
    }

    public func rowCounts() throws -> [String: Int] {
        try writer.read { db in
            var out: [String: Int] = [:]
            for t in ["sys_10s", "sys_1m", "sys_1h", "app_1m", "app_1h", "event", "app"] {
                out[t] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(t)") ?? 0
            }
            return out
        }
    }

    /// Database + WAL + shared-memory files on disk.
    public var bytesOnDisk: UInt64 {
        guard let path else { return 0 }
        return ["", "-wal", "-shm"].reduce(0) { sum, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? UInt64) ?? nil
            return sum + (size ?? 0)
        }
    }
}
