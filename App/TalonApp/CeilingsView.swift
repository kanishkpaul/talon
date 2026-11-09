import AppKit
import Charts
import SwiftUI
import TalonIPC
import TalonModel

/// Ceilings: every rule on the left; on the right, the target's live usage with the ceiling drawn
/// across it. Drag the line to move the ceiling — a haptic tick marks the moment it crosses current
/// usage — and pick how strictly talon holds it.
struct CeilingsView: View {
    var model: LiveModel
    @State private var banner: (text: String, ok: Bool)?

    var body: some View {
        HSplitView {
            list.frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            Group {
                if let id = model.selectedCeiling, let rule = model.ceilings.first(where: { $0.id == id }) {
                    CeilingDetail(model: model, rule: rule, status: model.ceilingStates[id]) { r in
                        withAnimation { banner = r }
                    }
                    .id(id)
                } else {
                    ContentUnavailableView("No ceiling selected", systemImage: "gauge.with.needle",
                                           description: Text("Pick one on the left, or add one for a running app."))
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { ToolbarItem { addMenu } }
        .navigationTitle("Ceilings")
        .overlay(alignment: .bottom) {
            if let banner {
                Label(banner.text, systemImage: banner.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .padding(16)
                    .task { try? await Task.sleep(for: .seconds(4)); withAnimation { self.banner = nil } }
            }
        }
        .onAppear {
            if model.selectedCeiling == nil { model.selectedCeiling = model.ceilings.first?.id }
        }
    }

    private var list: some View {
        List(selection: Binding(get: { model.selectedCeiling }, set: { model.selectedCeiling = $0 })) {
            ForEach(model.ceilings) { rule in
                CeilingRow(rule: rule, status: model.ceilingStates[rule.id]).tag(rule.id)
            }
        }
        .overlay {
            if model.ceilings.isEmpty {
                ContentUnavailableView {
                    Label("No ceilings yet", systemImage: "gauge.with.needle")
                } description: {
                    Text("Give any app a limit on memory, CPU or SSD writes, and choose how hard talon holds the line.")
                } actions: { addMenu }
            }
        }
    }

    private var addMenu: some View {
        Menu {
            let apps = (model.snapshot?.apps ?? []).sorted { $0.footprint > $1.footprint }.prefix(15)
            ForEach(Array(apps)) { a in
                Button { model.open(ceilingFor: a) } label: {
                    Label { Text("\(a.name) — \(Fmt.bytes(a.footprint))") } icon: { Image(nsImage: AppIcons.icon(for: a.key)) }
                }
            }
            if apps.isEmpty { Text("Waiting for the process list…") }
        } label: {
            Label("Add ceiling", systemImage: "plus")
        }
    }
}

struct CeilingRow: View {
    var rule: Ceiling
    var status: CeilingStatus?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcons.icon(for: iconKey)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(rule.label).font(.body.weight(.medium)).lineLimit(1)
                    Spacer()
                    PhaseBadge(phase: status?.phase ?? .ok)
                }
                Text("\(rule.summary) · \(rule.strictness.label)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ProgressView(value: min(status?.ratio ?? 0, 1))
                    .tint(PhaseBadge.color(status?.phase ?? .ok))
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 4)
        .opacity(rule.enabled ? 1 : 0.5)
    }

    private var iconKey: String { if case .app(let k) = rule.target { k } else { "" } }
}

struct PhaseBadge: View {
    var phase: CeilingStatus.Phase

    static func color(_ p: CeilingStatus.Phase) -> Color {
        switch p {
        case .ok: .green
        case .approaching, .over: .orange
        case .enforced, .asking: .red
        case .gone, .disabled: .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Self.color(phase).opacity(0.18), in: Capsule())
            .foregroundStyle(Self.color(phase))
    }

    private var label: String {
        switch phase {
        case .ok: "ok"; case .approaching: "approaching"; case .over: "over"; case .enforced: "enforced"
        case .asking: "asking"; case .gone: "not running"; case .disabled: "off"
        }
    }
}

// MARK: - Detail

struct CeilingDetail: View {
    var model: LiveModel
    @State var rule: Ceiling
    var status: CeilingStatus?
    var report: ((String, Bool)) -> Void
    @State private var resource: CeilingResource

    init(model: LiveModel, rule: Ceiling, status: CeilingStatus?, report: @escaping ((String, Bool)) -> Void) {
        self.model = model
        _rule = State(initialValue: rule)
        self.status = status
        self.report = report
        _resource = State(initialValue: CeilingResource.allCases.first { rule.limit($0) != nil } ?? .memory)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let s = status, s.phase == .asking {
                    AskBanner(model: model, rule: rule)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Live usage").font(.headline)
                        Spacer()
                        Picker("Resource", selection: $resource) {
                            ForEach(CeilingResource.allCases, id: \.self) { r in Text(Self.name(r)).tag(r) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    CeilingChart(rule: $rule, resource: resource,
                                 history: model.ceilingHistory[rule.id] ?? [], current: status?.usage[resource]) { save() }
                        .frame(height: 220)
                    Text(rule.limit(resource) == nil
                         ? "No \(Self.name(resource).lowercased()) ceiling. Drag up from the bottom of the chart, or set one below."
                         : "Drag the line to move the ceiling. The dashed line is where talon starts warning.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                limits
                StrictnessLadder(selection: Binding(get: { rule.strictness }, set: { rule.strictness = $0; save() }))
                timing
            }
            .padding(20)
        }
        .onChange(of: model.ceilings.first { $0.id == rule.id }) { _, server in
            // Pick up changes made elsewhere (an Ask answer that raised the ceiling, the CLI).
            if let server, server != rule { rule = server }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIcons.icon(for: iconKey)).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.label).font(.title2.weight(.semibold))
                Text(targetDescription).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let s = status {
                VStack(alignment: .trailing, spacing: 2) {
                    PhaseBadge(phase: s.phase)
                    if let a = s.lastAction { Text(a).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Toggle("On", isOn: Binding(get: { rule.enabled }, set: { rule.enabled = $0; save() }))
                .toggleStyle(.switch).labelsHidden()
                .help(rule.enabled ? "Turn this ceiling off" : "Turn this ceiling on")
        }
    }

    private var limits: some View {
        Card(title: "Limits", symbol: "slider.horizontal.3") {
            LimitField(title: "Memory", placeholder: "e.g. 8G", value: rule.memory.map { ByteSize.format($0) }) { text in
                rule.memory = text.flatMap { try? ByteSize.parse($0) }.flatMap { $0 >= 16 << 20 ? $0 : nil }
                save()
            }
            LimitField(title: "CPU", placeholder: "e.g. 200%", value: rule.cpu.map { String(format: "%.0f%%", $0) }) { text in
                rule.cpu = text.flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }.flatMap { $0 > 0 ? $0 : nil }
                save()
            }
            LimitField(title: "SSD writes", placeholder: "e.g. 50M per second", value: rule.writeRate.map { ByteSize.format($0) + "/s" }) { text in
                rule.writeRate = text.map { $0.replacingOccurrences(of: "/s", with: "") }.flatMap { try? ByteSize.parse($0) }.map(Double.init)
                save()
            }
            Text("Limits are summed across every process the app is responsible for. CPU is in percent of one core.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var timing: some View {
        Card(title: "Timing", symbol: "timer") {
            HStack {
                Text("Warn from").foregroundStyle(.secondary)
                Slider(value: Binding(get: { rule.warnFraction }, set: { rule.warnFraction = $0 }), in: 0.5...0.99) { editing in
                    if !editing { save() }
                }
                Text("\(Int((rule.warnFraction * 100).rounded()))% of the ceiling").monospacedDigit().frame(width: 140, alignment: .trailing)
            }
            Stepper(value: Binding(get: { rule.grace }, set: { rule.grace = $0; save() }), in: 0...120, step: 1) {
                HStack { Text("Grace period").foregroundStyle(.secondary); Spacer(); Text("\(Int(rule.grace)) s over before acting").monospacedDigit() }
            }
            if rule.strictness == .quit {
                Stepper(value: Binding(get: { rule.quitGrace }, set: { rule.quitGrace = $0; save() }), in: 1...120, step: 1) {
                    HStack { Text("Force-quit after").foregroundStyle(.secondary); Spacer(); Text("\(Int(rule.quitGrace)) s").monospacedDigit() }
                }
            }
            HStack {
                Spacer()
                Button("Delete ceiling", role: .destructive) {
                    let r = rule
                    model.selectedCeiling = model.ceilings.first { $0.id != r.id }?.id
                    Task { report(result(await model.remove(r))) }
                }
            }
        }
    }

    private func save() {
        let r = rule
        Task {
            let res = await model.save(r)
            if case .failure = res { report(result(res)) }
        }
    }

    private func result(_ r: Result<String, TalonError>) -> (String, Bool) {
        switch r { case .success(let m): (m, true); case .failure(let e): (e.message, false) }
    }

    private var iconKey: String { if case .app(let k) = rule.target { k } else { "" } }

    private var targetDescription: String {
        switch rule.target {
        case .app(let key): "Every process \(rule.label) is responsible for · \(key)"
        case .process(let pid, _): "Process \(pid)"
        case .tree(let pid, _): "Process \(pid) and everything it spawns"
        }
    }

    static func name(_ r: CeilingResource) -> String {
        switch r { case .memory: "Memory"; case .cpu: "CPU"; case .writes: "Writes" }
    }
}

/// A text field that commits on Return or focus loss; empty clears the limit.
struct LimitField: View {
    var title: String
    var placeholder: String
    var value: String?
    var commit: (String?) -> Void
    @State private var text = ""

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit(text.isEmpty ? nil : text) }
            if value != nil {
                Button { text = ""; commit(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove this limit")
            }
        }
        .onAppear { text = value ?? "" }
        .onChange(of: value) { _, v in text = v ?? "" }
    }
}

// MARK: - The chart you drag

struct CeilingChart: View {
    @Binding var rule: Ceiling
    var resource: CeilingResource
    var history: [(Date, CeilingUsage)]
    var current: Double?
    var commit: () -> Void
    @State private var dragValue: Double?
    @State private var lastSide: Bool?

    private var limit: Double? { dragValue ?? rule.limit(resource) }

    var body: some View {
        let pts = history.map { ($0.0, $0.1[resource]) }
        let top = max((pts.map(\.1).max() ?? 0), limit ?? 0, current ?? 0) * 1.3 + (resource == .memory ? 64e6 : 5)
        let tint = Tint.series(resource == .memory ? .memUsed : resource == .cpu ? .cpu : .diskWriteRate)
        Chart {
            ForEach(pts.indices, id: \.self) { i in
                AreaMark(x: .value("t", pts[i].0), y: .value("v", pts[i].1))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", pts[i].0), y: .value("v", pts[i].1))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
            }
            if let limit {
                RuleMark(y: .value("ceiling", limit))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: dragValue == nil ? 2 : 3))
                    .annotation(position: .top, alignment: .trailing, spacing: 4) {
                        Text("ceiling \(resource.format(limit))")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.red, in: Capsule())
                    }
                RuleMark(y: .value("warn", limit * rule.warnFraction))
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(resource.format(d)) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                guard let plot = proxy.plotFrame else { return }
                                let y = g.location.y - geo[plot].origin.y
                                guard let v: Double = proxy.value(atY: y) else { return }
                                let snapped = snap(max(v, 0))
                                if snapped != dragValue { tick(crossing: snapped) }
                                dragValue = snapped
                            }
                            .onEnded { _ in
                                if let v = dragValue { set(v) }
                                dragValue = nil
                                lastSide = nil
                                commit()
                            }
                    )
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(CeilingDetail.name(resource)) ceiling")
        .accessibilityValue((limit.map { "ceiling \(resource.format($0))" } ?? "no ceiling") + (current.map { ", using \(resource.format($0))" } ?? ""))
        .accessibilityAdjustableAction { direction in
            // Without a trackpad: up and down move the ceiling one snap step.
            let base = rule.limit(resource) ?? (current ?? 0)
            let step = snap(base * 0.05)
            set(snap(max(step, direction == .increment ? base + step : base - step)))
            commit()
        }
    }

    /// Round numbers only: 64 MB steps for memory, 5 % for CPU, 1 MB/s for writes.
    private func snap(_ v: Double) -> Double {
        let step: Double = switch resource { case .memory: 64 * 1_048_576; case .cpu: 5; case .writes: 1_048_576 }
        return max(step, (v / step).rounded() * step)
    }

    /// The signature haptic: one tick each time the line crosses what the app is using right now.
    private func tick(crossing v: Double) {
        guard let current else { return }
        let side = v >= current
        if let lastSide, lastSide != side {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastSide = side
    }

    private func set(_ v: Double) {
        switch resource {
        case .memory: rule.memory = UInt64(v)
        case .cpu: rule.cpu = v
        case .writes: rule.writeRate = v
        }
    }
}

// MARK: - Strictness ladder

struct StrictnessLadder: View {
    @Binding var selection: Strictness

    var body: some View {
        Card(title: "When it's crossed", symbol: "stairs") {
            VStack(spacing: 4) {
                ForEach(Strictness.allCases, id: \.self) { s in
                    Button {
                        if selection != s { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
                        selection = s
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selection == s ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selection == s ? Color.accentColor : .secondary)
                            Text(s.label).font(.body.weight(.medium)).frame(width: 90, alignment: .leading)
                            Text(s.explanation).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .background(selection == s ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == s ? .isSelected : [])
                    .accessibilityHint(s.explanation)
                }
            }
        }
    }
}

// MARK: - Ask

/// The answer row, used in the ask panel and atop a ceiling that's asking.
struct AskBanner: View {
    var model: LiveModel
    var rule: Ceiling
    var done: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: AppIcons.icon(for: key)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(rule.label) crossed its ceiling").font(.headline)
                    if let s = model.ceilingStates[rule.id] {
                        Text(LiveModel.describe(rule, s)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    answer("Raise 25%", "arrow.up", .raise(by: 1.25), prominent: true)
                    answer("Pause", "pause.fill", .pause)
                    answer("Quit", "xmark", .quit)
                    answer("Ignore", "eye.slash", .ignore)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func answer(_ title: String, _ symbol: String, _ choice: AskChoice, prominent: Bool = false) -> some View {
        let button = Button {
            Task {
                _ = await model.answer(rule, choice)
                done?()
            }
        } label: { Label(title, systemImage: symbol) }
        if prominent { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.glass) }
    }

    private var key: String { if case .app(let k) = rule.target { k } else { "" } }
}
