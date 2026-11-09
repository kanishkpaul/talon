import Darwin
import Foundation
import Synchronization
import TalonModel
import TalonPrivate
import TalonSensors

/// `talon run --mem 6G -- cmd`: spawn with a kernel memory ceiling set at launch. No admin needed —
/// phase 0 saw the kernel stop a runaway process at 275 MB of a 300 MB ceiling.
///
/// Kernel ceilings are per process and not inherited by children, so the launcher also watches the
/// whole process tree and, given a `budget`, enforces it with the same `CeilingEngine` talond uses —
/// no daemon needed, since the tree belongs to the user running it.
public struct CappedLauncher {
    public struct Result: Sendable {
        public var pid: pid_t
        public var exitCode: Int32        // shell convention: 128 + signal when killed
        public var signal: Int32?
        public var peakFootprint: UInt64  // the process itself
        public var peakTreeFootprint: UInt64
        public var seconds: Double
        /// Killed with SIGKILL while under a ceiling — almost certainly the kernel enforcing it.
        public var hitCeiling: Bool
        /// What the tree budget did, in order.
        public var budgetActions: [String]
    }

    public enum LaunchError: Error, CustomStringConvertible {
        case notFound(String)
        case spawnFailed(String, Int32)
        case ceilingUnavailable

        public var description: String {
            switch self {
            case .notFound(let c): "command not found: \(c)"
            case .spawnFailed(let c, let e): "couldn't start \(c): \(String(cString: strerror(e)))"
            case .ceilingUnavailable: "this macOS doesn't expose posix_spawnattr_setjetsam_ext — can't set a launch ceiling"
            }
        }
    }

    public var memoryCeiling: UInt64?
    public var pollHz: Double
    /// A tree-wide ceiling. Its target is filled in with the spawned process; `ask` isn't available.
    public var budget: Ceiling?
    /// Called (on a background queue) with each thing the budget does, as it happens.
    public var onBudgetEvent: (@Sendable (String) -> Void)?

    public init(memoryCeiling: UInt64?, pollHz: Double = 4, budget: Ceiling? = nil, onBudgetEvent: (@Sendable (String) -> Void)? = nil) {
        self.memoryCeiling = memoryCeiling
        self.pollHz = pollHz
        self.budget = budget
        self.onBudgetEvent = onBudgetEvent
    }

    public func run(_ command: [String]) throws -> Result {
        precondition(!command.isEmpty)
        let mb: Int32 = memoryCeiling.map { Int32(clamping: ($0 + (1 << 20) - 1) >> 20) } ?? 0

        // Ctrl-C reaches the child through the terminal; the launcher outlives it to report.
        let ignored = [SIGINT, SIGQUIT, SIGTERM, SIGHUP]
        let previous = ignored.map { signal($0, SIG_IGN) }
        defer { for (s, h) in zip(ignored, previous) { signal(s, h) } }

        var argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0)=\($1)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = talon_spawn_capped(&pid, command[0], &argv, &envp, mb)
        if rc == -1 { throw LaunchError.ceilingUnavailable }
        if rc == ENOENT { throw LaunchError.notFound(command[0]) }
        if rc != 0 { throw LaunchError.spawnFailed(command[0], rc) }

        let start = Date()
        let peaks = Mutex<(own: UInt64, tree: UInt64)>((0, 0))
        let actions = Mutex<[String]>([])
        var rule = budget
        if rule != nil, let st = ProcessSensor.read(pid)?.startTime { rule!.target = .tree(pid: pid, start: st) }
        let watcher = Mutex(TreeWatcher(rule: rule, onEvent: onBudgetEvent))
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.kanishk.talon.run.watch"))
        timer.schedule(deadline: .now(), repeating: 1 / max(pollHz, 0.5), leeway: .milliseconds(20))
        let child = pid
        timer.setEventHandler {
            let own = ProcessSensor.footprint(child) ?? 0
            let tree = ProcessTree.descendants(of: child).reduce(own) { $0 + (ProcessSensor.footprint($1) ?? 0) }
            peaks.withLock { $0 = (max($0.own, own), max($0.tree, tree)) }
            let done = watcher.withLock { $0.tick(root: child) }
            if !done.isEmpty { actions.withLock { $0 += done } }
        }
        timer.resume()

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        timer.cancel()

        let p = peaks.withLock { $0 }
        let sig: Int32? = (status & 0x7f) != 0 && (status & 0x7f) != 0x7f ? status & 0x7f : nil
        let code: Int32 = sig.map { 128 + $0 } ?? (status >> 8) & 0xff
        return Result(pid: pid, exitCode: code, signal: sig, peakFootprint: p.own, peakTreeFootprint: max(p.tree, p.own),
                      seconds: Date().timeIntervalSince(start), hitCeiling: sig == SIGKILL && mb > 0 && actions.withLock({ $0.isEmpty }),
                      budgetActions: actions.withLock { $0 })
    }
}

/// Samples one process tree (CPU from deltas) and runs the ceiling engine over it.
struct TreeWatcher: Sendable {
    let rule: Ceiling?
    let onEvent: (@Sendable (String) -> Void)?
    var engine = CeilingEngine(release: 10)
    var previous: [pid_t: (start: UInt64, cpuNs: UInt64, written: UInt64)] = [:]
    var lastNs: UInt64 = 0
    let enforcer = Enforcer(policy: TargetPolicy(allowedUID: getuid()))

    init(rule: Ceiling?, onEvent: (@Sendable (String) -> Void)?) {
        self.rule = rule
        self.onEvent = onEvent
    }

    mutating func tick(root: pid_t) -> [String] {
        guard let rule else { return [] }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = lastNs == 0 ? 0 : Double(now - lastNs)
        lastNs = now
        var samples: [ProcessSample] = []
        var next: [pid_t: (UInt64, UInt64, UInt64)] = [:]
        for pid in [root] + ProcessTree.descendants(of: root) {
            guard let raw = ProcessSensor.read(pid), let info = ProcessSensor.info(pid) else { continue }
            var cpu = 0.0, rate = 0.0
            if let p = previous[pid], p.start == raw.startTime, elapsed > 0 {
                cpu = Double(raw.cpuNanoseconds &- p.cpuNs) / elapsed * 100
                rate = Double(raw.diskWritten &- p.written) / (elapsed / 1e9)
            }
            next[pid] = (raw.startTime, raw.cpuNanoseconds, raw.diskWritten)
            samples.append(ProcessSample(pid: pid, startTime: raw.startTime, responsiblePID: root, uid: info.uid,
                                         name: ProcessSensor.name(pid), footprint: raw.footprint, cpuPercent: max(0, cpu),
                                         diskWriteRate: max(0, rate), diskWrittenTotal: raw.diskWritten,
                                         parentPID: pid == root ? 0 : info.parent))
        }
        previous = next.mapValues { (start: $0.0, cpuNs: $0.1, written: $0.2) }
        var messages: [String] = []
        for d in engine.evaluate([rule], processes: samples, apps: [], now: Double(now) / 1e9) {
            switch d {
            case .record(_, let m), .notify(_, let m), .ask(_, let m): messages.append(m)
            case .expired: break
            default:
                for o in enforcer.apply(d, caller: getuid()) {
                    switch o { case .done(let m), .refused(let m), .failed(let m): messages.append(m) }
                }
            }
        }
        messages.forEach { onEvent?($0) }
        return messages
    }
}

/// Descendants of a process, found by parent pid. Used for tree-wide footprints and budgets.
public enum ProcessTree {
    public static func children(of pid: pid_t) -> [pid_t] {
        var capacity = 64
        while true {
            var buf = [pid_t](repeating: 0, count: capacity)
            let n = Int(proc_listchildpids(pid, &buf, Int32(capacity * MemoryLayout<pid_t>.size)))
            if n <= 0 { return [] }
            if n < capacity { return Array(buf.prefix(n)) }
            capacity *= 4
        }
    }

    public static func descendants(of root: pid_t) -> [pid_t] {
        var out: [pid_t] = [], queue = [root], seen: Set<pid_t> = [root]
        while let p = queue.popLast() {
            for c in children(of: p) where seen.insert(c).inserted { out.append(c); queue.append(c) }
        }
        return out
    }

    public static func footprint(root: pid_t) -> UInt64 {
        ([root] + descendants(of: root)).reduce(0) { $0 + (ProcessSensor.footprint($1) ?? 0) }
    }
}
