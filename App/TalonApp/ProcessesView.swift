import AppKit
import SwiftUI
import TalonIPC
import TalonModel

/// Every process, grouped under the app responsible for it, refreshing once a second.
/// NSOutlineView, not SwiftUI Table: ~600 live rows with stable identity and targeted reloads.
struct ProcessesView: View {
    var model: LiveModel
    @State private var search = ""
    @State private var grouped = true
    @State private var capTarget: CapTarget?
    @State private var banner: (text: String, ok: Bool)?

    struct CapTarget: Identifiable {
        var pid: Int32
        var name: String
        var id: Int32 { pid }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProcessOutline(snapshot: model.snapshot, frozen: model.frozen, grouped: grouped, filter: search) { action in
                switch action {
                case .freeze(let pid): run(.freeze(pid: pid))
                case .thaw(let pid): run(.thaw(pid: pid))
                case .cap(let pid, let name): capTarget = CapTarget(pid: pid, name: name)
                case .ceiling(let key):
                    if let app = model.snapshot?.apps.first(where: { $0.key == key }) { model.open(ceilingFor: app) }
                }
            }
            footer
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter processes")
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $grouped) {
                    Label("By app", systemImage: "square.stack.3d.up").tag(true)
                    Label("All processes", systemImage: "list.bullet").tag(false)
                }
                .pickerStyle(.segmented)
            }
        }
        .sheet(item: $capTarget) { t in
            CapSheet(target: t) { bytes in run(.capMemory(pid: t.pid, bytes: bytes)) }
        }
        .navigationTitle("Processes")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let s = model.snapshot {
                Text("\(s.readable) processes · \(s.apps.count) apps · sweep \(String(format: "%.1f", s.sweepSeconds * 1000)) ms")
                if s.denied > 0 {
                    Text("· \(s.denied) system processes need the root daemon").foregroundStyle(.orange)
                }
            }
            Spacer()
            if let banner {
                Label(banner.text, systemImage: banner.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(banner.ok ? Color.green : .orange)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func run(_ request: TalonRequest) {
        Task {
            let r = await model.perform(request)
            withAnimation {
                switch r {
                case .success(let m): banner = (m, true)
                case .failure(let e): banner = (e.message, false)
                }
            }
            try? await Task.sleep(for: .seconds(6))
            withAnimation { banner = nil }
        }
    }
}

struct CapSheet: View {
    var target: ProcessesView.CapTarget
    var apply: (UInt64) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = "2G"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hard memory ceiling").font(.headline)
            Text("The kernel stops **\(target.name)** (pid \(target.pid)) if it ever crosses this. It can't be raised past it — only removed by restarting the process. Needs talond running as root.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Ceiling", text: $text, prompt: Text("e.g. 2G, 800M"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let error = parseError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Set ceiling", action: submit).keyboardShortcut(.defaultAction).disabled(parseError != nil)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var parseError: String? {
        do {
            let b = try ByteSize.parse(text)
            return b < 16 << 20 ? "At least 16 MB" : nil
        } catch {
            return "Try 300M, 2G or 1.5GiB"
        }
    }

    private func submit() {
        guard parseError == nil, let b = try? ByteSize.parse(text) else { return }
        apply(b)
        dismiss()
    }
}

// MARK: - The outline

struct ProcessOutline: NSViewRepresentable {
    enum Action { case freeze(Int32), thaw(Int32), cap(Int32, String), ceiling(String) }

    var snapshot: ProcessSnapshot?
    var frozen: Set<Int32>
    var grouped: Bool
    var filter: String
    var onAction: (Action) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .inset
        outline.rowHeight = 22
        outline.usesAutomaticRowHeights = false
        outline.allowsMultipleSelection = false
        outline.autoresizesOutlineColumn = false
        outline.indentationPerLevel = 14
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        for c in Coordinator.Column.allCases {
            let col = NSTableColumn(identifier: c.id)
            col.title = c.title
            col.width = c.width
            col.minWidth = c == .name ? 200 : 50
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.rawValue, ascending: c == .name)
            if c != .name { col.headerCell.alignment = .right }
            outline.addTableColumn(col)
            if c == .name { outline.outlineTableColumn = col }
        }
        outline.sortDescriptors = [NSSortDescriptor(key: Coordinator.Column.memory.rawValue, ascending: false)]
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onAction = onAction
        context.coordinator.update(snapshot: snapshot, frozen: frozen, grouped: grouped, filter: filter)
    }

    // MARK: Coordinator

    final class Node: NSObject {
        let id: String
        var name = ""
        var key = ""
        var pid: Int32 = 0
        var count = 0
        var memory: UInt64 = 0
        var cpu = 0.0
        var writes = 0.0
        var isApp = false
        var frozen = false
        var children: [Node] = []

        init(id: String) { self.id = id }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        enum Column: String, CaseIterable {
            case name, pid, memory, cpu, writes
            var id: NSUserInterfaceItemIdentifier { .init(rawValue) }
            var title: String {
                switch self { case .name: "Name"; case .pid: "PID"; case .memory: "Memory"; case .cpu: "CPU"; case .writes: "Writes/s" }
            }
            var width: CGFloat {
                switch self { case .name: 320; case .pid: 70; case .memory: 100; case .cpu: 70; case .writes: 100 }
            }
        }

        weak var outline: NSOutlineView?
        var onAction: (Action) -> Void = { _ in }
        private var cache: [String: Node] = [:]
        private var roots: [Node] = []
        private var expanded: Set<String> = []
        private var shape: [String] = []
        private var last: (snapshot: ProcessSnapshot?, frozen: Set<Int32>, grouped: Bool, filter: String)?

        private func node(_ id: String) -> Node {
            if let n = cache[id] { return n }
            let n = Node(id: id)
            cache[id] = n
            return n
        }

        func update(snapshot: ProcessSnapshot?, frozen: Set<Int32>, grouped: Bool, filter: String) {
            last = (snapshot, frozen, grouped, filter)
            rebuild()
        }

        private func rebuild() {
            guard let outline, let last, let snap = last.snapshot else { return }
            let q = last.filter.trimmingCharacters(in: .whitespaces).lowercased()
            var live = Set<String>()

            func proc(_ p: ProcessSample) -> Node {
                let n = node("p:\(p.pid):\(p.startTime)")
                n.name = p.name; n.pid = p.pid; n.key = ""; n.count = 1
                n.memory = p.footprint; n.cpu = p.cpuPercent; n.writes = p.diskWriteRate
                n.frozen = last.frozen.contains(p.pid); n.isApp = false; n.children = []
                live.insert(n.id)
                return n
            }

            var newRoots: [Node] = []
            if last.grouped {
                let byApp = Dictionary(grouping: snap.processes, by: \.responsiblePID)
                for a in snap.apps {
                    let kids = (byApp[a.responsiblePID] ?? []).map(proc)
                    let appMatches = q.isEmpty || a.name.lowercased().contains(q)
                    let shown = appMatches ? kids : kids.filter { $0.name.lowercased().contains(q) || "\($0.pid)" == q }
                    if !appMatches && shown.isEmpty { continue }
                    let n = node("a:\(a.key):\(a.responsiblePID)")
                    n.name = a.name; n.key = a.key; n.pid = a.responsiblePID; n.count = a.processCount
                    n.memory = a.footprint; n.cpu = a.cpuPercent; n.writes = a.diskWriteRate
                    n.isApp = true; n.frozen = last.frozen.contains(a.responsiblePID)
                    n.children = a.processCount > 1 ? shown : []
                    live.insert(n.id)
                    newRoots.append(n)
                }
            } else {
                newRoots = snap.processes.filter { q.isEmpty || $0.name.lowercased().contains(q) || "\($0.pid)" == q }.map(proc)
            }
            cache = cache.filter { live.contains($0.key) }
            expanded = expanded.filter { live.contains($0) }

            let sorter = comparator(outline.sortDescriptors.first)
            newRoots.sort(by: sorter)
            for r in newRoots { r.children.sort(by: sorter) }

            let newShape = newRoots.flatMap { r in [r.id] + (expanded.contains(r.id) ? r.children.map(\.id) : []) }
            roots = newRoots
            if newShape == shape {
                // Same rows in the same order: refresh values in place, keep scroll and selection untouched.
                let rows = IndexSet(integersIn: 0..<outline.numberOfRows)
                outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
            } else {
                let selected = (outline.item(atRow: outline.selectedRow) as? Node)?.id
                outline.reloadData()
                for r in roots where expanded.contains(r.id) { outline.expandItem(r) }
                if let selected, let n = cache[selected] {
                    let row = outline.row(forItem: n)
                    if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
                }
                shape = newShape
            }
        }

        private func comparator(_ d: NSSortDescriptor?) -> (Node, Node) -> Bool {
            let asc = d?.ascending ?? false
            let col = Column(rawValue: d?.key ?? "") ?? .memory
            func less(_ a: Node, _ b: Node) -> Bool {
                switch col {
                case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
                case .pid: a.pid < b.pid
                case .memory: a.memory < b.memory
                case .cpu: a.cpu < b.cpu
                case .writes: a.writes < b.writes
                }
            }
            return { a, b in asc ? less(a, b) : less(b, a) }
        }

        // Data source

        func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node)?.children.count ?? roots.count
        }

        func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Node)?.children[index] ?? roots[index]
        }

        func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? Node)?.children.isEmpty ?? true)
        }

        func outlineView(_ o: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            shape = []
            rebuild()
        }

        func outlineViewItemDidExpand(_ n: Notification) {
            if let node = n.userInfo?["NSObject"] as? Node { expanded.insert(node.id); shape = []; rebuild() }
        }

        func outlineViewItemDidCollapse(_ n: Notification) {
            if let node = n.userInfo?["NSObject"] as? Node { expanded.remove(node.id); shape = []; rebuild() }
        }

        // Cells

        func outlineView(_ o: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
            guard let column, let c = Column(rawValue: column.identifier.rawValue), let n = item as? Node else { return nil }
            let cell = (o.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView) ?? makeCell(c)
            let field = cell.textField!
            switch c {
            case .name:
                field.stringValue = n.name + (n.isApp && n.count > 1 ? "  (\(n.count))" : "")
                field.textColor = n.frozen ? .secondaryLabelColor : .labelColor
                cell.imageView?.image = n.frozen ? NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "paused")
                    : n.isApp ? AppIcons.icon(for: n.key) : nil
                cell.imageView?.isHidden = cell.imageView?.image == nil
            case .pid: field.stringValue = "\(n.pid)"
            case .memory: field.stringValue = ByteSize.format(n.memory)
            case .cpu: field.stringValue = String(format: "%.1f", n.cpu)
            case .writes: field.stringValue = n.writes >= 1 ? ByteSize.format(n.writes) : "–"
            }
            if c != .name { field.textColor = n.frozen ? .tertiaryLabelColor : (c == .pid ? .secondaryLabelColor : .labelColor) }
            return cell
        }

        private func makeCell(_ c: Column) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = c.id
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.alignment = c == .name ? .left : .right
            cell.addSubview(field)
            cell.textField = field
            if c == .name {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ])
            } else {
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        // Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? Node else { return }
            let who = n.isApp ? "\(n.name) (main process)" : n.name
            if n.frozen {
                menu.addItem(item("Resume \(who)", "play.fill") { [weak self] in self?.onAction(.thaw(n.pid)) })
            } else {
                menu.addItem(item("Pause \(who)", "pause.fill") { [weak self] in self?.onAction(.freeze(n.pid)) })
            }
            if n.isApp {
                menu.addItem(item("Ceiling for \(n.name)…", "gauge.with.needle") { [weak self] in self?.onAction(.ceiling(n.key)) })
            }
            menu.addItem(item("Hard-cap this process's memory…", "lock") { [weak self] in self?.onAction(.cap(n.pid, n.name)) })
            menu.addItem(.separator())
            menu.addItem(item("Copy PID \(n.pid)", "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(n.pid)", forType: .string)
            })
            if n.key.hasSuffix(".app") {
                menu.addItem(item("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: n.key)]) })
            }
        }

        private func item(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let target = MenuAction(action)
            let i = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            i.target = target
            i.representedObject = target
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return i
        }
    }
}

/// Target for a closure-backed menu item; the item retains it through `representedObject`.
final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
