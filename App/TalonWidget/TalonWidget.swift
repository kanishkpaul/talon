import SwiftUI
import TalonModel
import WidgetKit

/// Minute-level summaries; the menu bar panel is the live view. macOS throttles widget refreshes,
/// so the app nudges a reload when it writes a new snapshot.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: WidgetSnapshot.read() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: Date(), snapshot: WidgetSnapshot.read())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
    }
}

struct Entry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
}

struct TalonWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Entry

    var body: some View {
        Group {
            if let s = entry.snapshot, Date().timeIntervalSince(s.time) < 15 * 60 {
                if family == .systemSmall { small(s) } else { medium(s) }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "bird.fill").font(.title2).foregroundStyle(.tint)
                    Text("Open Talon to start").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func small(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(s)
            Spacer(minLength: 0)
            reading("CPU", String(format: "%.0f%%", s.cpu), fraction: s.cpu / 100, tint: .blue)
            reading("Memory", ByteSize.format(s.memUsed), fraction: s.memUsed / max(s.memTotal, 1), tint: s.memPressure > 0 ? .orange : .purple)
            reading("CPU die", s.cpuTemp.isFinite ? String(format: "%.0f°", s.cpuTemp) : "—", fraction: (s.cpuTemp - 30) / 70,
                    tint: s.thermalPressure > 0 ? .orange : .pink)
        }
    }

    private func medium(_ s: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header(s)
                Spacer(minLength: 0)
                reading("CPU", String(format: "%.0f%%", s.cpu), fraction: s.cpu / 100, tint: .blue)
                reading("Memory", ByteSize.format(s.memUsed), fraction: s.memUsed / max(s.memTotal, 1), tint: s.memPressure > 0 ? .orange : .purple)
                reading("CPU die", s.cpuTemp.isFinite ? String(format: "%.0f°", s.cpuTemp) : "—", fraction: (s.cpuTemp - 30) / 70, tint: .pink)
            }
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow { label("Power"); value(s.power.isFinite ? String(format: "%.1f W", s.power) : "—") }
                    GridRow { label("Battery"); value(s.battery.isFinite ? String(format: "%.0f%%", s.battery) : "—") }
                    GridRow { label("Swap"); value(ByteSize.format(s.swap)) }
                    GridRow { label("Free"); value(ByteSize.format(s.diskFree)) }
                }
                Spacer(minLength: 0)
                if let t = s.careTitle {
                    Text(t).font(.caption2).lineLimit(3)
                        .foregroundStyle((s.careSeverity ?? 0) >= 3 ? Color.red : (s.careSeverity ?? 0) >= 2 ? .orange : .secondary)
                }
            }
        }
    }

    private func header(_ s: WidgetSnapshot) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "bird.fill").foregroundStyle(s.asking > 0 ? Color.red : .accentColor)
            Text(s.asking > 0 ? "\(s.asking) asking" : "Talon").font(.caption.weight(.semibold))
        }
    }

    private func reading(_ title: String, _ value: String, fraction: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.caption.weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: max(0, min(1, fraction.isFinite ? fraction : 0))).tint(tint).controlSize(.mini)
        }
    }

    private func label(_ t: String) -> some View { Text(t).font(.caption2).foregroundStyle(.secondary) }
    private func value(_ t: String) -> some View { Text(t).font(.caption.weight(.medium)).monospacedDigit() }
}

@main
struct TalonWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.kanishk.talon.summary", provider: Provider()) { entry in
            TalonWidgetView(entry: entry)
        }
        .configurationDisplayName("Talon")
        .description("CPU, memory, heat and the one thing Care says matters most.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
