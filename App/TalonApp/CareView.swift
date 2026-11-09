import AppKit
import SwiftUI
import TalonModel

/// Care: the few things worth doing for this Mac's long-term health, most important first.
struct CareView: View {
    var model: LiveModel
    @State private var showGood = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Care").font(.title2.weight(.semibold))
                    Text(summary).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Show all-clear", isOn: $showGood).toggleStyle(.switch).controlSize(.small)
                }
                let shown = model.insights.filter { showGood || $0.severity > .good }
                if shown.isEmpty {
                    ContentUnavailableView("Nothing needs your attention", systemImage: "checkmark.seal",
                                           description: Text("Care reads a week of history; insights appear as talon learns how this Mac is used."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
                ForEach(shown) { i in InsightCard(insight: i, model: model) }
            }
            .padding(20)
        }
        .navigationTitle("Care")
    }

    private var summary: String {
        let act = model.insights.filter { $0.severity == .act }.count, watch = model.insights.filter { $0.severity == .watch }.count
        if act + watch == 0 { return "all clear" }
        return [act > 0 ? "\(act) to act on" : nil, watch > 0 ? "\(watch) to watch" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

enum Severity {
    static func color(_ s: Insight.Severity) -> Color {
        switch s { case .act: .red; case .watch: .orange; case .info: .blue; case .good: .green }
    }
    static func label(_ s: Insight.Severity) -> String {
        switch s { case .act: "Act"; case .watch: "Watch"; case .info: "Info"; case .good: "Good" }
    }
    static func symbol(_ a: Insight.Area) -> String {
        switch a {
        case .ssd: "internaldrive"; case .battery: "battery.75percent"; case .memory: "memorychip"
        case .thermal: "thermometer.medium"; case .storage: "externaldrive"; case .stability: "bolt.trianglebadge.exclamationmark"
        }
    }
}

struct InsightCard: View {
    var insight: Insight
    var model: LiveModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: Severity.symbol(insight.area))
                .font(.title2)
                .foregroundStyle(Severity.color(insight.severity))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(Severity.label(insight.severity).uppercased())
                        .font(.caption2.weight(.bold)).foregroundStyle(Severity.color(insight.severity))
                    Text(insight.area.label).font(.caption).foregroundStyle(.secondary)
                }
                Text(insight.title).font(.headline)
                Text(insight.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let s = insight.suggestion {
                    Label(s, systemImage: "arrow.turn.down.right").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Severity.color(insight.severity)).frame(width: 4).padding(.vertical, 12)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if insight.id.hasPrefix("ssd.top-writer."), let app = writerApp {
                Button("Ceiling for \(app.name)…") { model.open(ceilingFor: app) }.buttonStyle(.bordered)
            }
            if insight.area == .battery, insight.id == "battery.parked-full" || insight.id == "battery.service" {
                Button("Battery Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                }.buttonStyle(.bordered)
            }
            if insight.area == .memory, let hog = model.snapshot?.apps.max(by: { $0.footprint < $1.footprint }) {
                Button("Ceiling for \(hog.name)…") { model.open(ceilingFor: hog) }.buttonStyle(.bordered)
            }
            if insight.area == .storage {
                Button("Open Scalpel") { model.requestedPane = .scalpel }.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }

    private var writerApp: AppUsage? {
        let key = String(insight.id.dropFirst("ssd.top-writer.".count))
        return model.snapshot?.apps.first { $0.key == key }
    }
}

/// One line in the menu bar panel: the most important thing Care has to say.
struct CareLine: View {
    var insight: Insight
    var more: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Severity.symbol(insight.area)).foregroundStyle(Severity.color(insight.severity))
            Text(insight.title).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if more > 0 { Text("+\(more)").font(.caption).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Severity.color(insight.severity).opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}
