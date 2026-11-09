import Darwin
import Foundation

/// One cut: everything moved out in one go, restorable together.
public struct CutManifest: Codable, Sendable {
    public var id: String
    public var createdAt: Date
    public var category: FindingCategory?
    public var findingID: String?
    public var title: String?
    public var items: [HeldItem]

    public var sizes: Sizes { items.reduce(Sizes()) { $0 + $1.sizes } }
    public func purgeDate(hold: TimeInterval) -> Date { createdAt.addingTimeInterval(hold) }
}

public struct HeldItem: Codable, Sendable {
    public var originalPath: String
    /// Name inside the cut's `items/` folder.
    public var heldName: String
    public var sizes: Sizes
}

/// `~/.talon/holding/<cut-id>/` — items move here with rename(2): same volume, so a cut is instant,
/// writes no data, and a restore is the same rename backwards. Purged for good after the hold period.
public struct HoldingArea: Sendable {
    public var root: String
    public var guardrails: CutGuard
    /// How long a cut is kept before `purgeExpired` deletes it.
    public var hold: TimeInterval

    public static let defaultHold: TimeInterval = 7 * 86_400

    public init(root: String? = nil, guardrails: CutGuard = CutGuard(), hold: TimeInterval = HoldingArea.defaultHold) {
        self.root = root ?? (NSHomeDirectory() + "/.talon/holding")
        self.guardrails = guardrails
        self.hold = hold
    }

    public enum HoldingError: Error, CustomStringConvertible {
        case notFound(String)
        case ambiguous(String)
        case io(String, Int32)
        public var description: String {
            switch self {
            case .notFound(let id): "no cut matches \"\(id)\" — see `talon scalpel holding`"
            case .ambiguous(let id): "\"\(id)\" matches several cuts; give more of the id"
            case .io(let what, let e): "\(what): \(String(cString: strerror(e)))"
            }
        }
    }

    /// What to cut: a path plus what the safety checks need to know about it.
    public struct Request: Sendable {
        public var path: String
        public var tier: Tier?
        public var ownerBundleID: String?
        public var ownerName: String?
        public var sizes: Sizes?

        public init(path: String, tier: Tier? = nil, ownerBundleID: String? = nil, ownerName: String? = nil, sizes: Sizes? = nil) {
            self.path = path
            self.tier = tier
            self.ownerBundleID = ownerBundleID
            self.ownerName = ownerName
            self.sizes = sizes
        }
    }

    // MARK: - Cut

    /// Checks every path first, then moves them all; if any move fails, the ones already moved go back.
    @discardableResult
    public func cut(_ requests: [Request], category: FindingCategory? = nil, findingID: String? = nil, title: String? = nil,
                    now: Date = Date()) throws -> CutManifest {
        let paths = requests.map { Protection.canonical($0.path) }
        for (r, p) in zip(requests, paths) {
            try guardrails.check(p, tier: r.tier, ownerBundleID: r.ownerBundleID, ownerName: r.ownerName)
            if p == root || p.hasPrefix(root + "/") || root.hasPrefix(p + "/") { throw Refusal(p, "contains or is inside the holding area") }
        }
        try ensureRoot()
        let rootDev = device(of: root)
        for p in paths where device(of: p) != rootDev {
            throw Refusal(p, "on another volume — the holding area only takes same-volume moves (rename, no copying)")
        }

        let id = Self.makeID(now)
        let dir = root + "/" + id
        let itemsDir = dir + "/items"
        guard mkdir(dir, 0o700) == 0, mkdir(itemsDir, 0o700) == 0 else { throw HoldingError.io("creating \(dir)", errno) }

        var items: [HeldItem] = []
        for (i, (r, p)) in zip(requests, paths).enumerated() {
            let sizes = r.sizes ?? ((try? DiskScanner(options: .init(workers: 2)).measure(p)) ?? Sizes())
            items.append(HeldItem(originalPath: p, heldName: "\(i)-" + (p as NSString).lastPathComponent, sizes: sizes))
        }
        var manifest = CutManifest(id: id, createdAt: now, category: category, findingID: findingID, title: title, items: items)
        // The manifest goes down first, so a crash mid-cut still leaves a record of where things went.
        try write(manifest, to: dir)

        var moved: [HeldItem] = []
        for item in items {
            if rename(item.originalPath, itemsDir + "/" + item.heldName) != 0 {
                let e = errno
                for m in moved.reversed() { _ = rename(itemsDir + "/" + m.heldName, m.originalPath) }
                try? FileManager.default.removeItem(atPath: dir)
                throw HoldingError.io("moving \(item.originalPath)", e)
            }
            moved.append(item)
        }
        manifest.items = moved
        try write(manifest, to: dir)
        return manifest
    }

    // MARK: - List / restore / purge

    public func list() -> [CutManifest] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return names.compactMap { read(root + "/" + $0) }.sorted { $0.createdAt > $1.createdAt }
    }

    /// An id or unique prefix.
    public func find(_ ref: String) throws -> CutManifest {
        let hits = list().filter { $0.id == ref || $0.id.hasPrefix(ref) }
        if hits.count > 1, let exact = hits.first(where: { $0.id == ref }) { return exact }
        guard hits.count == 1 else { throw hits.isEmpty ? HoldingError.notFound(ref) : HoldingError.ambiguous(ref) }
        return hits[0]
    }

    /// Puts every item back. Refuses up front if anything now exists at an original path, so a
    /// restore never overwrites and never half-happens.
    @discardableResult
    public func restore(_ ref: String) throws -> [String] {
        var manifest = try find(ref)
        let dir = root + "/" + manifest.id
        var st = stat()
        for item in manifest.items where lstat(item.originalPath, &st) == 0 {
            throw Refusal(item.originalPath, "something already exists here — move it aside first; nothing was restored")
        }
        var restored: [String] = []
        var remaining: [HeldItem] = []
        for item in manifest.items {
            let held = dir + "/items/" + item.heldName
            guard lstat(held, &st) == 0 else { continue }  // never moved (interrupted cut)
            let parent = (item.originalPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            if rename(held, item.originalPath) == 0 { restored.append(item.originalPath) } else { remaining.append(item) }
        }
        if remaining.isEmpty {
            try? FileManager.default.removeItem(atPath: dir)
        } else {
            manifest.items = remaining
            try write(manifest, to: dir)
        }
        return restored
    }

    /// Deletes one cut for good.
    @discardableResult
    public func purge(_ ref: String) throws -> CutManifest {
        let m = try find(ref)
        try Self.forceRemove(root + "/" + m.id)
        return m
    }

    /// Deletes every cut older than `age`.
    @discardableResult
    public func purge(olderThan age: TimeInterval, now: Date = Date()) throws -> [CutManifest] {
        let expired = list().filter { now.timeIntervalSince($0.createdAt) >= age }
        for m in expired { try Self.forceRemove(root + "/" + m.id) }
        return expired
    }

    /// Cuts that would be purged at `now` given the hold period.
    public func expired(now: Date = Date()) -> [CutManifest] { list().filter { now >= $0.purgeDate(hold: hold) } }

    // MARK: - Internals

    static func makeID(_ now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: now) + "-" + String(UInt32.random(in: 0...0xFFFF), radix: 16).leftPad(4)
    }

    private func ensureRoot() throws {
        do { try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw HoldingError.io("creating \(root)", EACCES) }
    }

    private func device(of path: String) -> dev_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_dev : nil
    }

    private func write(_ m: CutManifest, to dir: String) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try e.encode(m).write(to: URL(fileURLWithPath: dir + "/manifest.json"), options: .atomic)
    }

    private func read(_ dir: String) -> CutManifest? {
        guard let data = FileManager.default.contents(atPath: dir + "/manifest.json") else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(CutManifest.self, from: data)
    }

    /// Removes a tree, making read-only folders writable first (Go module caches, some node_modules).
    static func forceRemove(_ path: String) throws {
        do { try FileManager.default.removeItem(atPath: path); return } catch {}
        if let e = FileManager.default.enumerator(atPath: path) {
            chmod(path, 0o700)
            while let rel = e.nextObject() as? String {
                let p = path + "/" + rel
                var st = stat()
                if lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { chmod(p, 0o700) }
                if st.st_flags & UInt32(UF_IMMUTABLE) != 0 { chflags(p, st.st_flags & ~UInt32(UF_IMMUTABLE)) }
            }
        }
        do { try FileManager.default.removeItem(atPath: path) } catch { throw HoldingError.io("purging \(path)", EACCES) }
    }
}
