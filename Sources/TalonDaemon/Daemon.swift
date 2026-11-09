import Darwin
import Foundation
import os
import TalonCore
import TalonIPC
import TalonModel
import TalonPrivate
import TalonSensors
import TalonStore

public let log = Logger(subsystem: "dev.kanishk.talon", category: "talond")

/// Everything talond owns. All state lives on `queue`; XPC handlers hop onto it synchronously.
/// Pointer- and signal-heavy work stays synchronous inside this one owner, and only Sendable
/// value snapshots leave it.
public final class Daemon: @unchecked Sendable {
    public struct Options: Sendable {
        public var allowedUID: uid_t
        public var databasePath: String?          // nil: history in memory only (tests)
        public var flushInterval: TimeInterval
        public var sampleHz: Double
        public var verbose: Bool

        public init(allowedUID: uid_t, databasePath: String?, flushInterval: TimeInterval = 60, sampleHz: Double = 1,
                    verbose: Bool = false) {
            self.allowedUID = allowedUID; self.databasePath = databasePath; self.flushInterval = flushInterval
            self.sampleHz = sampleHz; self.verbose = verbose
        }
    }

    public let options: Options
    let queue = DispatchQueue(label: "dev.kanishk.talond.state", qos: .utility)
    let startedAt = Date()
    let enforcer: Enforcer

    // T0: RAM only.
    private let processSampler = ProcessSampler()
    private let systemSampler = SystemSampler()
    private var ring = RingBuffer<SystemSample>(capacity: 3600)
    private var latestProcesses: ProcessSnapshot?
    private var lastSweepTime: TimeInterval?

    // T1–T3: in-memory accumulators, committed every `flushInterval`.
    private let tier10s = SystemTier(period: 10)
    private let tier1m = SystemTier(period: 60)
    private let tier1h = SystemTier(period: 3600)
    private let apps1m = AppTier(period: 60)
    private let apps1h = AppTier(period: 3600)

    private let store: HistoryStore?
    private var frozen: [pid_t: UInt64] = [:]   // pid → start time, persisted so a crash can't strand one
    private var lastThermal: ThermalPressure?
    private var lastMemoryPressure: MemoryPressure?
    private var timers: [DispatchSourceTimer] = []
    private let cpuAtStart: Double

    public init(options: Options) {
        self.options = options
        enforcer = Enforcer(policy: TargetPolicy(allowedUID: options.allowedUID))
        do {
            store = try options.databasePath.map { try HistoryStore(path: $0) } ?? HistoryStore.inMemory()
        } catch {
            log.error("history disabled — can't open \(options.databasePath ?? "memory", privacy: .public): \(String(describing: error), privacy: .public)")
            store = nil
        }
        cpuAtStart = Self.ownCPUSeconds()
    }

    private var frozenStatePath: String? {
        options.databasePath.map { ($0 as NSString).deletingLastPathComponent + "/frozen.json" }
    }

    // MARK: - Lifecycle

    public func start() {
        queue.sync {
            resumeStrandedProcesses()
            record(TalonEvent(time: now(), kind: .daemonStarted,
                              message: "talond \(talonVersion) started as uid \(geteuid()), serving uid \(options.allowedUID)"))
            _ = processSampler.sweep()  // prime counters so the first real tick has rates
        }
        schedule(every: 1 / options.sampleHz, leeway: .milliseconds(50)) { $0.tick() }
        schedule(every: options.flushInterval, leeway: .seconds(5)) { $0.flush() }
        schedule(every: 3600, leeway: .seconds(60)) { $0.prune() }
    }

    public func shutdown() {
        queue.sync {
            for pid in frozen.keys { kill(pid, SIGCONT) }
            frozen = [:]
            persistFrozen()
            flush(final: true)
            record(TalonEvent(time: now(), kind: .daemonStopped, message: "talond stopped"))
            timers.forEach { $0.cancel() }
        }
    }

    private func schedule(every interval: TimeInterval, leeway: DispatchTimeInterval, _ body: @escaping (Daemon) -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        t.setEventHandler { [unowned self] in body(self) }
        t.resume()
        timers.append(t)
    }

    private func now() -> TimeInterval { Date().timeIntervalSince1970 }

    // MARK: - Sampling

    private func tick() {
        let snap = processSampler.sweep()
        let sample = systemSampler.sample(processes: snap, now: snap.time)
        let interval = lastSweepTime.map { min(snap.time - $0, 10) } ?? 1 / options.sampleHz
        lastSweepTime = snap.time
        latestProcesses = snap
        ring.append(sample)
        for t in [tier10s, tier1m, tier1h] { t.add(sample) }
        apps1m.add(snap.apps, at: snap.time, interval: interval)
        apps1h.add(snap.apps, at: snap.time, interval: interval)
        noticeChanges(sample)
        if options.verbose {
            print(String(format: "tick %.0f · %d procs (%d denied) · sweep %.1f ms · cpu %.0f%% · %@",
                         snap.time, snap.readable, snap.denied, snap.sweepSeconds * 1000, sample[.cpu],
                         SystemSeries.memUsed.format(sample[.memUsed])))
        }
    }

    private func noticeChanges(_ s: SystemSample) {
        if let tp = ThermalPressure(rawValue: Int(s[.thermalPressure].isFinite ? s[.thermalPressure] : -1)) {
            if let last = lastThermal, last != tp {
                record(TalonEvent(time: s.time, kind: .thermalChange, message: "thermal pressure \(last.label) → \(tp.label)"))
            }
            lastThermal = tp
        }
        if s[.memPressure].isFinite, let mp = MemoryPressure(rawValue: Int(s[.memPressure])) {
            if let last = lastMemoryPressure, last != mp {
                record(TalonEvent(time: s.time, kind: .memoryPressureChange, message: "memory pressure \(last.label) → \(mp.label)"))
            }
            lastMemoryPressure = mp
        }
    }

    private func flush(final: Bool = false) {
        guard let store else { return }
        do {
            try store.write(tenSeconds: tier10s.drain(includePartial: final), minutes: tier1m.drain(includePartial: final),
                            hours: tier1h.drain(includePartial: final), appMinutes: apps1m.drain(includePartial: final),
                            appHours: apps1h.drain(includePartial: final))
        } catch {
            log.error("flush failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func prune() {
        do { try store?.prune() } catch { log.error("prune failed: \(String(describing: error), privacy: .public)") }
    }

    private func record(_ e: TalonEvent) {
        log.notice("\(e.kind.rawValue, privacy: .public): \(e.message, privacy: .public)")
        do { try store?.record(e) } catch { log.error("event not recorded: \(String(describing: error), privacy: .public)") }
    }

    // MARK: - Frozen processes survive nothing

    private func persistFrozen() {
        guard let frozenStatePath else { return }
        if frozen.isEmpty { try? FileManager.default.removeItem(atPath: frozenStatePath); return }
        let entries = frozen.map { ["pid": UInt64($0.key), "start": $0.value] }
        if let data = try? JSONSerialization.data(withJSONObject: entries) {
            try? data.write(to: URL(fileURLWithPath: frozenStatePath), options: .atomic)
        }
    }

    /// Resume anything a previous talond froze and didn't get to thaw (a crash, a kill -9).
    private func resumeStrandedProcesses() {
        guard let frozenStatePath, let data = FileManager.default.contents(atPath: frozenStatePath),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: UInt64]] else { return }
        for e in entries {
            guard let pid = e["pid"].map({ pid_t($0) }), let start = e["start"] else { continue }
            if ProcessSensor.read(pid)?.startTime == start {
                kill(pid, SIGCONT)
                log.notice("resumed pid \(pid) left frozen by a previous talond")
            }
        }
        try? FileManager.default.removeItem(atPath: frozenStatePath)
    }

    // MARK: - Requests

    public func handle(_ request: TalonRequest, callerUID: uid_t) -> TalonReply {
        queue.sync { handleOnQueue(request, callerUID: callerUID) }
    }

    private func handleOnQueue(_ request: TalonRequest, callerUID: uid_t) -> TalonReply {
        switch request {
        case .hello:
            return .hello(protocolVersion: talonProtocolVersion, daemonVersion: talonVersion)

        case .status:
            return .status(status())

        case .processes:
            guard let p = latestProcesses else { return .error(TalonError(.notFound, "no sweep yet — try again in a second")) }
            return .processes(p)

        case .history(let series, let range, let maxPoints):
            return .history(history(series, range: range, maxPoints: max(2, min(maxPoints, 5000))))

        case .topApps(let range, let metric, let limit):
            guard let store else { return .error(TalonError(.failed, "history is disabled (database couldn't be opened)")) }
            flush()
            do { return .topApps(try store.topApps(from: now() - range, by: metric, limit: limit)) }
            catch { return .error(TalonError(.failed, "\(error)")) }

        case .events(let range, let limit):
            guard let store else { return .events([]) }
            do { return .events(try store.events(from: now() - range, limit: limit)) }
            catch { return .error(TalonError(.failed, "\(error)")) }

        case .capMemory(let pid, let bytes):
            return reply(enforcer.capMemory(caller: callerUID, pid: pid, bytes: bytes), kind: .memoryCapSet, pid: pid)

        case .memoryLimit(let pid):
            var active: Int32 = 0, inactive: Int32 = 0, fatal = false
            let rc = talon_get_memory_limit(pid, &active, &inactive, &fatal)
            if rc != 0 { return .error(TalonError(.failed, "can't read pid \(pid)'s limit: \(String(cString: strerror(rc)))")) }
            return .memoryLimit(activeMB: active, inactiveMB: inactive, fatal: fatal)

        case .freeze(let pid):
            let outcome = enforcer.freeze(caller: callerUID, pid: pid)
            if case .done = outcome, let start = ProcessSensor.read(pid)?.startTime {
                frozen[pid] = start
                persistFrozen()
            }
            return reply(outcome, kind: .frozen, pid: pid)

        case .thaw(let pid):
            let outcome = enforcer.thaw(caller: callerUID, pid: pid)
            if case .done = outcome { frozen[pid] = nil; persistFrozen() }
            return reply(outcome, kind: .thawed, pid: pid)
        }
    }

    private func reply(_ o: Enforcer.Outcome, kind: TalonEvent.Kind, pid: pid_t) -> TalonReply {
        switch o {
        case .done(let msg):
            record(TalonEvent(time: now(), kind: kind, pid: pid, message: msg))
            return .ok(msg)
        case .refused(let msg):
            log.notice("refused: \(msg, privacy: .public)")
            return .error(TalonError(.refused, msg))
        case .failed(let msg):
            return .error(TalonError(.failed, msg))
        }
    }

    private func history(_ series: SystemSeries, range: TimeInterval, maxPoints: Int) -> HistorySeries {
        let to = now(), from = to - range
        if range <= 3600 || store == nil {
            let pts = ring.elements.filter { $0.time >= from }.map {
                HistoryPoint(time: $0.time, min: $0[series], avg: $0[series], max: $0[series])
            }
            return HistorySeries(series: series, tier: .live, points: downsample(pts, maxPoints: maxPoints))
        }
        let tier = store!.tier(for: range)
        var points = (try? store!.history(series, from: from, to: to, tier: tier)) ?? []
        // Add buckets that are complete or in progress but not yet committed.
        let pending: [SystemBucket] = switch tier {
        case .live, .tenSeconds: tier10s.pending
        case .minute: tier1m.pending
        case .hour: tier1h.pending
        }
        let lastStored = points.last?.time ?? -.infinity
        for b in pending where b.start > lastStored && b.start >= from {
            let a = b[series]
            points.append(tier == .tenSeconds ? HistoryPoint(time: b.start, min: a.avg, avg: a.avg, max: a.avg)
                                              : HistoryPoint(time: b.start, min: a.minOrNaN, avg: a.avg, max: a.maxOrNaN))
        }
        return HistorySeries(series: series, tier: tier, points: downsample(points, maxPoints: maxPoints))
    }

    private static func ownCPUSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        let t = { (tv: timeval) in Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6 }
        return t(u.ru_utime) + t(u.ru_stime)
    }

    private func status() -> DaemonStatus {
        let me = ProcessSensor.read(getpid())
        let up = max(Date().timeIntervalSince(startedAt), 1)
        return DaemonStatus(
            version: talonVersion, protocolVersion: talonProtocolVersion, pid: getpid(), euid: geteuid(),
            allowedUID: options.allowedUID, startedAt: startedAt,
            ownCPUPercent: (Self.ownCPUSeconds() - cpuAtStart) / up * 100, ownFootprint: me?.footprint ?? 0,
            ownBytesWritten: me?.diskWritten ?? 0, databasePath: options.databasePath ?? "(memory)",
            databaseBytes: store?.bytesOnDisk ?? 0, readableProcesses: latestProcesses?.readable ?? 0,
            deniedProcesses: latestProcesses?.denied ?? 0, lastSweepMillis: (latestProcesses?.sweepSeconds ?? 0) * 1000,
            frozen: frozen.keys.sorted(), latest: ring.last)
    }
}
