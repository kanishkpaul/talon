import Charts
import SwiftUI
import TalonModel

/// The long view: what happened (events), how the hardware is ageing (daily records), and any
/// one app over time.
struct HistoryView: View {
    var model: LiveModel

    enum Range: String, CaseIterable, Identifiable {
        case h24 = "24h", d7 = "7d", d30 = "30d", d90 = "90d"
        var id: Self { self }
        var seconds: TimeInterval { TimeSpan.parse(rawValue)! }
        var days: Int { Int(seconds / 86_400) }
    }

    @State private var range: Range = .d7
    @State private var events: [TalonEvent] = []
    @State private var days: [HealthDay] = []
    @State private var appKey: String?
    @State private var appPoints: [AppPoint] = []
    @State private var kinds: Set<TalonEvent.Kind> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("History").font(.title2.weight(.semibold))
                    Spacer()
                    Picker("Range", selection: $range) { ForEach(Range.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                        .glassEffect(.regular, in: Capsule())
                }
                HStack(alignment: .top, spacing: 14) {
                    BatteryTrend(days: days)
                    SSDTrend(days: days)
                }
                appSection
                timeline
            }
            .padding(20)
        }
        .task(id: range) { await load() }
        .task(id: appKey) { await loadApp() }
        .task(id: range) { await loadApp() }
    }

    private func load() async {
        async let e = model.events(range: range.seconds, limit: 300)
        async let d = model.healthDays(max(range.days, 2))
        events = await e
        days = await d
        if appKey == nil { appKey = model.topWriters.first?.key ?? model.snapshot?.apps.max { $0.footprint < $1.footprint }?.key }
    }

    private func loadApp() async {
        guard let appKey else { appPoints = []; return }
        appPoints = await model.appHistory(key: appKey, range: range.seconds, points: 200)
    }

    // MARK: App over time

    private var appChoices: [(key: String, name: String)] {
        var seen = Set<String>(), out: [(String, String)] = []
        for a in model.topWriters where seen.insert(a.key).inserted { out.append((a.key, a.name)) }
        for a in (model.snapshot?.apps ?? []).sorted(by: { $0.footprint > $1.footprint }).prefix(25) where seen.insert(a.key).inserted {
            out.append((a.key, a.name))
        }
        return out
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("One app over time", systemImage: "app.badge.clock").font(.headline)
                Spacer()
                Picker("App", selection: $appKey) {
                    ForEach(appChoices, id: \.key) { a in Text(a.name).tag(Optional(a.key)) }
                }
                .frame(width: 240)
            }
            HStack(spacing: 14) {
                AppChart(title: "Memory", points: appPoints.map { ($0.time, $0.memoryAverage, $0.memoryPeak) }, tint: .purple) { ByteSize.format($0) }
                AppChart(title: "CPU", points: appPoints.map { ($0.time, $0.cpuPercent, $0.cpuPercent) }, tint: .blue) { String(format: "%.0f%%", $0) }
                AppChart(title: "SSD writes", points: appPoints.map { ($0.time, $0.writeRate, $0.writeRate) }, tint: .teal) { ByteSize.format($0) + "/s" }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Timeline

    private var timeline: some View {
        let shown = events.filter { kinds.isEmpty || kinds.contains($0.kind) }
        let byDay = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: $0.time)) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Events", systemImage: "list.bullet.rectangle").font(.headline)
                Spacer()
                ForEach(EventStyle.filters, id: \.title) { f in
                    let on = !kinds.isDisjoint(with: f.kinds)
                    Button { if on { kinds.subtract(f.kinds) } else { kinds.formUnion(f.kinds) } } label: {
                        Label(f.title, systemImage: f.symbol)
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? .accentColor : nil)
                    .controlSize(.small)
                }
            }
            if shown.isEmpty {
                Text("Nothing in the last \(range.rawValue).").foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                Text(day.formatted(.dateTime.weekday(.wide).month().day())).font(.subheadline.weight(.semibold)).padding(.top, 6)
                ForEach(Array(byDay[day]!.sorted { $0.time > $1.time }.enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: EventStyle.symbol(e.kind)).foregroundStyle(EventStyle.tint(e.kind)).frame(width: 18)
                        Text(Date(timeIntervalSince1970: e.time).formatted(date: .omitted, time: .shortened))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        Text(e.message).textSelection(.enabled)
                        Spacer()
                    }
                    .font(.callout)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

enum EventStyle {
    struct Filter { var title: String; var symbol: String; var kinds: Set<TalonEvent.Kind> }

    static let filters: [Filter] = [
        Filter(title: "Ceilings", symbol: "gauge.with.needle", kinds: [.ceilingWarning, .ceilingAction, .ceilingChanged, .memoryCapSet]),
        Filter(title: "Heat", symbol: "thermometer.medium", kinds: [.thermalChange, .throttling]),
        Filter(title: "Memory", symbol: "memorychip", kinds: [.memoryPressureChange]),
        Filter(title: "Processes", symbol: "pause.circle", kinds: [.frozen, .thawed, .killed]),
        Filter(title: "System", symbol: "power", kinds: [.daemonStarted, .daemonStopped, .unsafeShutdown]),
    ]

    static func symbol(_ k: TalonEvent.Kind) -> String {
        switch k {
        case .daemonStarted: "play.circle"
        case .daemonStopped: "stop.circle"
        case .memoryCapSet: "lock"
        case .frozen: "pause.circle.fill"
        case .thawed: "play.circle.fill"
        case .killed: "xmark.octagon"
        case .thermalChange: "thermometer.medium"
        case .memoryPressureChange: "memorychip"
        case .ceilingWarning: "exclamationmark.triangle"
        case .ceilingAction: "hand.raised"
        case .ceilingChanged: "gauge.with.needle"
        case .throttling: "tortoise"
        case .unsafeShutdown: "bolt.trianglebadge.exclamationmark"
        }
    }

    static func tint(_ k: TalonEvent.Kind) -> Color {
        switch k {
        case .ceilingWarning, .thermalChange, .memoryPressureChange: .orange
        case .ceilingAction, .killed, .throttling, .unsafeShutdown: .red
        case .frozen, .thawed, .memoryCapSet, .ceilingChanged: .blue
        case .daemonStarted, .daemonStopped: .secondary
        }
    }
}

struct AppChart: View {
    var title: String
    var points: [(TimeInterval, Double, Double)]   // time, avg, peak
    var tint: Color
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let mx = points.map(\.2).filter(\.isFinite).max() { Text("peak " + format(mx)).font(.caption).foregroundStyle(.secondary) }
            }
            Chart {
                ForEach(points.indices, id: \.self) { i in
                    let t = Date(timeIntervalSince1970: points[i].0)
                    if points[i].2 > points[i].1 {
                        AreaMark(x: .value("t", t), yStart: .value("avg", points[i].1), yEnd: .value("peak", points[i].2))
                            .foregroundStyle(tint.opacity(0.15))
                    }
                    LineMark(x: .value("t", t), y: .value(title, points[i].1)).foregroundStyle(tint).interpolationMethod(.monotone)
                }
            }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)) } } } }
            .frame(height: 120)
            .overlay { if points.isEmpty { Text("No history yet").font(.caption).foregroundStyle(.secondary) } }
        }
        .frame(maxWidth: .infinity)
    }
}

struct BatteryTrend: View {
    var days: [HealthDay]

    var body: some View {
        let pts = days.compactMap { d in d.batteryHealthPercent.map { (day: d.day, v: $0, cycles: d.cycleCount ?? 0) } }
        Card(title: "Battery health", symbol: "battery.75percent") {
            if let first = pts.first, let last = pts.last {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.1f%%", last.v)).font(.title2.weight(.semibold)).monospacedDigit()
                    Text(String(format: "%+.1f pts · +%d cycles over %d days", last.v - first.v, last.cycles - first.cycles, pts.count))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Chart(pts, id: \.day) { p in
                    LineMark(x: .value("Day", p.day), y: .value("Health", p.v)).foregroundStyle(.green).interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 110)
                Text("Raw capacity ÷ design, recorded daily. Apple's own figure usually reads a few points higher.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("talond records the battery once a day; the trend starts with the first record.").foregroundStyle(.secondary)
            }
        }
    }
}

struct SSDTrend: View {
    var days: [HealthDay]

    var body: some View {
        let perDay: [(day: String, bytes: Double)] = zip(days, days.dropFirst()).compactMap { a, b in
            guard let w0 = a.ssdBytesWritten, let w1 = b.ssdBytesWritten, w1 >= w0 else { return nil }
            return (b.day, Double(w1 - w0))
        }
        Card(title: "SSD writes per day", symbol: "internaldrive") {
            if !perDay.isEmpty {
                let avg = perDay.map(\.bytes).reduce(0, +) / Double(perDay.count)
                HStack(alignment: .firstTextBaseline) {
                    Text(ByteSize.format(avg)).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("a day on average · \(ByteSize.format(days.last?.ssdBytesWritten ?? 0)) lifetime").font(.callout).foregroundStyle(.secondary)
                }
                Chart(perDay, id: \.day) { p in
                    BarMark(x: .value("Day", p.day), y: .value("Written", p.bytes)).foregroundStyle(.teal.gradient)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(ByteSize.format(d)) } } } }
                .frame(height: 110)
                Text("From the SSD's own counter, so it includes every app, macOS and swap.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Needs two daily records.").foregroundStyle(.secondary)
            }
        }
    }
}
