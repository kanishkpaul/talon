import Foundation

public struct BatteryHealth: Codable, Sendable, Equatable {
    public var cycleCount: Int
    public var designCapacity: Int        // mAh
    public var nominalCapacity: Int       // mAh — the long-term trend number
    public var fullChargeCapacity: Int    // mAh — temperature-compensated, moves day to day
    public var chargePercent: Int
    public var isCharging: Bool
    public var externalConnected: Bool
    public var voltage: Double            // V
    public var amperage: Int              // mA, negative while discharging
    public var systemPower: Double?       // W, the whole machine
    public var adapterPower: Double?      // W drawn from the charger
    public var temperature: Double?       // °C (gas gauge sensor)

    /// Raw health: nominal ÷ design. Apple's own "Maximum Capacity" figure is computed
    /// differently and usually reads a few points higher.
    public var rawHealthPercent: Double { designCapacity > 0 ? 100 * Double(nominalCapacity) / Double(designCapacity) : .nan }

    public init(cycleCount: Int, designCapacity: Int, nominalCapacity: Int, fullChargeCapacity: Int, chargePercent: Int,
                isCharging: Bool, externalConnected: Bool, voltage: Double, amperage: Int, systemPower: Double?,
                adapterPower: Double?, temperature: Double?) {
        self.cycleCount = cycleCount; self.designCapacity = designCapacity; self.nominalCapacity = nominalCapacity
        self.fullChargeCapacity = fullChargeCapacity; self.chargePercent = chargePercent; self.isCharging = isCharging
        self.externalConnected = externalConnected; self.voltage = voltage; self.amperage = amperage
        self.systemPower = systemPower; self.adapterPower = adapterPower; self.temperature = temperature
    }
}

public struct SSDHealth: Codable, Sendable, Equatable {
    public var model: String
    public var percentUsed: Int           // NVMe wear estimate
    public var availableSpare: Int
    public var spareThreshold: Int
    public var criticalWarning: Int
    public var temperature: Int           // °C
    public var bytesWritten: UInt64
    public var bytesRead: UInt64
    public var powerOnHours: UInt64       // under-reports on Apple SSDs — don't derive rates from it
    public var powerCycles: UInt64
    public var unsafeShutdowns: UInt64
    public var mediaErrors: UInt64

    public init(model: String, percentUsed: Int, availableSpare: Int, spareThreshold: Int, criticalWarning: Int,
                temperature: Int, bytesWritten: UInt64, bytesRead: UInt64, powerOnHours: UInt64, powerCycles: UInt64,
                unsafeShutdowns: UInt64, mediaErrors: UInt64) {
        self.model = model; self.percentUsed = percentUsed; self.availableSpare = availableSpare
        self.spareThreshold = spareThreshold; self.criticalWarning = criticalWarning; self.temperature = temperature
        self.bytesWritten = bytesWritten; self.bytesRead = bytesRead; self.powerOnHours = powerOnHours
        self.powerCycles = powerCycles; self.unsafeShutdowns = unsafeShutdowns; self.mediaErrors = mediaErrors
    }
}

public struct ThermalReading: Codable, Sendable, Equatable {
    public var pressure: ThermalPressure?
    public var sensors: [String: Double]  // name → °C, calibration sensors removed

    public init(pressure: ThermalPressure?, sensors: [String: Double]) {
        self.pressure = pressure
        self.sensors = sensors
    }

    /// Hottest CPU-die sensor (`PMU tdie*` on M5).
    public var cpuMax: Double? { sensors.filter { $0.key.hasPrefix("PMU tdie") }.values.max() }
    /// Hottest second-PMU die sensor (`PMU2 tdie*`).
    public var soc2Max: Double? { sensors.filter { $0.key.hasPrefix("PMU2 tdie") }.values.max() }
    public var ssd: Double? { sensors.first { $0.key.hasPrefix("NAND") }?.value }
    public var battery: Double? { sensors["gas gauge battery"] }
    public var hottest: (name: String, celsius: Double)? {
        sensors.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}

/// One CPU cluster's clock since the previous reading.
public struct ClusterClock: Codable, Sendable, Equatable {
    public var name: String      // "ECPU", "PCPU"
    public var avgMHz: Double
    public var maxMHz: Double
    public var busy: Double      // 0…1

    public init(name: String, avgMHz: Double, maxMHz: Double, busy: Double) {
        self.name = name; self.avgMHz = avgMHz; self.maxMHz = maxMHz; self.busy = busy
    }

    /// Clock as a share of the cluster's maximum. Meaningful only when the cluster is busy:
    /// an idle cluster runs slow on purpose.
    public var ratio: Double { maxMHz > 0 ? avgMHz / maxMHz : .nan }
}

public struct MemoryInfo: Codable, Sendable, Equatable {
    public var physical: UInt64
    public var used: UInt64          // app + wired + compressed
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64        // file-backed, reclaimable
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure

    public init(physical: UInt64, used: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64,
                swapUsed: UInt64, swapTotal: UInt64, pressure: MemoryPressure) {
        self.physical = physical; self.used = used; self.app = app; self.wired = wired; self.compressed = compressed
        self.cached = cached; self.swapUsed = swapUsed; self.swapTotal = swapTotal; self.pressure = pressure
    }
}

public struct DiskSpace: Codable, Sendable, Equatable {
    public var total: UInt64
    public var free: UInt64   // real free space in the container — not "available incl. purgeable"

    public init(total: UInt64, free: UInt64) { self.total = total; self.free = free }
}

public struct HealthReport: Codable, Sendable {
    public var takenAt: Date
    public var battery: BatteryHealth?
    public var ssd: SSDHealth?
    public var thermal: ThermalReading
    public var memory: MemoryInfo?
    public var disk: DiskSpace?
    public var unavailable: [String]   // which probes failed, and why

    public init(takenAt: Date, battery: BatteryHealth?, ssd: SSDHealth?, thermal: ThermalReading, memory: MemoryInfo?,
                disk: DiskSpace?, unavailable: [String]) {
        self.takenAt = takenAt; self.battery = battery; self.ssd = ssd; self.thermal = thermal
        self.memory = memory; self.disk = disk; self.unavailable = unavailable
    }
}
