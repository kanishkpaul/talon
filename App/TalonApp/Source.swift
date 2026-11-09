import Foundation
import TalonIPC
import TalonModel

/// Where the app's numbers come from. In normal use that's talond over XPC; `--demo` swaps in a
/// synthetic source so the interface can be developed and snapshotted without a running helper.
nonisolated protocol TalonSource: Sendable {
    var label: String { get }
    var isDemo: Bool { get }
    func send(_ request: TalonRequest) throws(TalonError) -> TalonReply
}

nonisolated struct XPCSource: TalonSource {
    let client: TalonClient
    var label: String { client.endpoint == .daemon ? "root daemon" : "user agent" }
    var isDemo: Bool { false }
    func send(_ request: TalonRequest) throws(TalonError) -> TalonReply { try client.send(request, timeout: 3) }

    static func connect() -> Result<XPCSource, TalonError> {
        TalonClient.connect(timeout: 1).map(XPCSource.init)
    }
}

/// Plausible, clearly-labelled fake data: a few apps with drifting usage, waves for history.
nonisolated final class DemoSource: TalonSource, @unchecked Sendable {
    var label: String { "demo data" }
    var isDemo: Bool { true }
    private let start = Date().timeIntervalSince1970
    private let lock = NSLock()
    private var frozen: Set<Int32> = []
    private var rules: [Ceiling] = [
        Ceiling(target: .app(key: "/Applications/Xcode.app"), label: "Xcode", memory: 2_800_000_000, strictness: .ask),
        Ceiling(target: .app(key: "/opt/homebrew/bin/python3.13"), label: "python3.13", cpu: 80, strictness: .slowDown),
        Ceiling(target: .app(key: "/Applications/Safari.app"), label: "Safari", memory: 3 << 30, cpu: 150, strictness: .warn),
    ]
    private var answered: Set<UUID> = []

    private struct DemoApp { var key: String; var name: String; var pid: Int32; var mem: Double; var cpu: Double; var write: Double; var helpers: [String] }
    private let apps: [DemoApp] = [
        .init(key: "/Applications/Safari.app", name: "Safari", pid: 610, mem: 1.9e9, cpu: 6, write: 40e3,
              helpers: ["Safari Web Content", "Safari Web Content", "Safari Networking", "Safari Graphics and Media"]),
        .init(key: "/Applications/Xcode.app", name: "Xcode", pid: 702, mem: 3.1e9, cpu: 14, write: 2.2e6,
              helpers: ["SourceKitService", "XCBBuildService", "swift-frontend"]),
        .init(key: "/Applications/Claude.app", name: "Claude", pid: 815, mem: 2.4e9, cpu: 3, write: 15e3,
              helpers: ["Claude Helper (Renderer)", "Claude Helper (GPU)", "Claude Helper"]),
        .init(key: "/System/Applications/Mail.app", name: "Mail", pid: 530, mem: 420e6, cpu: 0.4, write: 8e3, helpers: ["com.apple.MailServiceAgent"]),
        .init(key: "/System/Applications/Music.app", name: "Music", pid: 544, mem: 310e6, cpu: 1.2, write: 0, helpers: []),
        .init(key: "/opt/homebrew/bin/python3.13", name: "python3.13", pid: 4242, mem: 834e6, cpu: 93, write: 8.6e6, helpers: []),
        .init(key: "/System/Library/CoreServices/Finder.app", name: "Finder", pid: 498, mem: 180e6, cpu: 0.1, write: 0, helpers: []),
        .init(key: "/Applications/Ghostty.app", name: "Ghostty", pid: 901, mem: 260e6, cpu: 2.5, write: 1e3, helpers: ["zsh", "claude"]),
    ]

    private func wave(_ t: TimeInterval, period: Double, phase: Double = 0) -> Double { sin(t / period * 2 * .pi + phase) }

    private func sample(at t: TimeInterval) -> SystemSample {
        var s = SystemSample(time: t)
        s[.cpu] = 18 + 12 * wave(t, period: 90) + 6 * wave(t, period: 13, phase: 1)
        s[.memUsed] = 9.4e9 + 0.6e9 * wave(t, period: 600)
        s[.memCompressed] = 1.2e9 + 0.2e9 * wave(t, period: 900)
        s[.swapUsed] = 0.9e9 + 0.05e9 * wave(t, period: 3600)
        s[.memPressure] = 0
        s[.diskFree] = 231e9 - (t - start) * 2e3
        s[.diskWriteRate] = max(0, 1.1e6 + 0.9e6 * wave(t, period: 45))
        s[.cpuTemp] = 47 + 6 * wave(t, period: 120) + 2 * wave(t, period: 11)
        s[.batteryTemp] = 31.5
        s[.ssdTemp] = 38 + wave(t, period: 300)
        s[.thermalPressure] = 0
        s[.systemPower] = 6.5 + 3.5 * wave(t, period: 90) + wave(t, period: 7)
        s[.batteryCharge] = 80
        s[.processCount] = 566
        return s
    }

    func send(_ request: TalonRequest) throws(TalonError) -> TalonReply {
        let now = Date().timeIntervalSince1970
        switch request {
        case .hello:
            return .hello(protocolVersion: talonProtocolVersion, daemonVersion: talonVersion)
        case .status:
            return .status(DaemonStatus(version: talonVersion, protocolVersion: talonProtocolVersion, pid: 377, euid: 0,
                                        allowedUID: 501, startedAt: Date(timeIntervalSince1970: start - 86_400 * 3),
                                        ownCPUPercent: 0.48, ownFootprint: 5_600_000, ownBytesWritten: 41_000_000,
                                        databasePath: "/Library/Application Support/Talon/talon.sqlite",
                                        databaseBytes: 38_000_000, readableProcesses: 566, deniedProcesses: 0,
                                        lastSweepMillis: 3.4, frozen: lock.withLock { frozen.sorted() }, latest: sample(at: now)))
        case .processes:
            return .processes(processes(at: now))
        case .health:
            return .health(health())
        case .history(let series, let range, let maxPoints):
            let n = max(2, min(maxPoints, 600))
            let step = range / Double(n)
            let pts = (0..<n).map { i -> HistoryPoint in
                let t = now - range + Double(i) * step
                // Compress time so any range shows a few readable cycles rather than aliasing.
                let v = sample(at: now - (now - t) * min(1, 1200 / range))[series]
                let jitter = abs(v) * (range > 3600 ? 0.12 : 0.02)
                return HistoryPoint(time: t, min: v - jitter, avg: v, max: v + jitter)
            }
            return .history(HistorySeries(series: series, tier: range <= 3600 ? .live : range <= 172_800 ? .tenSeconds : .minute, points: pts))
        case .topApps(let range, let metric, let limit):
            let totals = apps.map { a in
                AppTotal(key: a.key, name: a.name, cpuSeconds: a.cpu / 100 * range, memoryPeak: UInt64(a.mem * 1.3),
                         memoryAverage: UInt64(a.mem), bytesWritten: UInt64(a.write * range * 0.03))   // apps are mostly idle
            }
            return .topApps(Array(totals.sorted {
                switch metric {
                case .cpu: $0.cpuSeconds > $1.cpuSeconds
                case .memory: $0.memoryPeak > $1.memoryPeak
                case .disk: $0.bytesWritten > $1.bytesWritten
                }
            }.prefix(limit)))
        case .events:
            return .events([
                TalonEvent(time: now - 7200, kind: .daemonStarted, message: "talond 0.1.0 started as uid 0, serving uid 501"),
                TalonEvent(time: now - 1800, kind: .thermalChange, message: "thermal pressure nominal → moderate"),
                TalonEvent(time: now - 1500, kind: .thermalChange, message: "thermal pressure moderate → nominal"),
            ])
        case .capMemory(let pid, let bytes):
            return .ok("hard memory ceiling of \(ByteSize.format(bytes)) set on pid \(pid) (demo)")
        case .memoryLimit:
            return .memoryLimit(activeMB: -1, inactiveMB: -1, fatal: false)
        case .freeze(let pid):
            lock.withLock { _ = frozen.insert(pid) }
            return .ok("paused pid \(pid) (demo)")
        case .thaw(let pid):
            lock.withLock { _ = frozen.remove(pid) }
            return .ok("resumed pid \(pid) (demo)")
        case .ceilings:
            let snap = processes(at: now)
            return lock.withLock { .ceilings(rules, rules.map { status($0, snap) }) }
        case .setCeiling(let c):
            lock.withLock {
                if let i = rules.firstIndex(where: { $0.id == c.id }) { rules[i] = c } else { rules.append(c) }
                answered.remove(c.id)
            }
            return .ok("\(c.label): ceiling set — \(c.summary) · \(c.strictness.label) (demo)")
        case .removeCeiling(let id):
            lock.withLock { rules.removeAll { $0.id == id } }
            return .ok("removed (demo)")
        case .answer(let id, let choice):
            lock.withLock {
                answered.insert(id)
                if case .raise(let f) = choice, let i = rules.firstIndex(where: { $0.id == id }) {
                    rules[i].memory = rules[i].memory.map { UInt64(Double($0) * f) }
                    rules[i].cpu = rules[i].cpu.map { $0 * f }
                }
            }
            return .ok("answered (demo)")
        }
    }

    /// A simplified engine for the demo: phase from the current ratio, no timers.
    private func status(_ r: Ceiling, _ snap: ProcessSnapshot) -> CeilingStatus {
        guard case .app(let key) = r.target, let a = snap.apps.first(where: { $0.key == key }) else {
            return CeilingStatus(id: r.id, phase: .gone, usage: .init(), ratio: 0, worst: nil, pids: [], overSince: nil, lastAction: nil)
        }
        let u = CeilingUsage(memory: Double(a.footprint), cpu: a.cpuPercent, writes: a.diskWriteRate)
        var ratio = 0.0, worst: CeilingResource?
        for res in CeilingResource.allCases { if let l = r.limit(res), u[res] / l > ratio { ratio = u[res] / l; worst = res } }
        let phase: CeilingStatus.Phase, action: String?
        if !r.enabled { phase = .disabled; action = nil }
        else if ratio >= 1 {
            switch r.strictness {
            case .ask where !answered.contains(r.id): phase = .asking; action = "asked"
            case .slowDown: phase = .enforced; action = "slowed down"
            default: phase = .enforced; action = answered.contains(r.id) ? "ignored" : "notified"
            }
        } else { phase = ratio >= r.warnFraction ? .approaching : .ok; action = nil }
        return CeilingStatus(id: r.id, phase: phase, usage: u, ratio: ratio, worst: worst,
                             pids: snap.processes.filter { $0.responsiblePID == a.responsiblePID }.map(\.pid),
                             overSince: ratio >= 1 ? Date().addingTimeInterval(-12) : nil, lastAction: action)
    }

    private func processes(at t: TimeInterval) -> ProcessSnapshot {
        var procs: [ProcessSample] = []
        var usage: [AppUsage] = []
        for (i, a) in apps.enumerated() {
            let drift = 1 + 0.08 * wave(t, period: 30 + Double(i) * 7, phase: Double(i))
            let parts = 1 + a.helpers.count
            var total = AppUsage(key: a.key, name: a.name, responsiblePID: a.pid, processCount: parts, footprint: 0, cpuPercent: 0, diskWriteRate: 0)
            for (j, name) in ([a.name] + a.helpers).enumerated() {
                let share = j == 0 ? 0.5 : 0.5 / Double(max(1, a.helpers.count))
                let p = ProcessSample(pid: a.pid + Int32(j), startTime: UInt64(a.pid), responsiblePID: a.pid, uid: 501, name: name,
                                      footprint: UInt64(a.mem * share * drift), cpuPercent: a.cpu * share * drift,
                                      diskWriteRate: a.write * share * drift, diskWrittenTotal: UInt64(a.write * 3600))
                procs.append(p)
                total.footprint += p.footprint
                total.cpuPercent += p.cpuPercent
                total.diskWriteRate += p.diskWriteRate
            }
            usage.append(total)
        }
        return ProcessSnapshot(time: t, processes: procs, apps: usage, readable: procs.count, denied: 0, sweepSeconds: 0.0034)
    }

    private func health() -> HealthReport {
        HealthReport(
            takenAt: Date(),
            battery: BatteryHealth(cycleCount: 99, designCapacity: 4629, nominalCapacity: 4319, fullChargeCapacity: 4176,
                                   chargePercent: 80, isCharging: false, externalConnected: false, voltage: 12.3, amperage: -540,
                                   systemPower: 6.6, adapterPower: nil, temperature: 31.5),
            ssd: SSDHealth(model: "APPLE SSD AP0512Z", percentUsed: 0, availableSpare: 100, spareThreshold: 99, criticalWarning: 0,
                           temperature: 38, bytesWritten: 12_080_000_000_000, bytesRead: 32_940_000_000_000, powerOnHours: 266,
                           powerCycles: 129, unsafeShutdowns: 20, mediaErrors: 0),
            thermal: ThermalReading(pressure: .nominal, sensors: ["PMU tdie1": 48.2, "PMU tdie8": 51.0, "PMU2 tdie1": 44.0,
                                                                   "NAND CH0 temp": 38.0, "gas gauge battery": 31.5]),
            memory: MemoryInfo(physical: 17_179_869_184, used: 9_400_000_000, app: 5_900_000_000, wired: 2_300_000_000,
                               compressed: 1_200_000_000, cached: 3_100_000_000, swapUsed: 900_000_000, swapTotal: 2_147_483_648,
                               pressure: .normal),
            disk: DiskSpace(total: 494_000_000_000, free: 231_000_000_000),
            unavailable: [])
    }
}
