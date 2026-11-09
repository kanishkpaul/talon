import Foundation
import TalonModel

/// Running min / max / mean. NaN (unavailable) readings are skipped.
public struct Accumulator: Sendable, Equatable {
    public private(set) var min = Double.infinity
    public private(set) var max = -Double.infinity
    public private(set) var sum = 0.0
    public private(set) var count = 0

    public init() {}

    public mutating func add(_ v: Double) {
        guard v.isFinite else { return }
        min = Swift.min(min, v); max = Swift.max(max, v); sum += v; count += 1
    }

    /// A one-entry accumulator standing for an already-reduced group (the folded "Other" app).
    public static func summary(avg: Double, max: Double) -> Accumulator {
        var a = Accumulator()
        a.min = avg; a.max = Swift.max(avg, max); a.sum = avg; a.count = 1
        return a
    }

    public var avg: Double { count > 0 ? sum / Double(count) : .nan }
    public var minOrNaN: Double { count > 0 ? min : .nan }
    public var maxOrNaN: Double { count > 0 ? max : .nan }
}

/// A finished system bucket: one accumulator per `SystemSeries`.
public struct SystemBucket: Sendable, Equatable {
    public var start: TimeInterval
    public var period: TimeInterval
    public var stats: [Accumulator]

    public subscript(_ s: SystemSeries) -> Accumulator { stats[SystemSeries.index(of: s)] }
}

/// Downsamples the 1 s stream into one fixed period (10 s, 1 min, 1 h) in memory. Each tier is
/// fed every raw sample directly, so each is written once and never rebuilt from another tier.
public final class SystemTier {
    public let period: TimeInterval
    private var current: SystemBucket?
    private var finished: [SystemBucket] = []

    public init(period: TimeInterval) { self.period = period }

    public func add(_ sample: SystemSample) {
        let start = (sample.time / period).rounded(.down) * period
        if let c = current, c.start != start {
            finished.append(c)
            current = nil
        }
        if current == nil {
            current = SystemBucket(start: start, period: period,
                                   stats: Array(repeating: Accumulator(), count: SystemSeries.allCases.count))
        }
        for i in sample.values.indices { current!.stats[i].add(sample.values[i]) }
    }

    /// Completed buckets since the last drain. Pass `includePartial` on shutdown.
    public func drain(includePartial: Bool = false) -> [SystemBucket] {
        var out = finished
        finished = []
        if includePartial, let c = current { out.append(c); current = nil }
        return out
    }

    /// Completed-but-unwritten buckets plus the bucket in progress — for answering queries
    /// without waiting for the next commit.
    public var pending: [SystemBucket] { finished + (current.map { [$0] } ?? []) }
}

/// Per-app totals for one bucket.
public struct AppStats: Sendable, Equatable {
    public var name: String
    public var memory = Accumulator()
    public var cpuSeconds = 0.0
    public var bytesWritten = 0.0

    public init(name: String) { self.name = name }
}

public struct AppBucket: Sendable, Equatable {
    public var start: TimeInterval
    public var period: TimeInterval
    public var apps: [String: AppStats]   // app key → stats
}

/// Per-app tiers. Only the top apps per bucket are kept; the rest fold into `AppTier.otherKey`,
/// which keeps the per-minute table to tens of rows instead of hundreds.
public final class AppTier {
    public static let otherKey = "_other"
    public let period: TimeInterval
    public let keep: Int
    private var current: AppBucket?
    private var finished: [AppBucket] = []

    public init(period: TimeInterval, keep: Int = 40) {
        self.period = period
        self.keep = keep
    }

    /// `interval` is the time since the previous sweep, so CPU % and write rates become totals.
    public func add(_ apps: [AppUsage], at time: TimeInterval, interval: TimeInterval) {
        let start = (time / period).rounded(.down) * period
        if let c = current, c.start != start {
            finished.append(trimmed(c))
            current = nil
        }
        if current == nil { current = AppBucket(start: start, period: period, apps: [:]) }
        for a in apps {
            var st = current!.apps[a.key] ?? AppStats(name: a.name)
            st.memory.add(Double(a.footprint))
            st.cpuSeconds += a.cpuPercent / 100 * interval
            st.bytesWritten += a.diskWriteRate * interval
            current!.apps[a.key] = st
        }
    }

    public func drain(includePartial: Bool = false) -> [AppBucket] {
        var out = finished
        finished = []
        if includePartial, let c = current { out.append(trimmed(c)); current = nil }
        return out
    }

    public var pending: [AppBucket] { finished + (current.map { [trimmed($0)] } ?? []) }

    /// Keep any app that is in the top `keep` by CPU, by memory, or by writes; fold the rest.
    func trimmed(_ b: AppBucket) -> AppBucket {
        guard b.apps.count > keep else { return b }
        let entries = Array(b.apps)
        var winners = Set<String>()
        for metric: (AppStats) -> Double in [{ $0.cpuSeconds }, { $0.memory.max }, { $0.bytesWritten }] {
            winners.formUnion(entries.sorted { metric($0.value) > metric($1.value) }.prefix(keep).map(\.key))
        }
        var out = AppBucket(start: b.start, period: b.period, apps: [:])
        var other = AppStats(name: "Other")
        var otherMem = 0.0, otherMemMax = 0.0
        for (k, v) in entries {
            if winners.contains(k) { out.apps[k] = v; continue }
            other.cpuSeconds += v.cpuSeconds
            other.bytesWritten += v.bytesWritten
            otherMem += v.memory.avg.isFinite ? v.memory.avg : 0
            otherMemMax += v.memory.maxOrNaN.isFinite ? v.memory.max : 0
        }
        // "Other" memory: the sum of the folded apps' averages, and of their peaks.
        other.memory = .summary(avg: otherMem, max: otherMemMax)
        out.apps[Self.otherKey] = other
        return out
    }
}

/// Fixed-capacity ring. The daemon keeps the last hour of 1 s samples here and never writes them.
public struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int) { storage = Array(repeating: nil, count: Swift.max(1, capacity)) }

    public var capacity: Int { storage.count }

    public mutating func append(_ e: Element) {
        storage[head] = e
        head = (head + 1) % storage.count
        count = Swift.min(count + 1, storage.count)
    }

    /// Oldest first.
    public var elements: [Element] {
        let start = (head - count + storage.count) % storage.count
        return (0..<count).map { storage[(start + $0) % storage.count]! }
    }

    public var last: Element? { count == 0 ? nil : storage[(head - 1 + storage.count) % storage.count] }
}
