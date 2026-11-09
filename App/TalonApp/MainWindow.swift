import Charts
import SwiftUI
import TalonModel

struct MainWindow: View {
    enum Pane: String, CaseIterable, Identifiable {
        case overview = "Overview", processes = "Processes", ceilings = "Ceilings"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.50percent"
            case .processes: "list.bullet.indent"
            case .ceilings: "gauge.with.needle"
            }
        }
    }

    var model: LiveModel
    @State var selection: Pane

    init(model: LiveModel, initial: Pane) {
        self.model = model
        _selection = State(initialValue: initial)
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label(pane.rawValue, systemImage: pane.symbol)
                    .badge(pane == .ceilings ? model.asking.count : 0)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .safeAreaInset(edge: .bottom) { sourceFooter }
        } detail: {
            switch model.connection {
            case .unavailable(let why):
                Unavailable(message: why, retry: model.connectNow).frame(maxWidth: 520).padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                switch selection {
                case .overview: OverviewView(model: model)
                case .processes: ProcessesView(model: model)
                case .ceilings: CeilingsView(model: model)
                }
            }
        }
        .onAppear { model.beginViewing() }
        .onDisappear { model.endViewing() }
        .onChange(of: model.requestedPane) { _, pane in
            if let pane { selection = pane; model.requestedPane = nil }
        }
    }

    private var sourceFooter: some View {
        HStack(spacing: 6) {
            Circle().fill(model.connection.isLive ? (model.isDemo ? Color.orange : .green) : .secondary).frame(width: 7, height: 7)
            switch model.connection {
            case .connected(let l): Text(l)
            case .connecting: Text("connecting…")
            case .unavailable: Text("talond offline")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Overview

struct OverviewView: View {
    var model: LiveModel

    enum Range: String, CaseIterable, Identifiable {
        case m15 = "15m", h1 = "1h", h24 = "24h", d7 = "7d", d30 = "30d"
        var id: Self { self }
        var seconds: TimeInterval { TimeSpan.parse(rawValue)! }
        var refresh: TimeInterval { seconds <= 3600 ? 2 : 30 }
    }

    @State private var range: Range = .h1
    @State private var charts: [SystemSeries: HistorySeries] = [:]
    private let chartSeries: [SystemSeries] = [.cpu, .memUsed, .cpuTemp, .systemPower, .diskWriteRate, .swapUsed]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TileGrid(model: model, columns: 6)
                HStack {
                    Text("History").font(.title3.weight(.semibold))
                    Spacer()
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    .glassEffect(.regular, in: Capsule())
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(chartSeries, id: \.self) { s in
                        HistoryChart(series: s, history: charts[s])
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    HealthCards(health: model.health)
                }
                WritersCard(writers: model.topWriters)
            }
            .padding(20)
        }
        .task(id: range) {
            while !Task.isCancelled {
                for s in chartSeries {
                    if let h = await model.history(s, range: range.seconds, points: 240) { charts[s] = h }
                }
                try? await Task.sleep(for: .seconds(range.refresh))
            }
        }
    }
}

/// avg as a line, the min–max band behind it so spikes survive downsampling.
struct HistoryChart: View {
    var series: SystemSeries
    var history: HistorySeries?

    var body: some View {
        let pts = (history?.points ?? []).filter { $0.avg.isFinite }
        let tint = Tint.series(series)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.label).font(.headline)
                Spacer()
                if let last = pts.last { Text(series.format(last.avg)).monospacedDigit().foregroundStyle(.secondary) }
                if let tier = history?.tier { Text(tier.rawValue).font(.caption2).foregroundStyle(.tertiary) }
            }
            Chart {
                ForEach(pts.indices, id: \.self) { i in
                    let p = pts[i], t = Date(timeIntervalSince1970: p.time)
                    AreaMark(x: .value("Time", t), yStart: .value("min", p.min), yEnd: .value("max", p.max))
                        .foregroundStyle(tint.opacity(0.15))
                    LineMark(x: .value("Time", t), y: .value(series.label, p.avg))
                        .foregroundStyle(tint)
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: .automatic(includesZero: series.unit != .celsius))
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(axisLabel(d)) } }
                }
            }
            .frame(height: 150)
            .overlay {
                if pts.isEmpty { Text("No history yet").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func axisLabel(_ v: Double) -> String {
        switch series.unit {
        case .bytes: ByteSize.format(v)
        case .bytesPerSecond: ByteSize.format(v) + "/s"
        case .percent: String(format: "%.0f%%", v)
        case .celsius: String(format: "%.0f°", v)
        case .watts: String(format: "%.0f W", v)
        default: String(format: "%.0f", v)
        }
    }
}

struct HealthCards: View {
    var health: HealthReport?

    var body: some View {
        if let b = health?.battery {
            Card(title: "Battery", symbol: "battery.75percent") {
                let h = b.rawHealthPercent
                Fact(label: "Health (raw)", value: String(format: "%.1f%%", h), tint: h >= 85 ? .green : h >= 80 ? .orange : .red)
                Fact(label: "Cycles", value: "\(b.cycleCount) of ~1,000")
                Fact(label: "Capacity", value: "\(b.nominalCapacity) / \(b.designCapacity) mAh")
                Fact(label: "Now", value: "\(b.chargePercent)% · " + (b.externalConnected ? (b.isCharging ? "charging" : "plugged in") : "on battery"))
            }
        }
        if let s = health?.ssd {
            Card(title: "SSD", symbol: "internaldrive") {
                Fact(label: "Wear", value: "\(s.percentUsed)%", tint: s.percentUsed < 10 ? .green : .orange)
                Fact(label: "Written", value: Fmt.bytes(s.bytesWritten))
                Fact(label: "Media errors", value: "\(s.mediaErrors)", tint: s.mediaErrors == 0 ? .green : .red)
                Fact(label: "Unsafe shutdowns", value: "\(s.unsafeShutdowns)")
            }
        }
        if let t = health?.thermal {
            Card(title: "Thermals", symbol: "thermometer.medium") {
                Fact(label: "Pressure", value: t.pressure?.label ?? "—", tint: Tint.thermal(t.pressure))
                Fact(label: "CPU die", value: t.cpuMax.map { String(format: "%.1f °C", $0) } ?? "—")
                Fact(label: "SSD", value: t.ssd.map { String(format: "%.1f °C", $0) } ?? "—")
                Fact(label: "Battery", value: t.battery.map { String(format: "%.1f °C", $0) } ?? "—")
            }
        }
        if let d = health?.disk {
            Card(title: "Storage", symbol: "externaldrive") {
                Fact(label: "Free", value: Fmt.bytes(d.free), tint: d.free >= 60 << 30 ? .green : .orange)
                Fact(label: "Total", value: Fmt.bytes(d.total))
                ProgressView(value: Double(d.total - d.free), total: Double(max(d.total, 1))).tint(.teal)
            }
        }
        if health == nil {
            Card(title: "Health", symbol: "heart.text.square") { Text("Reading the hardware…").foregroundStyle(.secondary) }
        }
    }
}

struct WritersCard: View {
    var writers: [AppTotal]

    var body: some View {
        Card(title: "Who wrote to the SSD · last 24 h", symbol: "square.and.pencil") {
            if writers.isEmpty {
                Text("talond commits app history once a minute — check back shortly.").foregroundStyle(.secondary)
            }
            let top = Double(writers.first?.bytesWritten ?? 1)
            ForEach(writers, id: \.key) { a in
                HStack(spacing: 10) {
                    Image(nsImage: AppIcons.icon(for: a.key)).resizable().frame(width: 18, height: 18)
                    Text(a.name).frame(width: 180, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        Capsule().fill(.teal.gradient)
                            .frame(width: max(3, g.size.width * Double(a.bytesWritten) / max(top, 1)))
                    }
                    .frame(height: 8)
                    Text(Fmt.bytes(a.bytesWritten)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                .font(.callout)
            }
        }
    }
}
