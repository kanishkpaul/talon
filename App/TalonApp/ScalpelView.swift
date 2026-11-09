import AppKit
import Observation
import SwiftUI
import TalonModel
import TalonScalpel

/// Scalpel in the app. The scan runs here, as you — never in the root helper — and every cut goes
/// to the holding area first, restorable for seven days.
@Observable
final class ScalpelModel {
    enum State {
        case idle
        case scanning(ScanProgress?)
        case done
        case failed(String)
    }

    var state: State = .idle
    var root = NSHomeDirectory()
    var findDuplicates = false
    private(set) var tree: ScanTree?
    private(set) var findings: [Finding] = []
    private(set) var volume: VolumeSpace?
    private(set) var cuts: [CutManifest] = []
    var selected: Set<String> = []
    var inspected: String?
    var mapNode: Int32 = 0
    var message: (text: String, ok: Bool)?
    @ObservationIgnored private var task: Task<Void, Never>?

    init() { refreshHolding() }

    var isScanning: Bool { if case .scanning = state { true } else { false } }

    func scan() {
        task?.cancel()
        state = .scanning(nil)
        selected = []
        inspected = nil
        mapNode = 0
        let root = self.root, dupes = findDuplicates
        task = Task {
            var o = FindingsOptions()
            o.findDuplicates = dupes
            let progress: @Sendable (ScanProgress) -> Void = { p in Task { @MainActor [weak self] in
                if case .scanning = self?.state { self?.state = .scanning(p) }
            } }
            do {
                let result = try await Task.detached(priority: .utility) { () throws -> (ScanTree, [Finding]) in
                    let tree = try DiskScanner(options: FindingsEngine.scanOptions(o)).scan(root, progress: progress)
                    try Task.checkCancellation()
                    return (tree, FindingsEngine(home: NSHomeDirectory(), tree: tree, scope: tree.root, options: o).run())
                }.value
                tree = result.0
                findings = result.1.sorted { $0.sizes.reclaimable > $1.sizes.reclaimable }
                volume = VolumeSpace.of(root)
                state = .done
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed("\(error)")
            }
        }
    }

    func cancel() { task?.cancel(); state = .idle }

    var selectedFindings: [Finding] { findings.filter { selected.contains($0.id) } }

    /// Carries out the selected findings, each by its own removal method, each through the cut checks.
    /// Owner tools never run from a bulk cut — they have their own button.
    func cutSelected() {
        let chosen = selectedFindings
        Task {
            let results = await Task.detached(priority: .userInitiated) { chosen.map { Cleaner().apply($0) } }.value
            var freed: UInt64 = 0, done = 0
            var problems: [String] = []
            for r in results {
                switch r.outcome {
                case .held(let m): freed += m.sizes.reclaimable; done += 1
                case .trashed: freed += r.finding.sizes.reclaimable; done += 1
                case .cloned(let f, _, let failures): freed += f; done += 1; problems += failures
                case .ran: done += 1
                case .skipped(let why), .refused(let why): problems.append("\(r.finding.title): \(why)")
                }
            }
            findings.removeAll { f in results.contains { $0.finding.id == f.id && !Self.failed($0.outcome) } }
            selected = []
            refreshHolding()
            message = problems.isEmpty
                ? ("Moved \(done) item\(done == 1 ? "" : "s") out of the way · \(ByteSize.format(freed)) freed · restorable for 7 days", true)
                : ("\(done) done, \(problems.count) refused — \(problems.first!)", false)
        }
    }

    private static func failed(_ o: Cleaner.Outcome) -> Bool {
        switch o { case .skipped, .refused: true; default: false }
    }

    func runTool(_ f: Finding) {
        Task {
            let r = await Task.detached(priority: .userInitiated) { Cleaner(runOwnerTools: true).apply(f) }.value
            switch r.outcome {
            case .ran(let tool, let out): message = ("\(tool.name) finished (exit \(out.status))", out.status == 0)
            case .skipped(let why), .refused(let why): message = (why, false)
            default: message = ("Done", true)
            }
        }
    }

    func refreshHolding() { cuts = HoldingArea().list().sorted { $0.createdAt > $1.createdAt } }

    func restore(_ cut: CutManifest) {
        do {
            let paths = try HoldingArea().restore(cut.id)
            message = ("Restored \(paths.count) item\(paths.count == 1 ? "" : "s")", true)
        } catch { message = ("\(error)", false) }
        refreshHolding()
    }

    func purge(_ cut: CutManifest) {
        do {
            let m = try HoldingArea().purge(cut.id)
            message = ("Deleted for good · \(ByteSize.format(m.sizes.reclaimable))", true)
        } catch { message = ("\(error)", false) }
        refreshHolding()
    }
}

struct ScalpelView: View {
    @State private var model = ScalpelModel()
    @State private var tab = 0
    @State private var confirmCut = false
    @State private var confirmPurge: CutManifest?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tab == 0 { scanBody } else { holding }
        }
        .navigationTitle("Scalpel")
        .overlay(alignment: .bottom) { banner }
        .onAppear {
            // `--snapshot` with TALON_SNAPSHOT_SCAN=<dir> renders a real (read-only) scan.
            if Snapshot.requestedDirectory != nil, let dir = ProcessInfo.processInfo.environment["TALON_SNAPSHOT_SCAN"], model.tree == nil {
                model.root = dir
                model.scan()
            }
        }
        .confirmationDialog("Move \(model.selected.count) item\(model.selected.count == 1 ? "" : "s") out of the way?",
                            isPresented: $confirmCut, titleVisibility: .visible) {
            Button("Move \(ByteSize.format(selectedBytes))") { model.cutSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Folders go to the holding area (instant, same volume) and can be restored for 7 days; installers go to the Trash; duplicates become clones. Nothing is deleted outright.")
        }
        .confirmationDialog("Delete this cut for good?", isPresented: Binding(get: { confirmPurge != nil }, set: { if !$0 { confirmPurge = nil } }),
                            titleVisibility: .visible, presenting: confirmPurge) { cut in
            Button("Delete \(ByteSize.format(cut.sizes.reclaimable)) permanently", role: .destructive) { model.purge(cut) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("This can't be undone.") }
    }

    private var selectedBytes: UInt64 { model.selectedFindings.reduce(0) { $0 + $1.sizes.reclaimable } }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                Text("Scan").tag(0)
                Text("Holding area (\(model.cuts.count))").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            Spacer()
            if tab == 0 {
                Text((model.root as NSString).abbreviatingWithTildeInPath).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Button("Choose…") { choose() }.disabled(model.isScanning)
                Toggle("Find duplicates", isOn: $model.findDuplicates).toggleStyle(.checkbox)
                    .help("Hashing reads every candidate file, which updates its access time.")
                if model.isScanning {
                    Button("Stop", role: .cancel) { model.cancel() }
                } else {
                    Button(model.tree == nil ? "Scan" : "Scan again") { model.scan() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: model.root)
        if p.runModal() == .OK, let url = p.url { model.root = url.path }
    }

    // MARK: Scan

    @ViewBuilder private var scanBody: some View {
        switch model.state {
        case .idle where model.tree == nil:
            ContentUnavailableView {
                Label("Storage, cut precisely", systemImage: "scissors")
            } description: {
                Text("Scalpel measures the space you'd actually get back — clone-, hard-link- and snapshot-aware — and explains every item before you touch it. Every cut is reversible for 7 days.")
            } actions: {
                Button("Scan \((model.root as NSString).abbreviatingWithTildeInPath)") { model.scan() }.buttonStyle(.borderedProminent)
            }
        case .scanning(let p):
            VStack(spacing: 10) {
                ProgressView()
                Text(p.map { "\($0.files.formatted()) files · \(ByteSize.format($0.logicalBytes))" } ?? "Starting…").monospacedDigit()
                Text(p.map { ($0.currentPath as NSString).abbreviatingWithTildeInPath } ?? " ")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 600)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let why):
            ContentUnavailableView("Scan failed", systemImage: "exclamationmark.triangle", description: Text(why))
        default:
            if let tree = model.tree {
                HSplitView {
                    VStack(spacing: 0) {
                        summary(tree)
                        TreemapPane(model: model, tree: tree).padding(12)
                    }
                    .frame(minWidth: 420)
                    findingsList.frame(minWidth: 380, idealWidth: 460)
                }
            }
        }
    }

    private func summary(_ tree: ScanTree) -> some View {
        HStack(spacing: 18) {
            stat("Reclaimable", ByteSize.format(tree.totals.reclaimable))
            stat("On disk", ByteSize.format(tree.totals.onDisk))
            stat("Logical", ByteSize.format(tree.totals.logical))
            if let v = model.volume {
                stat("Free", ByteSize.format(v.free) + (v.availableIncludingPurgeable.map { " (Finder: \(ByteSize.format($0)))" } ?? ""))
            }
            Spacer()
            if !tree.stats.unreadable.isEmpty {
                Label("\(tree.stats.unreadable.count) unreadable", systemImage: "lock")
                    .font(.caption).foregroundStyle(.orange)
                    .help("Grant Full Disk Access to Talon in System Settings › Privacy & Security to see these folders.")
            }
        }
        .padding(.horizontal, 14).padding(.top, 10)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }

    private var findingsList: some View {
        VStack(spacing: 0) {
            List(selection: $model.inspected) {
                let groups = Dictionary(grouping: model.findings, by: \.category)
                ForEach(FindingCategory.allCases.filter { groups[$0] != nil }, id: \.self) { cat in
                    let items = groups[cat]!
                    Section {
                        ForEach(items) { f in FindingRow(finding: f, selected: binding(f)).tag(f.id) }
                    } header: {
                        HStack {
                            Text(cat.label)
                            Spacer()
                            Text(ByteSize.format(items.reduce(0) { $0 + $1.sizes.reclaimable })).monospacedDigit()
                        }
                    }
                }
            }
            if let id = model.inspected, let f = model.findings.first(where: { $0.id == id }) {
                Divider()
                FindingInspector(finding: f) { model.runTool(f) }.frame(maxHeight: 280)
            }
            Divider()
            HStack {
                Text(model.selected.isEmpty ? "Select items to cut" : "\(model.selected.count) selected · \(ByteSize.format(selectedBytes))")
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Select safe") { model.selected = Set(model.findings.filter { $0.tier == .safe && $0.removal != .never }.map(\.id)) }
                Button("Move to holding area…") { confirmCut = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty)
            }
            .padding(10)
        }
    }

    private func binding(_ f: Finding) -> Binding<Bool> {
        Binding(get: { model.selected.contains(f.id) },
                set: { on in if on { model.selected.insert(f.id) } else { model.selected.remove(f.id) } })
    }

    // MARK: Holding

    private var holding: some View {
        List {
            if model.cuts.isEmpty {
                Text("Nothing held. Cuts wait here for 7 days before they're deleted, and can be restored with one click.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.cuts, id: \.id) { cut in
                HStack(spacing: 12) {
                    Image(systemName: "archivebox").font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cut.title ?? cut.items.first.map { ($0.originalPath as NSString).lastPathComponent } ?? cut.id).font(.headline)
                        Text("\(cut.items.count) item\(cut.items.count == 1 ? "" : "s") · cut \(cut.createdAt.formatted(.relative(presentation: .named))) · purges \(cut.purgeDate(hold: HoldingArea.defaultHold).formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ByteSize.format(cut.sizes.reclaimable)).monospacedDigit()
                    Button("Restore") { model.restore(cut) }
                    Button("Delete now…", role: .destructive) { confirmPurge = cut }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { model.refreshHolding() }
    }

    @ViewBuilder private var banner: some View {
        if let m = model.message {
            Label(m.text, systemImage: m.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .padding(16)
                .task(id: m.text) { try? await Task.sleep(for: .seconds(6)); model.message = nil }
        }
    }
}

// MARK: - Findings

struct TierBadge: View {
    var tier: Tier
    var body: some View {
        Text(tier.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        switch tier { case .safe: .green; case .review: .orange; case .protected: .secondary }
    }
}

struct FindingRow: View {
    var finding: Finding
    @Binding var selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $selected).toggleStyle(.checkbox).labelsHidden()
                .disabled(finding.tier == .protected || finding.removal == .never)
            TierBadge(tier: finding.tier)
            Text(finding.title).lineLimit(1)
            Spacer()
            if let used = finding.lastUsed {
                Text(used.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
            }
            Text(ByteSize.format(finding.sizes.reclaimable)).monospacedDigit().frame(width: 72, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FindingInspector: View {
    var finding: Finding
    var runTool: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TierBadge(tier: finding.tier)
                    Text(finding.title).font(.headline)
                    Spacer()
                    Text(ByteSize.format(finding.sizes.reclaimable)).font(.headline).monospacedDigit()
                }
                row("What it is", finding.what)
                row("Why \(finding.tier.rawValue)", finding.why)
                row("After", finding.after)
                row("Removed by", finding.removal.label)
                if let w = finding.regenerationWrites, w > 0 {
                    row("SSD cost", "If it regenerates, about \(ByteSize.format(w)) is written again.")
                }
                if let owner = finding.owner { row("Owner", owner) }
                Text("Logical \(ByteSize.format(finding.sizes.logical)) · on disk \(ByteSize.format(finding.sizes.onDisk)) · reclaimable \(ByteSize.format(finding.sizes.reclaimable))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                ForEach(finding.paths.prefix(6), id: \.self) { p in
                    HStack {
                        Text((p as NSString).abbreviatingWithTildeInPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderless).help("Show in Finder")
                    }
                }
                if case .ownerTool(let tool) = finding.removal {
                    Button("Run \(tool.display)") { runTool() }.help(tool.note)
                }
            }
            .padding(12)
        }
    }

    private func row(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Treemap

/// The map: the current folder's children as rectangles sized by what deleting them would give
/// back (not by logical size). Click to drill in; the breadcrumb climbs back out.
struct TreemapPane: View {
    var model: ScalpelModel
    var tree: ScanTree

    var body: some View {
        let node = model.mapNode
        let kids = tree.children(of: node)
            .map { ($0, tree.sizes(of: $0).reclaimable) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(40)
        VStack(alignment: .leading, spacing: 8) {
            breadcrumb(node)
            GeometryReader { geo in
                let rects = Treemap.layout(kids.map { Double($0.1) }, in: CGRect(origin: .zero, size: geo.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(kids.indices, rects)), id: \.0) { i, r in
                        let (child, bytes) = kids[i]
                        Button {
                            if !tree.children(of: child).isEmpty { model.mapNode = child }
                        } label: {
                            ZStack(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(color(i).gradient)
                                if r.width > 70 && r.height > 34 {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(tree.name(of: child)).font(.caption.weight(.semibold)).lineLimit(1)
                                        Text(ByteSize.format(bytes)).font(.caption2).monospacedDigit()
                                    }
                                    .foregroundStyle(.white)
                                    .padding(6)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(width: max(0, r.width - 2), height: max(0, r.height - 2))
                        .offset(x: r.minX, y: r.minY)
                        .help("\(tree.path(of: child)) — \(ByteSize.format(bytes)) reclaimable")
                        .accessibilityLabel("\(tree.name(of: child)), \(ByteSize.format(bytes)) reclaimable")
                    }
                }
            }
        }
    }

    private func breadcrumb(_ node: Int32) -> some View {
        var chain: [Int32] = [node]
        while let p = tree.parent(of: chain.last!) { chain.append(p) }
        return HStack(spacing: 4) {
            ForEach(Array(chain.reversed().enumerated()), id: \.offset) { i, n in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(n == 0 ? (tree.path(of: 0) as NSString).abbreviatingWithTildeInPath : tree.name(of: n)) { model.mapNode = n }
                    .buttonStyle(.link).font(.callout)
            }
            Spacer()
            Text(ByteSize.format(tree.sizes(of: node).reclaimable) + " here").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func color(_ i: Int) -> Color {
        [Color.teal, .blue, .indigo, .purple, .pink, .orange, .green, .cyan][i % 8].opacity(0.85 - Double(min(i, 20)) * 0.015)
    }
}

/// Squarified treemap (Bruls, Huizing & van Wijk): rows of rectangles whose aspect ratios stay
/// close to 1, so small folders remain clickable.
enum Treemap {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        var areas = values.map { $0 * scale }
        var out: [CGRect] = []
        var r = rect
        while !areas.isEmpty {
            let side = Double(min(r.width, r.height))
            var row: [Double] = []
            var best = Double.infinity
            while let next = areas.first {
                let candidate = row + [next]
                let w = worst(candidate, side)
                if w > best && !row.isEmpty { break }
                best = w
                row = candidate
                areas.removeFirst()
            }
            let sum = row.reduce(0, +)
            if r.width >= r.height {
                let colW = CGFloat(sum / Double(r.height))
                var y = r.minY
                for a in row {
                    let h = CGFloat(a) / colW
                    out.append(CGRect(x: r.minX, y: y, width: colW, height: h))
                    y += h
                }
                r = CGRect(x: r.minX + colW, y: r.minY, width: r.width - colW, height: r.height)
            } else {
                let rowH = CGFloat(sum / Double(r.width))
                var x = r.minX
                for a in row {
                    let w = CGFloat(a) / rowH
                    out.append(CGRect(x: x, y: r.minY, width: w, height: rowH))
                    x += w
                }
                r = CGRect(x: r.minX, y: r.minY + rowH, width: r.width, height: r.height - rowH)
            }
        }
        return out
    }

    private static func worst(_ row: [Double], _ side: Double) -> Double {
        let s = row.reduce(0, +), mx = row.max() ?? 0, mn = row.min() ?? 0
        guard s > 0, mn > 0 else { return .infinity }
        return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
    }
}
