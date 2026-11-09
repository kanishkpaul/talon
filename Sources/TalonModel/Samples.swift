import Foundation

/// One process at one moment. Identity is `pid` + `startTime` (pids are reused).
public struct ProcessSample: Codable, Sendable, Hashable {
    public var pid: Int32
    public var startTime: UInt64          // mach absolute time the process started
    public var responsiblePID: Int32      // the app macOS holds responsible (Safari for WebContent)
    public var uid: UInt32
    public var name: String
    public var footprint: UInt64          // bytes — the number Activity Monitor calls "Memory"
    public var cpuPercent: Double         // of one core, so 0…(cores × 100)
    public var diskWriteRate: Double      // bytes/s since the previous sweep
    public var diskWrittenTotal: UInt64   // bytes over the process lifetime
    public var parentPID: Int32           // for process-tree budgets

    public init(pid: Int32, startTime: UInt64, responsiblePID: Int32, uid: UInt32, name: String, footprint: UInt64,
                cpuPercent: Double, diskWriteRate: Double, diskWrittenTotal: UInt64, parentPID: Int32 = 0) {
        self.pid = pid; self.startTime = startTime; self.responsiblePID = responsiblePID; self.uid = uid
        self.name = name; self.footprint = footprint; self.cpuPercent = cpuPercent
        self.diskWriteRate = diskWriteRate; self.diskWrittenTotal = diskWrittenTotal; self.parentPID = parentPID
    }
}

/// Every process an app is responsible for, summed. `key` is stable across restarts
/// (the app bundle or executable path) and is what history is keyed on.
public struct AppUsage: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var name: String
    public var responsiblePID: Int32
    public var processCount: Int
    public var footprint: UInt64
    public var cpuPercent: Double
    public var diskWriteRate: Double

    public var id: String { key }

    public init(key: String, name: String, responsiblePID: Int32, processCount: Int, footprint: UInt64,
                cpuPercent: Double, diskWriteRate: Double) {
        self.key = key; self.name = name; self.responsiblePID = responsiblePID; self.processCount = processCount
        self.footprint = footprint; self.cpuPercent = cpuPercent; self.diskWriteRate = diskWriteRate
    }
}

/// The system-wide series talon records every second. Order is the storage column order —
/// append new cases at the end only.
public enum SystemSeries: String, CaseIterable, Codable, Sendable {
    case cpu              // % of total CPU capacity, 0–100
    case memUsed          // bytes: app + wired + compressed (Activity Monitor's "Memory Used")
    case memCompressed    // bytes
    case swapUsed         // bytes
    case memPressure      // 0 normal · 1 warning · 2 critical
    case diskFree         // bytes free on the Data volume
    case diskWriteRate    // bytes/s, summed over every process talon can read
    case cpuTemp          // °C, hottest CPU die sensor
    case batteryTemp      // °C
    case ssdTemp          // °C
    case thermalPressure  // 0 nominal … 4 sleeping
    case systemPower      // watts, whole machine (battery telemetry)
    case batteryCharge    // %
    case processCount

    public enum Unit: String, Sendable { case percent, bytes, bytesPerSecond, celsius, watts, level, count }

    public var unit: Unit {
        switch self {
        case .cpu, .batteryCharge: .percent
        case .memUsed, .memCompressed, .swapUsed, .diskFree: .bytes
        case .diskWriteRate: .bytesPerSecond
        case .cpuTemp, .batteryTemp, .ssdTemp: .celsius
        case .systemPower: .watts
        case .memPressure, .thermalPressure: .level
        case .processCount: .count
        }
    }

    /// Multiply a value by this before storing it as an integer. Small integers are 1–3 byte
    /// varints in SQLite; fractional REALs are 8 bytes.
    public var storageScale: Double {
        switch unit {
        case .percent, .celsius: 100           // centi-units
        case .bytes, .bytesPerSecond: 1 / 1024 // KiB
        case .watts: 1000                      // mW
        case .level, .count: 1
        }
    }

    public var label: String {
        switch self {
        case .cpu: "CPU"
        case .memUsed: "Memory used"
        case .memCompressed: "Compressed"
        case .swapUsed: "Swap"
        case .memPressure: "Memory pressure"
        case .diskFree: "Free space"
        case .diskWriteRate: "SSD writes"
        case .cpuTemp: "CPU temp"
        case .batteryTemp: "Battery temp"
        case .ssdTemp: "SSD temp"
        case .thermalPressure: "Thermal pressure"
        case .systemPower: "System power"
        case .batteryCharge: "Battery"
        case .processCount: "Processes"
        }
    }

    public func format(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        switch unit {
        case .percent: return String(format: "%.0f%%", v)
        case .bytes: return ByteSize.format(v)
        case .bytesPerSecond: return ByteSize.format(v) + "/s"
        case .celsius: return String(format: "%.1f °C", v)
        case .watts: return String(format: "%.1f W", v)
        case .level:
            switch self {
            case .memPressure: return MemoryPressure(rawValue: Int(v.rounded()))?.label ?? "\(Int(v))"
            default: return ThermalPressure(rawValue: Int(v.rounded()))?.label ?? "\(Int(v))"
            }
        case .count: return String(Int(v.rounded()))
        }
    }
}

/// One reading of every `SystemSeries`. Unavailable readings are NaN.
public struct SystemSample: Codable, Sendable, Equatable {
    public var time: TimeInterval   // unix seconds
    public var values: [Double]

    public init(time: TimeInterval, values: [Double] = Array(repeating: .nan, count: SystemSeries.allCases.count)) {
        self.time = time
        self.values = values
    }

    public subscript(_ s: SystemSeries) -> Double {
        get { values[SystemSeries.index(of: s)] }
        set { values[SystemSeries.index(of: s)] = newValue }
    }

    // NaN != NaN, so compare bit patterns.
    public static func == (a: SystemSample, b: SystemSample) -> Bool {
        a.time == b.time && a.values.map(\.bitPattern) == b.values.map(\.bitPattern)
    }
}

extension SystemSeries {
    private static let indices: [SystemSeries: Int] = Dictionary(
        uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })
    public static func index(of s: SystemSeries) -> Int { indices[s]! }
}

public enum MemoryPressure: Int, Codable, Sendable {
    case normal = 0, warning = 1, critical = 2
    public var label: String { switch self { case .normal: "normal"; case .warning: "warning"; case .critical: "critical" } }
    /// From `kern.memorystatus_vm_pressure_level` (1, 2, 4).
    public init(kernelLevel: Int) { self = kernelLevel >= 4 ? .critical : kernelLevel >= 2 ? .warning : .normal }
}

public enum ThermalPressure: Int, Codable, Sendable {
    case nominal = 0, moderate, heavy, trapping, sleeping
    public var label: String {
        switch self {
        case .nominal: "nominal"; case .moderate: "moderate"; case .heavy: "heavy"
        case .trapping: "trapping"; case .sleeping: "sleeping"
        }
    }
}

/// One full sweep: every readable process, and the same processes grouped by responsible app.
public struct ProcessSnapshot: Codable, Sendable {
    public var time: TimeInterval
    public var processes: [ProcessSample]
    public var apps: [AppUsage]
    public var readable: Int     // processes talon could read
    public var denied: Int       // processes it couldn't (root/system ones, when not running as root)
    public var sweepSeconds: Double

    public init(time: TimeInterval, processes: [ProcessSample], apps: [AppUsage], readable: Int, denied: Int,
                sweepSeconds: Double) {
        self.time = time; self.processes = processes; self.apps = apps
        self.readable = readable; self.denied = denied; self.sweepSeconds = sweepSeconds
    }
}
