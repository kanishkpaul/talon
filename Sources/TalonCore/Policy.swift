import Darwin
import Foundation
import TalonModel
import TalonPrivate
import TalonSensors

/// What the helper knows about a process it's been asked to act on.
public struct TargetFacts: Sendable, Equatable {
    public var pid: pid_t
    public var uid: uid_t
    public var name: String
    public var stopped: Bool

    public init(pid: pid_t, uid: uid_t, name: String, stopped: Bool = false) {
        self.pid = pid; self.uid = uid; self.name = name; self.stopped = stopped
    }

    public static func lookup(_ pid: pid_t) -> TargetFacts? {
        guard pid > 0, let info = ProcessSensor.info(pid) else { return nil }
        return TargetFacts(pid: pid, uid: info.uid, name: ProcessSensor.name(pid), stopped: info.stopped)
    }
}

public enum PolicyDecision: Equatable, Sendable {
    case allow
    case refuse(String)
}

/// "May this caller touch this process?" — a pure function, so every rule is unit-tested without
/// root. The helper only ever acts on the allowed user's own processes, which `kill(2)` would
/// already let that user do: it adds the kernel ceiling, never new reach.
public struct TargetPolicy: Sendable {
    public var allowedUID: uid_t
    public var selfPID: pid_t

    /// Never touched, even if somehow owned by the user.
    public static let protectedNames: Set<String> = [
        "launchd", "kernel_task", "WindowServer", "loginwindow", "talond", "logd", "opendirectoryd",
    ]

    public init(allowedUID: uid_t, selfPID: pid_t = getpid()) {
        self.allowedUID = allowedUID
        self.selfPID = selfPID
    }

    public func check(callerUID: uid_t, target: TargetFacts?) -> PolicyDecision {
        guard callerUID == allowedUID || callerUID == 0 else {
            return .refuse("caller uid \(callerUID) isn't the user this helper serves (\(allowedUID))")
        }
        guard let t = target else { return .refuse("no such process") }
        guard t.pid > 1 else { return .refuse("pid \(t.pid) is the kernel or launchd") }
        guard t.pid != selfPID else { return .refuse("talond doesn't act on itself") }
        guard t.uid == allowedUID else {
            return .refuse("pid \(t.pid) (\(t.name)) belongs to uid \(t.uid), not you (\(allowedUID))")
        }
        guard !Self.protectedNames.contains(t.name) else { return .refuse("\(t.name) is a protected system process") }
        return .allow
    }
}

/// The verbs that change another process. Each re-resolves its target right before acting.
public struct Enforcer: Sendable {
    public var policy: TargetPolicy
    public var lookup: @Sendable (pid_t) -> TargetFacts?

    public init(policy: TargetPolicy, lookup: @escaping @Sendable (pid_t) -> TargetFacts? = TargetFacts.lookup) {
        self.policy = policy
        self.lookup = lookup
    }

    public enum Outcome: Error, Equatable, Sendable {
        case done(String)
        case refused(String)
        case failed(String)
    }

    private func authorize(_ caller: uid_t, _ pid: pid_t) -> Result<TargetFacts, Outcome> {
        let target = lookup(pid)
        switch policy.check(callerUID: caller, target: target) {
        case .allow: return .success(target!)
        case .refuse(let why): return .failure(.refused("refused: \(why)"))
        }
    }

    /// Kernel-enforced memory ceiling on a running process (needs talond running as root).
    public func capMemory(caller: uid_t, pid: pid_t, bytes: UInt64) -> Outcome {
        let t: TargetFacts
        switch authorize(caller, pid) { case .success(let f): t = f; case .failure(let o): return o }
        let mb = Int32(clamping: (bytes + (1 << 20) - 1) >> 20)
        guard mb >= 16 else { return .refused("refused: a ceiling under 16 MB would kill almost anything instantly") }
        let rc = talon_set_memory_limit(pid, mb)
        if rc == 0 { return .done("hard memory ceiling of \(ByteSize.format(UInt64(mb) << 20)) set on \(t.name) (pid \(pid))") }
        if rc == EPERM { return .failed("the kernel refused (EPERM) — kernel ceilings on running apps need talond as root (`sudo make install`)") }
        return .failed("memorystatus_control failed: \(String(cString: strerror(rc)))")
    }

    public func freeze(caller: uid_t, pid: pid_t) -> Outcome {
        let t: TargetFacts
        switch authorize(caller, pid) { case .success(let f): t = f; case .failure(let o): return o }
        guard kill(pid, SIGSTOP) == 0 else { return .failed("SIGSTOP failed: \(String(cString: strerror(errno)))") }
        return .done("paused \(t.name) (pid \(pid)) — `talon thaw \(pid)` resumes it")
    }

    public func thaw(caller: uid_t, pid: pid_t) -> Outcome {
        let t: TargetFacts
        switch authorize(caller, pid) { case .success(let f): t = f; case .failure(let o): return o }
        guard kill(pid, SIGCONT) == 0 else { return .failed("SIGCONT failed: \(String(cString: strerror(errno)))") }
        return .done("resumed \(t.name) (pid \(pid))")
    }
}
