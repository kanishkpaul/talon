import AppKit
import Observation
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
                if wantsProcesses, case .processes(let p) = try source.send(.processes) { f.snapshot = p }
                if wantsSlow {
                    if case .health(let h) = try source.send(.health) { f.health = h }
                    if case .topApps(let a) = try source.send(.topApps(range: 86_400, by: .disk, limit: 8)) { f.writers = a }
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
            if wantsSlow, f.health != nil {
                health = f.health
                topWriters = f.writers
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
