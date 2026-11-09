import Foundation

/// One downsampled bucket. A 1 s point has min == avg == max.
public struct HistoryPoint: Codable, Sendable, Equatable {
    public var time: TimeInterval
    public var min: Double
    public var avg: Double
    public var max: Double

    public init(time: TimeInterval, min: Double, avg: Double, max: Double) {
        self.time = time; self.min = min; self.avg = avg; self.max = max
    }
}

/// Which stored resolution answered a history query.
public enum HistoryTier: String, Codable, Sendable {
    case live = "1s"     // daemon RAM, last hour
    case tenSeconds = "10s"
    case minute = "1m"
    case hour = "1h"
}

public struct HistorySeries: Codable, Sendable {
    public var series: SystemSeries
    public var tier: HistoryTier
    public var points: [HistoryPoint]

    public init(series: SystemSeries, tier: HistoryTier, points: [HistoryPoint]) {
        self.series = series; self.tier = tier; self.points = points
    }
}

/// An app's totals over a time range, from the per-app tiers.
public struct AppTotal: Codable, Sendable, Equatable {
    public var key: String
    public var name: String
    public var cpuSeconds: Double
    public var memoryPeak: UInt64
    public var memoryAverage: UInt64
    public var bytesWritten: UInt64

    public init(key: String, name: String, cpuSeconds: Double, memoryPeak: UInt64, memoryAverage: UInt64,
                bytesWritten: UInt64) {
        self.key = key; self.name = name; self.cpuSeconds = cpuSeconds; self.memoryPeak = memoryPeak
        self.memoryAverage = memoryAverage; self.bytesWritten = bytesWritten
    }
}

/// One app over time, from the per-app tiers.
public struct AppPoint: Codable, Sendable, Equatable {
    public var time: TimeInterval
    public var memoryAverage: Double   // bytes
    public var memoryPeak: Double      // bytes
    public var cpuPercent: Double      // average over the bucket, % of one core
    public var writeRate: Double       // average bytes/s over the bucket

    public init(time: TimeInterval, memoryAverage: Double, memoryPeak: Double, cpuPercent: Double, writeRate: Double) {
        self.time = time; self.memoryAverage = memoryAverage; self.memoryPeak = memoryPeak
        self.cpuPercent = cpuPercent; self.writeRate = writeRate
    }
}

/// The hardware's long-term numbers, recorded once a day: the trend lines behind Health.
public struct HealthDay: Codable, Sendable, Equatable, Identifiable {
    public var day: String                 // yyyy-MM-dd, local time
    public var time: TimeInterval          // when this row was last refreshed
    public var cycleCount: Int?
    public var designCapacity: Int?
    public var nominalCapacity: Int?
    public var fullChargeCapacity: Int?
    public var ssdBytesWritten: UInt64?
    public var ssdBytesRead: UInt64?
    public var ssdPercentUsed: Int?
    public var unsafeShutdowns: UInt64?
    public var powerCycles: UInt64?
    public var mediaErrors: UInt64?

    public var id: String { day }

    public init(day: String, time: TimeInterval, battery: BatteryHealth?, ssd: SSDHealth?) {
        self.day = day; self.time = time
        cycleCount = battery?.cycleCount; designCapacity = battery?.designCapacity
        nominalCapacity = battery?.nominalCapacity; fullChargeCapacity = battery?.fullChargeCapacity
        ssdBytesWritten = ssd?.bytesWritten; ssdBytesRead = ssd?.bytesRead; ssdPercentUsed = ssd?.percentUsed
        unsafeShutdowns = ssd?.unsafeShutdowns; powerCycles = ssd?.powerCycles; mediaErrors = ssd?.mediaErrors
    }

    public var batteryHealthPercent: Double? {
        guard let n = nominalCapacity, let d = designCapacity, d > 0 else { return nil }
        return 100 * Double(n) / Double(d)
    }

    public static func dayString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

public enum AppMetric: String, Codable, Sendable, CaseIterable {
    case cpu, memory, disk
}

/// Something worth remembering forever: a ceiling crossed, a process frozen, a kill.
public struct TalonEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case daemonStarted, daemonStopped, memoryCapSet, frozen, thawed, killed, thermalChange, memoryPressureChange
        case ceilingWarning, ceilingAction, ceilingChanged
        case throttling, unsafeShutdown
    }

    public var time: TimeInterval
    public var kind: Kind
    public var pid: Int32?
    public var appKey: String?
    public var message: String

    public init(time: TimeInterval, kind: Kind, pid: Int32? = nil, appKey: String? = nil, message: String) {
        self.time = time; self.kind = kind; self.pid = pid; self.appKey = appKey; self.message = message
    }
}

/// Bucket-reduce a series to at most `maxPoints`, keeping each bucket's true min and max so
/// spikes survive downsampling.
public func downsample(_ points: [HistoryPoint], maxPoints: Int) -> [HistoryPoint] {
    guard maxPoints > 0, points.count > maxPoints else { return points }
    let per = Double(points.count) / Double(maxPoints)
    var out: [HistoryPoint] = []
    out.reserveCapacity(maxPoints)
    for b in 0..<maxPoints {
        let lo = Int((Double(b) * per).rounded(.down)), hi = min(points.count, Int((Double(b + 1) * per).rounded(.down)))
        guard lo < hi else { continue }
        var mn = Double.infinity, mx = -Double.infinity, sum = 0.0, n = 0
        for p in points[lo..<hi] where p.avg.isFinite {
            mn = Swift.min(mn, p.min); mx = Swift.max(mx, p.max); sum += p.avg; n += 1
        }
        let t = points[lo].time
        out.append(n > 0 ? HistoryPoint(time: t, min: mn, avg: sum / Double(n), max: mx)
                         : HistoryPoint(time: t, min: .nan, avg: .nan, max: .nan))
    }
    return out
}
