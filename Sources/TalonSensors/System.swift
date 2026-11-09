import Darwin
import Foundation
import IOKit
import TalonModel
import TalonPrivate

/// Memory, swap, CPU load and disk space — all public, all cheap.
public enum SystemSensor {
    private static let host = mach_host_self()
    private static let pageSize = UInt64(sysconf(_SC_PAGESIZE))

    private static func sysctl<T: BitwiseCopyable>(_ name: String, _ initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    public static var physicalMemory: UInt64 { sysctl("hw.memsize", UInt64(0)) ?? 0 }
    public static var cpuCount: Int { sysctl("hw.logicalcpu", Int32(0)).map(Int.init) ?? ProcessInfo.processInfo.activeProcessorCount }

    public static func memory() -> MemoryInfo? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let app = UInt64(stats.internal_page_count &- stats.purgeable_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let cached = UInt64(stats.external_page_count &+ stats.purgeable_count) * pageSize
        let swap = sysctl("vm.swapusage", xsw_usage())
        let level = sysctl("kern.memorystatus_vm_pressure_level", Int32(1)) ?? 1
        return MemoryInfo(physical: physicalMemory, used: app + wired + compressed, app: app, wired: wired,
                          compressed: compressed, cached: cached, swapUsed: swap?.xsu_used ?? 0,
                          swapTotal: swap?.xsu_total ?? 0, pressure: MemoryPressure(kernelLevel: Int(level)))
    }

    /// Cumulative CPU ticks across every core. Diff two readings for a system CPU %.
    /// Per-processor counters, not HOST_CPU_LOAD_INFO: on macOS 27 the host-wide counters update in
    /// coarse steps (identical reads 200 ms apart), while the per-CPU ones advance smoothly.
    public static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &n, &info, &count) == KERN_SUCCESS, let info else { return nil }
        defer { talon_vm_deallocate(info, Int(count) * MemoryLayout<integer_t>.stride) }
        var busy: UInt64 = 0, total: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(n) {
            let base = cpu * states
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            busy += user + system + nice
            total += user + system + idle + nice
        }
        return (busy, total)
    }

    /// Free space on the Data volume — the APFS container's real free space, not counting purgeable.
    public static func disk(path: String = "/System/Volumes/Data") -> DiskSpace? {
        var s = statfs()
        guard statfs(path, &s) == 0 || statfs("/", &s) == 0 else { return nil }
        let block = UInt64(s.f_bsize)
        return DiskSpace(total: UInt64(s.f_blocks) * block, free: UInt64(s.f_bavail) * block)
    }
}

/// Temperature sensors (private HID event system) and macOS's thermal pressure level.
public enum ThermalSensor {
    public static func pressure() -> ThermalPressure? {
        var level: UInt64 = 0
        guard talon_thermal_pressure(&level) == 0 else { return nil }
        return ThermalPressure(rawValue: Int(min(level, 4)))
    }

    /// name → °C, with calibration (`tcal`) sensors removed.
    public static func temperatures() -> [String: Double] {
        guard let cf = talon_copy_temperatures(), let dict = cf as? [String: Double] else { return [:] }
        return dict.filter { !$0.key.hasSuffix("tcal") }
    }

    public static func read() -> ThermalReading { ThermalReading(pressure: pressure(), sensors: temperatures()) }
}

/// Per-cluster CPU clocks (private IOReport). The first read primes and returns an empty array.
public enum ClockSensor {
    public static func read() -> [ClusterClock]? {
        var buf = [talon_cluster_t](repeating: talon_cluster_t(), count: 8)
        var n: Int32 = 0
        guard talon_clocks_read(&buf, Int32(buf.count), &n) == 0 else { return nil }
        return buf.prefix(Int(n)).map { c in
            let name = withUnsafeBytes(of: c.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return ClusterClock(name: name, avgMHz: c.avg_mhz, maxMHz: c.max_mhz, busy: c.busy)
        }
    }
}

/// AppleSmartBattery in the IORegistry. On macOS 27 the capacities live under `BatteryData`.
public enum BatterySensor {
    private static let service: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))

    public static var present: Bool { service != 0 }

    private static func property(_ key: String) -> Any? {
        guard service != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func int(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }

    /// Signed battery current in mA (negative while discharging). The registry stores it unsigned.
    private static func amperage(_ any: Any?) -> Int? {
        (any as? NSNumber).map { Int(Int64(bitPattern: $0.uint64Value)) }
    }

    /// Whole-machine power in watts: what the adapter delivers minus what goes into the battery
    /// (on battery: voltage × discharge current). `PowerTelemetryData.SystemLoad` was found stale on
    /// battery on macOS 27 (0.5 W while the pack supplied 3.6 W), so it's only a fallback.
    static func systemPower(voltage: Int?, amperage: Int?, adapterIn: Int?, systemLoad: Int?, external: Bool) -> Double? {
        if let v = voltage, let i = amperage, v > 0 {
            let battery = Double(v) * Double(i) / 1e6          // W into the battery (negative = out of it)
            let adapter = Double(adapterIn ?? 0) / 1000
            if !external { return max(0, -battery) }
            if adapter > 0 { return max(0, adapter - battery) }
        }
        return systemLoad.map { Double($0) / 1000 }
    }

    /// The cheap per-second read: (charge %, plugged in, whole-system watts).
    public static func live() -> (charge: Int?, external: Bool?, systemPower: Double?) {
        guard service != 0 else { return (nil, nil, nil) }
        let tele = property("PowerTelemetryData") as? [String: Any]
        let external = (property("ExternalConnected") as? NSNumber)?.boolValue
        let power = systemPower(voltage: int(property("Voltage")), amperage: amperage(property("InstantAmperage")),
                                adapterIn: int(tele?["SystemPowerIn"]), systemLoad: int(tele?["SystemLoad"]),
                                external: external ?? false)
        return (int(property("CurrentCapacity")), external, power)
    }

    public static func health(temperature: Double?) -> BatteryHealth? {
        guard service != 0 else { return nil }
        var cf: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &cf, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = cf?.takeRetainedValue() as? [String: Any] else { return nil }
        let bd = p["BatteryData"] as? [String: Any] ?? [:]
        let tele = p["PowerTelemetryData"] as? [String: Any]
        let charger = p["ChargerData"] as? [String: Any]
        let amps = amperage(p["InstantAmperage"]) ?? 0
        let external = (p["ExternalConnected"] as? Bool) ?? false
        let adapterIn = int(tele?["SystemPowerIn"]).map { Double($0) / 1000 }
        return BatteryHealth(
            cycleCount: int(p["CycleCount"]) ?? 0,
            designCapacity: int(bd["DesignCapacity"]) ?? int(p["DesignCapacity"]) ?? 0,
            nominalCapacity: int(bd["NominalChargeCapacity"]) ?? int(p["NominalChargeCapacity"]) ?? 0,
            fullChargeCapacity: int(bd["FullChargeCapacity"]) ?? 0,
            chargePercent: int(p["CurrentCapacity"]) ?? 0,
            isCharging: (charger?["IsCharging"] as? NSNumber)?.boolValue ?? (p["IsCharging"] as? Bool) ?? false,
            externalConnected: external,
            voltage: Double(int(p["Voltage"]) ?? 0) / 1000,
            amperage: amps,
            systemPower: systemPower(voltage: int(p["Voltage"]), amperage: amps, adapterIn: int(tele?["SystemPowerIn"]),
                                     systemLoad: int(tele?["SystemLoad"]), external: external),
            adapterPower: adapterIn.flatMap { $0 > 0 ? $0 : nil },
            temperature: temperature)
    }
}

/// Exposes the power formula to tests.
public enum BatterySensorPowerProbe {
    public static func power(_ voltage: Int?, _ amperage: Int?, _ adapterIn: Int?, _ systemLoad: Int?, _ external: Bool) -> Double? {
        BatterySensor.systemPower(voltage: voltage, amperage: amperage, adapterIn: adapterIn, systemLoad: systemLoad, external: external)
    }
}

/// NVMe SMART through Apple's private CFPlugIn — no smartmontools, no admin.
public enum SSDSensor {
    public static func read() -> Result<SSDHealth, TalonSensorError> {
        var s = talon_smart_t()
        let rc = talon_smart_read(&s)
        guard rc == 0 else { return .failure(TalonSensorError("SMART read failed (\(rc))")) }
        let model = withUnsafeBytes(of: s.model) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return .success(SSDHealth(
            model: model.trimmingCharacters(in: .whitespaces), percentUsed: Int(s.percent_used),
            availableSpare: Int(s.available_spare), spareThreshold: Int(s.spare_threshold),
            criticalWarning: Int(s.critical_warning), temperature: Int(s.temperature_c),
            bytesWritten: s.data_units_written &* 512_000, bytesRead: s.data_units_read &* 512_000,
            powerOnHours: s.power_on_hours, powerCycles: s.power_cycles, unsafeShutdowns: s.unsafe_shutdowns,
            mediaErrors: s.media_errors))
    }
}

public struct TalonSensorError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ d: String) { description = d }
}

/// Everything in one call — used by `talon health`.
public enum HealthProbe {
    public static func report() -> HealthReport {
        var missing: [String] = []
        let thermal = ThermalSensor.read()
        if thermal.sensors.isEmpty { missing.append("temperature sensors: HID event system unavailable") }
        if thermal.pressure == nil { missing.append("thermal pressure: notify key unavailable") }
        let battery = BatterySensor.health(temperature: thermal.battery)
        if battery == nil { missing.append("battery: no AppleSmartBattery service") }
        let ssd: SSDHealth?
        switch SSDSensor.read() {
        case .success(let h): ssd = h
        case .failure(let e): ssd = nil; missing.append("ssd: \(e)")
        }
        return HealthReport(takenAt: Date(), battery: battery, ssd: ssd, thermal: thermal,
                            memory: SystemSensor.memory(), disk: SystemSensor.disk(), unavailable: missing)
    }
}
