import Foundation

/// How hard talon holds the line when a ceiling is crossed. Ordered: each rung does more.
public enum Strictness: Int, Codable, Sendable, CaseIterable, Comparable {
    case watch = 0    // mark it on the chart, nothing else
    case warn         // send a notification
    case ask          // a small glass panel: raise the ceiling, pause, or quit
    case slowDown     // background priority: efficiency cores, throttled disk I/O
    case pause        // SIGSTOP, one click resumes
    case quit         // SIGTERM, then SIGKILL after a grace period
    case hardCap      // kernel memory limit per process; the process can never exceed it

    public static func < (a: Strictness, b: Strictness) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .watch: "Watch"; case .warn: "Warn"; case .ask: "Ask"; case .slowDown: "Slow down"
        case .pause: "Pause"; case .quit: "Quit"; case .hardCap: "Hard cap"
        }
    }

    public var explanation: String {
        switch self {
        case .watch: "Mark it on the chart. Nothing else."
        case .warn: "Send a notification."
        case .ask: "Ask: raise the ceiling, pause, or quit."
        case .slowDown: "Move it to the efficiency cores and throttle its disk I/O."
        case .pause: "Freeze it in place. One click resumes it."
        case .quit: "Ask it to quit; force-quit after a grace period."
        case .hardCap: "The kernel enforces it. The process can never exceed the ceiling."
        }
    }

    /// CLI spelling: watch, warn, ask, slow, pause, quit, hard.
    public init?(name: String) {
        switch name.lowercased() {
        case "watch": self = .watch
        case "warn": self = .warn
        case "ask": self = .ask
        case "slow", "slowdown", "slow-down": self = .slowDown
        case "pause", "freeze": self = .pause
        case "quit", "kill": self = .quit
        case "hard", "hardcap", "hard-cap", "cap": self = .hardCap
        default: return nil
        }
    }
}

/// What a ceiling applies to. Processes are identified by pid *and* start time, so a reused pid is
/// never mistaken for the original.
public enum CeilingTarget: Codable, Sendable, Hashable {
    case app(key: String)                       // every process an app is responsible for
    case process(pid: Int32, start: UInt64)     // one process
    case tree(pid: Int32, start: UInt64)        // a process and all its descendants (`talon run`)

    /// Ephemeral targets disappear with their process; app ceilings persist.
    public var isEphemeral: Bool { if case .app = self { false } else { true } }
}

public enum CeilingResource: String, Codable, Sendable, CaseIterable {
    case memory, cpu, writes

    public func format(_ v: Double) -> String {
        switch self {
        case .memory: ByteSize.format(v)
        case .cpu: String(format: "%.0f%%", v)
        case .writes: ByteSize.format(v) + "/s"
        }
    }
}

public struct Ceiling: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var target: CeilingTarget
    public var label: String
    public var memory: UInt64?           // bytes, summed over the target's processes
    public var cpu: Double?              // percent of one core, summed (200 = two cores)
    public var writeRate: Double?        // bytes/s, summed
    public var strictness: Strictness
    public var warnFraction: Double      // "approaching" from here, e.g. 0.9
    public var grace: TimeInterval       // must stay over this long before talon acts
    public var quitGrace: TimeInterval   // SIGTERM → SIGKILL
    public var enabled: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), target: CeilingTarget, label: String, memory: UInt64? = nil, cpu: Double? = nil,
                writeRate: Double? = nil, strictness: Strictness, warnFraction: Double = 0.9, grace: TimeInterval = 5,
                quitGrace: TimeInterval = 10, enabled: Bool = true, createdAt: Date = Date()) {
        self.id = id; self.target = target; self.label = label; self.memory = memory; self.cpu = cpu
        self.writeRate = writeRate; self.strictness = strictness; self.warnFraction = warnFraction
        self.grace = grace; self.quitGrace = quitGrace; self.enabled = enabled; self.createdAt = createdAt
    }

    public func limit(_ r: CeilingResource) -> Double? {
        switch r {
        case .memory: memory.map { Double($0) }   // not .map(Double.init): that picks Double(bitPattern:)
        case .cpu: cpu
        case .writes: writeRate
        }
    }

    public var hasLimit: Bool { memory != nil || cpu != nil || writeRate != nil }

    public var summary: String {
        CeilingResource.allCases.compactMap { r in limit(r).map { r.format($0) } }.joined(separator: " · ")
    }
}

public struct CeilingUsage: Codable, Sendable, Equatable {
    public var memory: Double = 0
    public var cpu: Double = 0
    public var writes: Double = 0

    public init(memory: Double = 0, cpu: Double = 0, writes: Double = 0) {
        self.memory = memory; self.cpu = cpu; self.writes = writes
    }

    public subscript(_ r: CeilingResource) -> Double {
        switch r { case .memory: memory; case .cpu: cpu; case .writes: writes }
    }
}

/// A ceiling's live state, as the engine sees it.
public struct CeilingStatus: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case ok             // under the warning threshold
        case approaching    // past the warning threshold
        case over           // over the ceiling, inside the grace period
        case enforced       // talon has acted (or, for Watch/Warn, recorded it)
        case asking         // waiting for an answer in the ask panel
        case gone           // no matching processes right now
        case disabled
    }

    public var id: UUID
    public var phase: Phase
    public var usage: CeilingUsage
    public var ratio: Double                 // worst usage ÷ limit across resources
    public var worst: CeilingResource?
    public var pids: [Int32]
    public var overSince: Date?
    public var lastAction: String?

    public init(id: UUID, phase: Phase, usage: CeilingUsage, ratio: Double, worst: CeilingResource?, pids: [Int32],
                overSince: Date?, lastAction: String?) {
        self.id = id; self.phase = phase; self.usage = usage; self.ratio = ratio; self.worst = worst; self.pids = pids
        self.overSince = overSince; self.lastAction = lastAction
    }
}

/// The answers the ask panel offers.
public enum AskChoice: Codable, Sendable, Equatable {
    case raise(by: Double)    // multiply the crossed limits, e.g. 1.25
    case pause
    case quit
    case ignore               // leave it running; ask again only after it drops below the warning line
}
