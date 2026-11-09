import Darwin
import Foundation
import TalonModel
import TalonSensors

/// Sweeps every process, turns cumulative counters into rates, and groups helpers under the app
/// macOS holds responsible for them. Phase 0 measured a full sweep of ~680 processes at ~3.5 ms,
/// 0.35 % CPU at 1 Hz. Not thread-safe: own it from one queue.
public final class ProcessSampler {
    private struct Known {
        var start: UInt64
        var name: String
        var uid: UInt32
        var responsible: pid_t
        var cpuNs: UInt64
        var diskWritten: UInt64
    }

    private struct AppID { var start: UInt64; var key: String; var name: String }

    private var known: [pid_t: Known] = [:]
    private var apps: [pid_t: AppID] = [:]
    private var lastSweepNs: UInt64 = 0

    public init() {}

    private static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// One sweep. The first call has no previous counters, so its rates are zero.
    public func sweep(now: TimeInterval = Date().timeIntervalSince1970) -> ProcessSnapshot {
        let t0 = Self.nowNs()
        let elapsedNs = lastSweepNs == 0 ? 0 : t0 - lastSweepNs
        lastSweepNs = t0
        let elapsed = Double(elapsedNs) / 1e9

        let pids = ProcessSensor.allPIDs()
        var next: [pid_t: Known] = [:]
        next.reserveCapacity(pids.count)
        var samples: [ProcessSample] = []
        samples.reserveCapacity(pids.count)
        var denied = 0

        for pid in pids {
            guard let raw = ProcessSensor.read(pid) else { denied += 1; continue }
            var cpuPct = 0.0, writeRate = 0.0
            var entry: Known
            if let prev = known[pid], prev.start == raw.startTime {
                entry = prev
                if elapsed > 0 {
                    cpuPct = Double(raw.cpuNanoseconds &- prev.cpuNs) / Double(elapsedNs) * 100
                    writeRate = Double(raw.diskWritten &- prev.diskWritten) / elapsed
                }
            } else {
                // New process (or a reused pid): resolve the slow facts once.
                let info = ProcessSensor.info(pid)
                entry = Known(start: raw.startTime, name: ProcessSensor.name(pid), uid: info?.uid ?? 0,
                              responsible: ProcessSensor.responsible(pid), cpuNs: 0, diskWritten: 0)
            }
            entry.cpuNs = raw.cpuNanoseconds
            entry.diskWritten = raw.diskWritten
            next[pid] = entry
            samples.append(ProcessSample(pid: pid, startTime: raw.startTime, responsiblePID: entry.responsible,
                                         uid: entry.uid, name: entry.name, footprint: raw.footprint,
                                         cpuPercent: max(0, cpuPct), diskWriteRate: max(0, writeRate),
                                         diskWrittenTotal: raw.diskWritten))
        }
        known = next

        let grouped = group(samples)
        return ProcessSnapshot(time: now, processes: samples, apps: grouped, readable: samples.count, denied: denied,
                               sweepSeconds: Double(Self.nowNs() - t0) / 1e9)
    }

    private func group(_ samples: [ProcessSample]) -> [AppUsage] {
        var byApp: [pid_t: AppUsage] = [:]
        for s in samples {
            if byApp[s.responsiblePID] == nil {
                let id = appID(for: s.responsiblePID)
                byApp[s.responsiblePID] = AppUsage(key: id.key, name: id.name, responsiblePID: s.responsiblePID,
                                                   processCount: 0, footprint: 0, cpuPercent: 0, diskWriteRate: 0)
            }
            byApp[s.responsiblePID]!.processCount += 1
            byApp[s.responsiblePID]!.footprint += s.footprint
            byApp[s.responsiblePID]!.cpuPercent += s.cpuPercent
            byApp[s.responsiblePID]!.diskWriteRate += s.diskWriteRate
        }
        // Forget apps whose responsible process is gone.
        apps = apps.filter { known[$0.key] != nil || byApp[$0.key] != nil }
        return Array(byApp.values)
    }

    private func appID(for pid: pid_t) -> AppID {
        let start = known[pid]?.start ?? 0
        if let cached = apps[pid], cached.start == start { return cached }
        let (key, name) = ProcessSensor.appIdentity(pid)
        let id = AppID(start: start, key: key, name: name)
        apps[pid] = id
        return id
    }
}

/// Builds one `SystemSample` per tick from the cheap system sensors plus the process sweep.
public final class SystemSampler {
    private var prevTicks: (busy: UInt64, total: UInt64)?
    /// Temperatures are read every `temperatureEvery` ticks — they move slowly and the HID read is the
    /// most expensive sensor.
    public var temperatureEvery: Int
    private var tick = 0
    private var lastThermal = ThermalReading(pressure: nil, sensors: [:])

    public init(temperatureEvery: Int = 2) { self.temperatureEvery = max(1, temperatureEvery) }

    public func sample(processes: ProcessSnapshot?, now: TimeInterval = Date().timeIntervalSince1970) -> SystemSample {
        var s = SystemSample(time: now)

        if let t = SystemSensor.cpuTicks() {
            if let p = prevTicks, t.total > p.total {
                s[.cpu] = Double(t.busy - p.busy) / Double(t.total - p.total) * 100
            }
            prevTicks = t
        }
        if let m = SystemSensor.memory() {
            s[.memUsed] = Double(m.used)
            s[.memCompressed] = Double(m.compressed)
            s[.swapUsed] = Double(m.swapUsed)
            s[.memPressure] = Double(m.pressure.rawValue)
        }
        if let d = SystemSensor.disk() { s[.diskFree] = Double(d.free) }

        if tick % temperatureEvery == 0 { lastThermal = ThermalSensor.read() }
        else { lastThermal.pressure = ThermalSensor.pressure() }
        tick += 1
        s[.thermalPressure] = lastThermal.pressure.map { Double($0.rawValue) } ?? .nan
        s[.cpuTemp] = lastThermal.cpuMax ?? .nan
        s[.batteryTemp] = lastThermal.battery ?? .nan
        s[.ssdTemp] = lastThermal.ssd ?? .nan

        let battery = BatterySensor.live()
        s[.batteryCharge] = battery.charge.map(Double.init) ?? .nan
        s[.systemPower] = battery.systemPower ?? .nan

        if let p = processes {
            s[.diskWriteRate] = p.processes.reduce(0) { $0 + $1.diskWriteRate }
            s[.processCount] = Double(p.readable + p.denied)
        }
        return s
    }

    public var thermal: ThermalReading { lastThermal }
}
