import Foundation
import TalonModel

/// The ceiling state machine. Pure: it sees rules, a process list and the time, and returns
/// decisions; it never sends a signal itself. talond runs it for app ceilings, `talon run` runs it
/// for process-tree budgets, and the tests run it with hand-made process lists.
///
/// Per ceiling:
///
///     ok ──(≥ warn line)──▶ approaching ──(≥ ceiling)──▶ over ──(grace elapsed)──▶ enforced / asking
///      ▲                                                                              │
///      └──────────────── below the warn line for `release` seconds ◀──────────────────┘
///
/// The release delay is hysteresis: a slowed-down process that drops under its CPU ceiling isn't
/// un-throttled the next second, only to cross again and flap.
public struct CeilingEngine: Sendable {
    public enum Decision: Equatable, Sendable {
        case record(UUID, String)                    // an event, nothing else (Watch)
        case notify(UUID, String)                    // a notification (Warn, and every "approaching")
        case ask(UUID, String)                       // show the ask panel
        case throttle(UUID, [Int32], on: Bool)       // background priority on / off
        case pause(UUID, [Int32])                    // SIGSTOP
        case terminate(UUID, [Int32])                // SIGTERM
        case kill(UUID, [Int32])                     // SIGKILL
        case kernelCap(UUID, [Int32], bytes: UInt64) // per-process kernel memory limit
        case expired(UUID)                           // an ephemeral target is gone: drop the rule

        public var ruleID: UUID {
            switch self {
            case .record(let id, _), .notify(let id, _), .ask(let id, _), .throttle(let id, _, _), .pause(let id, _),
                 .terminate(let id, _), .kill(let id, _), .kernelCap(let id, _, _), .expired(let id): id
            }
        }
    }

    struct State: Sendable {
        var phase = CeilingStatus.Phase.ok
        var usage = CeilingUsage()
        var ratio = 0.0
        var worst: CeilingResource?
        var pids: [Int32] = []
        var overSince: TimeInterval?
        var underSince: TimeInterval?
        var acted = false
        var warned = false
        var asking = false
        var throttled: Set<Int32> = []
        var capped: Set<Int32> = []
        var termSentAt: TimeInterval?
        var killed = false
        var lastHardKill: TimeInterval = -.infinity
        var lastAction: String?
    }

    private var states: [UUID: State] = [:]

    /// How long usage must stay under the warn line before a ceiling re-arms (and throttling lifts).
    public var release: TimeInterval

    public init(release: TimeInterval = 30) { self.release = release }

    // MARK: - Resolving targets

    public static func resolve(_ target: CeilingTarget, processes: [ProcessSample], apps: [AppUsage]) -> [ProcessSample] {
        switch target {
        case .app(let key):
            let owners = Set(apps.filter { $0.key == key }.map(\.responsiblePID))
            return processes.filter { owners.contains($0.responsiblePID) }
        case .process(let pid, let start):
            return processes.filter { $0.pid == pid && $0.startTime == start }
        case .tree(let pid, let start):
            guard let root = processes.first(where: { $0.pid == pid && $0.startTime == start }) else { return [] }
            var children: [Int32: [ProcessSample]] = [:]
            for p in processes where p.pid != p.parentPID { children[p.parentPID, default: []].append(p) }
            var out = [root], queue = [root.pid], seen: Set<Int32> = [root.pid]
            while let next = queue.popLast() {
                for c in children[next] ?? [] where seen.insert(c.pid).inserted { out.append(c); queue.append(c.pid) }
            }
            return out
        }
    }

    // MARK: - Evaluation

    /// One pass. `memoryOnly` is the fast lane: footprints are fresh, CPU and write rates are not.
    public mutating func evaluate(_ rules: [Ceiling], processes: [ProcessSample], apps: [AppUsage], now: TimeInterval,
                                  memoryOnly: Bool = false) -> [Decision] {
        var out: [Decision] = []
        for rule in rules {
            var st = states[rule.id] ?? State()
            defer { states[rule.id] = st }

            guard rule.enabled, rule.hasLimit else {
                if !st.throttled.isEmpty { out.append(.throttle(rule.id, st.throttled.sorted(), on: false)) }
                st = State()
                st.phase = .disabled
                continue
            }

            let procs = Self.resolve(rule.target, processes: processes, apps: apps)
            if procs.isEmpty {
                if rule.target.isEphemeral { out.append(.expired(rule.id)) }
                let lastAction = st.lastAction
                st = State()
                st.phase = .gone
                st.lastAction = lastAction
                continue
            }

            st.pids = procs.map(\.pid)
            st.usage.memory = procs.reduce(0) { $0 + Double($1.footprint) }
            if !memoryOnly {
                st.usage.cpu = procs.reduce(0) { $0 + $1.cpuPercent }
                st.usage.writes = procs.reduce(0) { $0 + $1.diskWriteRate }
            }
            (st.ratio, st.worst) = Self.worst(rule, st.usage)

            // Hard cap: every process in the target gets the kernel limit as soon as it appears.
            if rule.strictness == .hardCap, let mem = rule.memory {
                let fresh = st.pids.filter { !st.capped.contains($0) }
                if !fresh.isEmpty {
                    out.append(.kernelCap(rule.id, fresh, bytes: mem))
                    st.capped.formUnion(fresh)
                }
            }
            // Processes that join a throttled target are throttled too.
            if !st.throttled.isEmpty {
                let fresh = Set(st.pids).subtracting(st.throttled)
                if !fresh.isEmpty {
                    out.append(.throttle(rule.id, fresh.sorted(), on: true))
                    st.throttled.formUnion(fresh)
                }
            }

            if st.ratio >= 1 {
                st.underSince = nil
                if st.overSince == nil { st.overSince = now }
                let overFor = now - st.overSince!
                if !st.acted {
                    if overFor >= rule.grace {
                        out += act(rule, procs, &st, now: now)
                    } else {
                        st.phase = .over
                    }
                } else {
                    out += escalate(rule, procs, &st, now: now)
                }
            } else if st.ratio >= rule.warnFraction {
                st.underSince = nil
                st.overSince = nil
                if !st.warned && !st.acted {
                    st.warned = true
                    let m = "\(rule.label) is approaching its ceiling: \(Self.describe(rule, st))"
                    out.append(rule.strictness == .watch ? .record(rule.id, m) : .notify(rule.id, m))
                }
                if !st.acted { st.phase = .approaching }
            } else {
                st.overSince = nil
                if st.underSince == nil { st.underSince = now }
                if st.acted || st.warned || !st.throttled.isEmpty {
                    if now - st.underSince! >= release {
                        if !st.throttled.isEmpty { out.append(.throttle(rule.id, st.throttled.sorted(), on: false)) }
                        if st.acted { out.append(.record(rule.id, "\(rule.label) is back under its ceiling")) }
                        st.throttled = []
                        st.acted = false; st.warned = false; st.asking = false
                        st.termSentAt = nil; st.killed = false
                        st.phase = .ok
                    }
                } else {
                    st.phase = .ok
                }
            }
        }
        // Forget rules that no longer exist.
        let ids = Set(rules.map(\.id))
        states = states.filter { ids.contains($0.key) }
        return out
    }

    private mutating func act(_ rule: Ceiling, _ procs: [ProcessSample], _ st: inout State, now: TimeInterval) -> [Decision] {
        st.acted = true
        st.phase = .enforced
        let what = Self.describe(rule, st)
        let pids = st.pids
        var out: [Decision] = []
        switch rule.strictness {
        case .watch:
            out.append(.record(rule.id, "\(rule.label) crossed its ceiling: \(what)"))
            st.lastAction = "marked"
        case .warn:
            out.append(.notify(rule.id, "\(rule.label) crossed its ceiling: \(what)"))
            st.lastAction = "notified"
        case .ask:
            out.append(.ask(rule.id, "\(rule.label) crossed its ceiling: \(what)"))
            st.asking = true
            st.phase = .asking
            st.lastAction = "asked"
        case .slowDown:
            out.append(.throttle(rule.id, pids, on: true))
            st.throttled.formUnion(pids)
            st.lastAction = "slowed down"
        case .pause:
            out.append(.pause(rule.id, pids))
            st.lastAction = "paused"
        case .quit:
            out.append(.terminate(rule.id, pids))
            st.termSentAt = now
            st.lastAction = "asked to quit"
        case .hardCap:
            if st.worst == .memory {
                out += hardKill(rule, procs, &st, now: now)
            } else {
                // The kernel can only cap memory; CPU and write ceilings fall back to slowing down.
                out.append(.throttle(rule.id, pids, on: true))
                st.throttled.formUnion(pids)
                st.lastAction = "slowed down"
            }
        }
        return out
    }

    /// Already acted and still over: Quit escalates to SIGKILL; a memory Hard cap keeps the sum
    /// under the ceiling by stopping the largest process, at most once a second.
    private mutating func escalate(_ rule: Ceiling, _ procs: [ProcessSample], _ st: inout State, now: TimeInterval) -> [Decision] {
        st.phase = st.asking ? .asking : .enforced
        if let sent = st.termSentAt, !st.killed, now - sent >= rule.quitGrace {
            st.killed = true
            st.lastAction = "force-quit"
            return [.kill(rule.id, st.pids)]
        }
        if rule.strictness == .hardCap, st.worst == .memory, now - st.lastHardKill >= 1 {
            return hardKill(rule, procs, &st, now: now)
        }
        return []
    }

    private func hardKillTarget(_ procs: [ProcessSample]) -> ProcessSample? { procs.max { $0.footprint < $1.footprint } }

    private mutating func hardKill(_ rule: Ceiling, _ procs: [ProcessSample], _ st: inout State, now: TimeInterval) -> [Decision] {
        guard let biggest = hardKillTarget(procs) else { return [] }
        st.lastHardKill = now
        st.lastAction = "stopped \(biggest.name) (largest, \(ByteSize.format(biggest.footprint)))"
        return [.kill(rule.id, [biggest.pid])]
    }

    // MARK: - Answers and removal

    /// Applies an ask-panel answer. Returns the decisions to carry out and, for `.raise`, the rule
    /// with its limits raised (the caller persists it).
    public mutating func answer(_ rule: Ceiling, _ choice: AskChoice, now: TimeInterval) -> (decisions: [Decision], updated: Ceiling?) {
        var st = states[rule.id] ?? State()
        defer { states[rule.id] = st }
        st.asking = false
        switch choice {
        case .raise(let factor):
            var r = rule
            let f = max(1.01, factor)
            r.memory = r.memory.map { UInt64(Double($0) * f) }
            r.cpu = r.cpu.map { $0 * f }
            r.writeRate = r.writeRate.map { $0 * f }
            st.acted = false; st.warned = false; st.overSince = nil
            st.phase = .ok
            st.lastAction = "raised to \(r.summary)"
            return ([.record(rule.id, "\(rule.label): ceiling raised to \(r.summary)")], r)
        case .pause:
            st.phase = .enforced
            st.lastAction = "paused"
            return ([.pause(rule.id, st.pids)], nil)
        case .quit:
            st.termSentAt = now
            st.phase = .enforced
            st.lastAction = "asked to quit"
            return ([.terminate(rule.id, st.pids)], nil)
        case .ignore:
            st.phase = .enforced
            st.lastAction = "ignored"
            return ([.record(rule.id, "\(rule.label): over its ceiling, left running")], nil)
        }
    }

    /// Undo what a ceiling is still doing (throttling) before it's deleted.
    public mutating func remove(_ id: UUID) -> [Decision] {
        defer { states[id] = nil }
        guard let st = states[id], !st.throttled.isEmpty else { return [] }
        return [.throttle(id, st.throttled.sorted(), on: false)]
    }

    // MARK: - Reading

    public func status(_ rules: [Ceiling]) -> [CeilingStatus] {
        rules.map { r in
            let st = states[r.id] ?? State()
            return CeilingStatus(id: r.id, phase: r.enabled ? st.phase : .disabled, usage: st.usage, ratio: st.ratio,
                                 worst: st.worst, pids: st.pids, overSince: st.overSince.map(Date.init(timeIntervalSince1970:)),
                                 lastAction: st.lastAction)
        }
    }

    /// Processes the 4 Hz fast lane should re-read: everything under an enabled memory ceiling.
    public func fastLanePIDs(_ rules: [Ceiling]) -> Set<Int32> {
        Set(rules.filter { $0.enabled && $0.memory != nil }.flatMap { states[$0.id]?.pids ?? [] })
    }

    // MARK: - Helpers

    static func worst(_ rule: Ceiling, _ u: CeilingUsage) -> (Double, CeilingResource?) {
        var ratio = 0.0, worst: CeilingResource?
        for r in CeilingResource.allCases {
            guard let l = rule.limit(r), l > 0 else { continue }
            let x = u[r] / l
            if worst == nil || x > ratio { ratio = x; worst = r }
        }
        return (ratio, worst)
    }

    static func describe(_ rule: Ceiling, _ st: State) -> String {
        guard let w = st.worst, let l = rule.limit(w) else { return "" }
        return "\(w.format(st.usage[w])) of \(w.format(l)) \(w == .writes ? "writes" : w.rawValue)"
    }
}
