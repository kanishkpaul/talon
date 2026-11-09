import SwiftUI
import TalonModel

/// The six readings shown in the panel and at the top of Overview.
struct TileGrid: View {
    var model: LiveModel
    var columns: Int

    var body: some View {
        let s = model.latest
        let mem = model.health?.memory
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            Tile(title: "CPU", value: Fmt.pct(s?[.cpu] ?? .nan), detail: "\(Int(s?[.processCount] ?? 0)) processes",
                 series: .cpu, points: model.series(.cpu))
            Tile(title: "Memory", value: Fmt.bytes(s?[.memUsed] ?? .nan),
                 detail: "of \(mem.map { Fmt.bytes($0.physical) } ?? "—") · \(s?.memoryPressure?.label ?? "—")",
                 series: .memUsed, points: model.series(.memUsed), accent: Tint.memory(s?.memoryPressure), floor: nil)
            Tile(title: "CPU die", value: Fmt.temp(s?[.cpuTemp] ?? .nan), detail: "pressure \(s?.thermalPressure?.label ?? "—")",
                 series: .cpuTemp, points: model.series(.cpuTemp), accent: Tint.thermal(s?.thermalPressure), floor: nil)
            Tile(title: "Power", value: Fmt.watts(s?[.systemPower] ?? .nan), detail: "battery \(Fmt.pct(s?[.batteryCharge] ?? .nan))",
                 series: .systemPower, points: model.series(.systemPower))
            Tile(title: "SSD writes", value: Fmt.rate(s?[.diskWriteRate] ?? .nan), detail: "all readable processes",
                 series: .diskWriteRate, points: model.series(.diskWriteRate))
            Tile(title: "Swap", value: Fmt.bytes(s?[.swapUsed] ?? .nan),
                 detail: "compressed \(Fmt.bytes(s?[.memCompressed] ?? .nan))",
                 series: .swapUsed, points: model.series(.swapUsed), floor: nil)
        }
    }
}

/// The menu bar panel: glance, then get out of the way.
struct MenuPanel: View {
    var model: LiveModel
    var openWindow: (MainWindow.Pane) -> Void
    var quit: () -> Void
    @State private var byCPU = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch model.connection {
            case .unavailable(let why):
                Unavailable(message: why, retry: model.connectNow)
            case .connecting:
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            case .connected:
                TileGrid(model: model, columns: 2)
                if let top = model.insights.first(where: { $0.severity >= .watch }) {
                    Button { openWindow(.care) } label: { CareLine(insight: top, more: model.insights.filter { $0.severity >= .watch }.count - 1) }
                        .buttonStyle(.plain)
                }
                topApps
            }
            footer
        }
        .padding(14)
        .frame(width: 360)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96, anchor: .top)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78)) { appeared = true }
        }
        .onAppear { model.beginViewing() }
        .onDisappear { model.endViewing() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bird.fill").foregroundStyle(.tint)
            Text("Talon").font(.headline)
            if model.isDemo {
                Text("DEMO DATA").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.25), in: Capsule())
            }
            Spacer()
            Button { openWindow(.overview) } label: { Image(systemName: "macwindow") }
                .buttonStyle(.borderless)
                .help("Open Talon")
        }
    }

    private var topApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Top apps").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("", selection: $byCPU) {
                    Text("Memory").tag(false)
                    Text("CPU").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .controlSize(.small)
            }
            let apps = (model.snapshot?.apps ?? [])
                .sorted { byCPU ? $0.cpuPercent > $1.cpuPercent : $0.footprint > $1.footprint }
                .prefix(5)
            ForEach(Array(apps)) { a in
                HStack(spacing: 8) {
                    Image(nsImage: AppIcons.icon(for: a.key)).resizable().frame(width: 18, height: 18)
                    Text(a.name).lineLimit(1)
                    Spacer()
                    Text(Fmt.bytes(a.footprint)).monospacedDigit().foregroundStyle(byCPU ? .secondary : .primary)
                        .frame(width: 70, alignment: .trailing)
                    Text(Fmt.pct(a.cpuPercent, digits: 1)).monospacedDigit().foregroundStyle(byCPU ? .primary : .secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .font(.callout)
            }
            if apps.isEmpty { Text("Waiting for the first sweep…").font(.callout).foregroundStyle(.secondary) }
            Button("All processes…") { openWindow(.processes) }.buttonStyle(.link).font(.callout)
        }
    }

    private var footer: some View {
        HStack {
            if let s = model.status {
                Text("talond \(Fmt.pct(s.ownCPUPercent, digits: 1)) · \(Fmt.bytes(s.ownFootprint))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("What talon itself costs. Source: \(connectionLabel)")
            }
            Spacer()
            Button("Settings…") {
                NSApp.activate()
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .buttonStyle(.borderless).font(.caption)
            .keyboardShortcut(",", modifiers: .command)
            Button("Quit", action: quit).buttonStyle(.borderless).font(.caption)
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var connectionLabel: String {
        if case .connected(let l) = model.connection { return l }
        return "—"
    }
}

/// talond isn't answering: say why and how to start it.
struct Unavailable: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("talond isn't running", systemImage: "bolt.horizontal.circle").font(.headline)
            // The standard "not running" error already names the fix below; show anything else verbatim.
            if !message.contains("make agent") {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Start it from the repo:").font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("make agent").font(.callout.monospaced())
                Text("no admin · your processes").font(.caption).foregroundStyle(.secondary)
                Text("make build && sudo make install").font(.callout.monospaced()).padding(.top, 4)
                Text("every process · kernel ceilings on running apps").font(.caption).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: retry)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
