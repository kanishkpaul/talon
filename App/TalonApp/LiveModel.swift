import AppKit
import Observation
import UserNotifications
import WidgetKit
import TalonIPC
import TalonModel

enum Connection: Equatable {
    case connecting
    case connected(String)        // "root daemon" / "user agent" / "demo data"
    case unavailable(String)

    var isLive: Bool { if case .connected = self { true } else { false } }
}

/// The app's single source of truth. Polls talond — once a second while the panel or a window is
/// open, every five seconds otherwise (just enough for the menu bar icon) — and keeps the last
/// 15 minutes of system samples locally so sparklines never need a history round-trip.
@Observable
final class LiveModel {
    static let shared = LiveModel(demo: CommandLine.arguments.contains("--demo"))

    private(set) var connection: Connection = .connecting
    private(set) var status: DaemonStatus?
    private(set) var recent: [SystemSample] = []
    private(set) var snapshot: ProcessSnapshot?
    private(set) var health: HealthReport?
    private(set) var topWriters: [AppTotal] = []
    private(set) var isDemo: Bool
    private(set) var insights: [Insight] = []
    private(set) var ceilings: [Ceiling] = []
    private(set) var ceilingStates: [UUID: CeilingStatus] = [:]
    /// Each ceiling's usage over the last five minutes, for the drag-to-set chart.
    private(set) var ceilingHistory: [UUID: [(Date, CeilingUsage)]] = [:]
    /// Set by views that want the window to switch pane (e.g. "Add ceiling" in Processes).
    var requestedPane: MainWindow.Pane?
    var selectedCeiling: UUID?

    var asking: [Ceiling] { ceilings.filter { ceilingStates[$0.id]?.phase == .asking } }

    var latest: SystemSample? { recent.last ?? status?.latest }

    @ObservationIgnored private var source: (any TalonSource)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var lastSlow: Date = .distantPast
    @ObservationIgnored private let window: TimeInterval = 15 * 60

    init(demo: Bool) {
        isDemo = demo
        if demo {
            let s = DemoSource()
            source = s
            connection = .connected(s.label)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            if let self, let demo = self.source { await self.seedRecent(from: demo) }
            while !Task.isCancelled {
                guard let self else { return }
                let pause = await self.poll()
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    /// Views call these in onAppear / onDisappear so polling speeds up only while someone is looking.
    func beginViewing() {
        viewers += 1
        if viewers == 1 { Task { _ = await poll(force: true) } }
    }

    func endViewing() { viewers = max(0, viewers - 1) }

    // MARK: - Polling

    private func poll(force: Bool = false) async -> TimeInterval {
        guard let source = await ensureSource() else { return 5 }
        let wantsProcesses = viewers > 0
        let wantsSlow = force || Date().timeIntervalSince(lastSlow) > 60

        let result = await Task.detached(priority: .utility) { () -> Result<Fetched, TalonError> in
            do throws(TalonError) {
                var f = Fetched()
                if case .status(let s) = try source.send(.status) { f.status = s }
                if case .ceilings(let c, let st) = try source.send(.ceilings) { f.ceilings = (c, st) }
                if wantsProcesses, case .processes(let p) = try source.send(.processes) { f.snapshot = p }
                if wantsSlow {
                    if case .health(let h) = try source.send(.health) { f.health = h }
                    if case .topApps(let a) = try source.send(.topApps(range: 86_400, by: .disk, limit: 8)) { f.writers = a }
                    if case .care(let c) = try source.send(.care) { f.insights = c }
                }
                return .success(f)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let f):
            if let s = f.status {
                status = s
                if let sample = s.latest, sample.time != recent.last?.time {
                    recent.append(sample)
                    let cutoff = sample.time - window
                    if let first = recent.firstIndex(where: { $0.time >= cutoff }), first > 0 { recent.removeFirst(first) }
                }
            }
            if let p = f.snapshot { snapshot = p }
            if let (rules, states) = f.ceilings { updateCeilings(rules, states) }
            if wantsSlow, f.health != nil {
                health = f.health
                topWriters = f.writers
                insights = f.insights
                notifyInsights(f.insights)
                writeWidgetSnapshot()
                lastSlow = Date()
            }
            return viewers > 0 ? 1 : 5
        case .failure(let e):
            self.source = nil
            connection = .unavailable(e.message)
            return 5
        }
    }

    private struct Fetched: Sendable {
        var status: DaemonStatus?
        var snapshot: ProcessSnapshot?
        var health: HealthReport?
        var writers: [AppTotal] = []
        var ceilings: ([Ceiling], [CeilingStatus])?
        var insights: [Insight] = []
    }

    /// The widget's data. Written once a minute (with the slow poll); WidgetKit is nudged to reload.
    private func writeWidgetSnapshot() {
        guard !isDemo, let s = latest else { return }
        let top = insights.first { $0.severity >= .watch }
        let snap = WidgetSnapshot(time: Date(), connected: connection.isLive, cpu: s[.cpu], memUsed: s[.memUsed],
                                  memTotal: Double(health?.memory?.physical ?? 0), memPressure: Int(s[.memPressure].isFinite ? s[.memPressure] : 0),
                                  cpuTemp: s[.cpuTemp], thermalPressure: Int(s[.thermalPressure].isFinite ? s[.thermalPressure] : 0),
                                  power: s[.systemPower], battery: s[.batteryCharge], swap: s[.swapUsed], diskFree: s[.diskFree],
                                  careTitle: top?.title, careSeverity: top?.severity.rawValue, asking: asking.count)
        do {
            try snap.write()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            NSLog("talon: widget snapshot not written: \(error)")
        }
    }

    /// "Act" insights become a notification, at most once a week each.
    private func notifyInsights(_ list: [Insight]) {
        guard !isDemo else { return }
        let defaults = UserDefaults.standard
        var sent = defaults.dictionary(forKey: "notifiedInsights") as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        for i in list where i.severity == .act {
            if let last = sent[i.id], now - last < 7 * 86_400 { continue }
            sent[i.id] = now
            let content = UNMutableNotificationContent()
            content.title = i.title
            content.body = i.suggestion.map { "\(i.detail) \($0)" } ?? i.detail
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { return }
                center.add(UNNotificationRequest(identifier: "care-\(i.id)", content: content, trigger: nil))
            }
        }
        defaults.set(sent, forKey: "notifiedInsights")
    }

    // MARK: - Ceilings

    private func updateCeilings(_ rules: [Ceiling], _ states: [CeilingStatus]) {
        let old = ceilingStates
        ceilings = rules
        ceilingStates = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        let now = Date()
        for st in states {
            var h = ceilingHistory[st.id] ?? []
            h.append((now, st.usage))
            h.removeAll { now.timeIntervalSince($0.0) > 300 }
            ceilingHistory[st.id] = h
        }
        ceilingHistory = ceilingHistory.filter { ceilingStates[$0.key] != nil }
        for rule in rules { notifyIfNeeded(rule, from: old[rule.id]?.phase, to: ceilingStates[rule.id]) }
    }

    /// Warn and stricter rungs notify when a ceiling starts approaching and when talon acts.
    private func notifyIfNeeded(_ rule: Ceiling, from: CeilingStatus.Phase?, to status: CeilingStatus?) {
        guard let status, let from, from != status.phase, rule.strictness >= .warn, !isDemo else { return }
        let body: String
        switch status.phase {
        case .approaching: body = "Approaching its ceiling — \(Self.describe(rule, status))."
        case .enforced: body = "Over its ceiling — \(Self.describe(rule, status)). Talon \(status.lastAction ?? "acted")."
        case .asking: body = "Over its ceiling — \(Self.describe(rule, status)). Raise it, pause, or quit?"
        default: return
        }
        let content = UNMutableNotificationContent()
        content.title = rule.label
        content.body = body
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: "\(rule.id)-\(status.phase.rawValue)", content: content, trigger: nil))
        }
    }

    static func describe(_ rule: Ceiling, _ s: CeilingStatus) -> String {
        guard let w = s.worst, let l = rule.limit(w) else { return "" }
        return "\(w.format(s.usage[w])) of \(w.format(l))"
    }

    func save(_ c: Ceiling) async -> Result<String, TalonError> {
        if let i = ceilings.firstIndex(where: { $0.id == c.id }) { ceilings[i] = c } else { ceilings.append(c) }  // optimistic
        return await perform(.setCeiling(c))
    }

    func remove(_ c: Ceiling) async -> Result<String, TalonError> {
        ceilings.removeAll { $0.id == c.id }
        return await perform(.removeCeiling(id: c.id))
    }

    func answer(_ c: Ceiling, _ choice: AskChoice) async -> Result<String, TalonError> {
        await perform(.answer(id: c.id, choice: choice))
    }

    /// A starting ceiling for an app: 1.5× what it uses now, rounded up, Warn.
    func newCeiling(for app: AppUsage) -> Ceiling {
        if let existing = ceilings.first(where: { $0.target == .app(key: app.key) }) { return existing }
        let step: UInt64 = 256 << 20
        let mem = max(step, (UInt64(Double(app.footprint) * 1.5) + step - 1) / step * step)
        return Ceiling(target: .app(key: app.key), label: app.name, memory: mem, strictness: .warn)
    }

    func open(ceilingFor app: AppUsage) {
        let c = newCeiling(for: app)
        selectedCeiling = c.id
        requestedPane = .ceilings
        if !ceilings.contains(where: { $0.id == c.id }) { Task { _ = await save(c) } }
    }

    private func ensureSource() async -> (any TalonSource)? {
        if let source { return source }
        let result = await Task.detached(priority: .utility) { XPCSource.connect() }.value
        switch result {
        case .success(let s):
            source = s
            connection = .connected(s.label)
            await seedRecent(from: s)
            return s
        case .failure(let e):
            connection = .unavailable(e.message)
            return nil
        }
    }

    /// On connect, back-fill the local window from talond's 1 s ring so sparklines start full.
    private func seedRecent(from source: any TalonSource) async {
        let window = self.window
        let series: [SystemSeries] = SystemSeries.allCases
        let samples = await Task.detached(priority: .utility) { () -> [SystemSample] in
            var byTime: [TimeInterval: SystemSample] = [:]
            for s in series {
                guard case .history(let h)? = try? source.send(.history(series: s, range: window, maxPoints: 900)) else { continue }
                for p in h.points {
                    let t = p.time.rounded()
                    var sample = byTime[t] ?? SystemSample(time: t)
                    sample[s] = p.avg
                    byTime[t] = sample
                }
            }
            return byTime.values.sorted { $0.time < $1.time }
        }.value
        if !samples.isEmpty { recent = samples }
    }

    func connectNow() {
        Task {
            if case .unavailable = connection { connection = .connecting }
            _ = await poll(force: true)
        }
    }

    // MARK: - Requests for views

    func series(_ s: SystemSeries, last seconds: TimeInterval = 300) -> [(Date, Double)] {
        guard let end = recent.last?.time else { return [] }
        return recent.filter { $0.time >= end - seconds && $0[s].isFinite }.map { (Date(timeIntervalSince1970: $0.time), $0[s]) }
    }

    func history(_ s: SystemSeries, range: TimeInterval, points: Int) async -> HistorySeries? {
        guard let source else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> HistorySeries? in
            if case .history(let h)? = try? source.send(.history(series: s, range: range, maxPoints: points)) { return h }
            return nil
        }.value
    }

    func events(range: TimeInterval, limit: Int = 200) async -> [TalonEvent] {
        guard let source else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [TalonEvent] in
            if case .events(let e)? = try? source.send(.events(range: range, limit: limit)) { return e }
            return []
        }.value
    }

    func healthDays(_ days: Int) async -> [HealthDay] {
        guard let source else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [HealthDay] in
            if case .healthHistory(let d)? = try? source.send(.healthHistory(days: days)) { return d }
            return []
        }.value
    }

    func appHistory(key: String, range: TimeInterval, points: Int) async -> [AppPoint] {
        guard let source else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [AppPoint] in
            if case .appHistory(let p)? = try? source.send(.appHistory(key: key, range: range, maxPoints: points)) { return p }
            return []
        }.value
    }

    /// Freeze / thaw / cap: returns a message for the UI either way.
    func perform(_ request: TalonRequest) async -> Result<String, TalonError> {
        guard let source else { return .failure(TalonError(.unreachable, "talond isn't connected")) }
        let r = await Task.detached(priority: .userInitiated) { () -> Result<String, TalonError> in
            do throws(TalonError) {
                if case .ok(let msg) = try source.send(request) { return .success(msg) }
                return .success("done")
            } catch {
                return .failure(error)
            }
        }.value
        _ = await poll(force: false)
        return r
    }

    var frozen: Set<Int32> { Set(status?.frozen ?? []) }
}
