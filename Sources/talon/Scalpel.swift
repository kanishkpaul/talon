import ArgumentParser
import Darwin
import Foundation
import TalonIPC
import TalonModel
import TalonScalpel

// MARK: - scalpel

struct ScalpelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scalpel",
        abstract: "Exact storage analysis and reversible cleanup.",
        discussion: """
        Every size is what deleting the item would actually give back on APFS (clones, hard links and
        snapshots accounted for). Cuts move items to ~/.talon/holding for 7 days; nothing is deleted directly.
        Examples:
          talon scalpel scan ~
          talon scalpel why ~/Library/Developer
          talon scalpel clean --tier safe            # dry run: shows the plan
          talon scalpel clean --tier safe --yes      # cut into the holding area
          talon scalpel holding
        """,
        subcommands: [Scan.self, Why.self, Clean.self, Held.self, Restore.self, Purge.self, Dedupe.self],
        defaultSubcommand: Scan.self)

    static let home = realpath(NSHomeDirectory(), nil).map { p in defer { free(p) }; return String(cString: p) } ?? NSHomeDirectory()

    /// `~/Library` instead of `/Users/you/Library`.
    static func display(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        if path.hasPrefix("/System/Volumes/Data" + home + "/") { return "~" + path.dropFirst(("/System/Volumes/Data" + home).count) }
        return path
    }

    static func badge(_ t: Tier) -> String {
        switch t {
        case .safe: Style.green("safe")
        case .review: Style.yellow("review")
        case .protected: Style.blue("protected")
        }
    }

    static func ago(_ d: Date?) -> String {
        guard let d else { return "—" }
        let s = Date().timeIntervalSince(d)
        if s < 86_400 { return "today" }
        let days = Int(s / 86_400)
        if days < 60 { return "\(days)d ago" }
        if days < 730 { return "\(days / 30) mo ago" }
        return "\(days / 365) y ago"
    }

    static func refuse(_ message: String) -> ExitCode { fail(TalonError(.refused, message)) }

    /// Scans with a one-line progress meter on stderr (terminals only).
    static func scan(_ path: String, options: DiskScanner.Options) throws -> ScanTree {
        let live = isatty(STDERR_FILENO) != 0
        let clear = { if live { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) } }
        defer { clear() }
        do {
            return try DiskScanner(options: options).scan(path, progress: live ? showProgress : nil)
        } catch {
            clear()
            throw fail(TalonError(.failed, "\(error)"))
        }
    }

    @Sendable static func showProgress(_ p: ScanProgress) {
        let line = "scanning \(p.files.formatted()) files · \(ByteSize.format(p.logicalBytes)) · \(display(p.currentPath))"
        FileHandle.standardError.write(Data(("\r\u{1B}[K" + Style.dim(truncate(line, 100))).utf8))
    }

    static func findings(home: String, options: FindingsOptions, duplicates: Bool) throws -> (ScanTree, [Finding]) {
        var o = options
        o.findDuplicates = duplicates
        let tree = try scan(home, options: FindingsEngine.scanOptions(o))
        return (tree, FindingsEngine(home: self.home, tree: tree, options: o).run())
    }

    static func printFindings(_ findings: [Finding], verbose: Bool = true) {
        for (category, group) in Dictionary(grouping: findings, by: \.category).sorted(by: { a, b in
            (FindingCategory.allCases.firstIndex(of: a.key) ?? 0) < (FindingCategory.allCases.firstIndex(of: b.key) ?? 0)
        }) {
            let total = group.reduce(UInt64(0)) { $0 + $1.sizes.reclaimable }
            print("\n" + Style.bold(category.label) + Style.dim(" · \(ByteSize.format(total)) reclaimable"))
            var t = Table(headers: ["TIER", "ITEM", "RECLAIMABLE", "LAST USED", "REMOVED BY"], right: [2])
            for f in group.sorted(by: { $0.sizes.reclaimable > $1.sizes.reclaimable }) {
                let size = f.category == .snapshots && f.sizes.reclaimable == 0 ? Style.dim("unknown") : ByteSize.format(f.sizes.reclaimable)
                t.rows.append([badge(f.tier), truncate(f.title, 48), size, ago(f.lastUsed), truncate(f.removal.label, 34)])
            }
            print(t.render())
            if verbose, let top = group.max(by: { $0.sizes.reclaimable < $1.sizes.reclaimable }) {
                print(Style.dim("  e.g. \(truncate(top.title, 40)): \(top.after)"))
            }
        }
    }

    static func printFolders(_ folders: [FolderSummary], under root: String, indent: Int = 0, table: inout Table) {
        for f in folders {
            let rel = f.path.hasPrefix(root + "/") ? String(f.path.dropFirst(root.count + 1)) : display(f.path)
            let name = String(repeating: "  ", count: indent) + (indent > 0 ? (rel as NSString).lastPathComponent : rel)
            table.rows.append([truncate(name, 56), ByteSize.format(f.sizes.logical), ByteSize.format(f.sizes.onDisk),
                               Style.bold(ByteSize.format(f.sizes.reclaimable)), ago(f.lastModified)])
            printFolders(f.children, under: root, indent: indent + 1, table: &table)
        }
    }

    // MARK: scan

    struct Scan: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Map a folder by reclaimable space and list what can go.")
        @Argument(help: "Folder to scan (default: your home folder). `/` scans the Data volume.") var path = "~"
        @Option(name: .long, help: "Folders to show at the top level of the map.") var top = 10
        @Flag(inversion: .prefixedNo, help: "Hash same-size files to find duplicates (16 MB and up).") var duplicates = true
        @Flag(name: .long, help: "Map only; skip the findings.") var mapOnly = false
        @Option(name: .long, help: "Hide findings smaller than this.") var minSize = Bytes(argument: "1M")!
        @Option(name: .long, help: ArgumentHelp("Directory reads in flight at once.", visibility: .hidden)) var workers = 2
        @OptionGroup var output: JSONFlag

        func run() throws {
            let root = DiskScanner.canonicalRoot(path)
            var o = FindingsOptions()
            o.findDuplicates = duplicates
            o.minimumBytes = minSize.value
            let tree = try ScalpelCommand.scan(root, options: FindingsEngine.scanOptions(o, workers: workers))
            let findings = mapOnly ? [] : FindingsEngine(home: ScalpelCommand.home, tree: tree, options: o).run()
            let report = ScanReport(stats: tree.stats, totals: tree.totals, folders: tree.summary(top: top, depth: 2),
                                    findings: findings, volume: VolumeSpace.of(root))
            if output.json { try JSON.print(report); return }

            let st = tree.stats
            print(Style.bold("scalpel") + Style.dim(" · \(ScalpelCommand.display(root)) · \(st.files.formatted()) files, \(st.directories.formatted()) folders in "
                + String(format: "%.1f s (%.1f s CPU)", st.seconds, st.cpuSeconds)))
            var t = Table(headers: ["FOLDER", "LOGICAL", "ON DISK", "RECLAIMABLE", "CHANGED"], right: [1, 2, 3])
            ScalpelCommand.printFolders(report.folders, under: tree.root, table: &t)
            t.rows.append([Style.bold("total"), ByteSize.format(tree.totals.logical), ByteSize.format(tree.totals.onDisk),
                           Style.bold(ByteSize.format(tree.totals.reclaimable)), ""])
            print(t.render())
            if let v = report.volume {
                let purgeable = v.availableIncludingPurgeable.map { $0 > v.free ? Style.dim(" (Finder counts \(ByteSize.format($0)) with purgeable space)") : "" } ?? ""
                print(Style.dim("free space ") + ByteSize.format(v.free) + Style.dim(" of \(ByteSize.format(v.total))") + purgeable)
            }
            if st.cloneGroups + st.hardLinkGroups > 0 {
                print(Style.dim("\(st.cloneGroups.formatted()) clone groups and \(st.hardLinkGroups.formatted()) hard-linked files counted once"))
            }
            if !st.unreadable.isEmpty {
                let fda = st.unreadable.contains { $0.errno == EPERM }
                print(Style.yellow("\(st.unreadable.count) unreadable") + Style.dim(fda ? " — give your terminal Full Disk Access to see them:" : ":"))
                for u in st.unreadable.prefix(5) { print(Style.dim("  \(ScalpelCommand.display(u.path)) (\(u.reason))")) }
                if st.unreadable.count > 5 { print(Style.dim("  … and \(st.unreadable.count - 5) more (--json lists all)")) }
            }
            guard !mapOnly else { return }
            if findings.isEmpty { print("\nno findings"); return }
            ScalpelCommand.printFindings(findings)
            let safe = findings.filter { $0.tier == .safe }.reduce(UInt64(0)) { $0 + $1.sizes.reclaimable }
            print("\n" + Style.dim("safe to cut now: ") + Style.green(ByteSize.format(safe)) + Style.dim(" — `talon scalpel clean --tier safe` shows the plan"))
        }
    }

    // MARK: why

    struct Why: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Explain one path: what it is, what it costs, what removing it does.")
        @Argument(help: "A file or folder.") var path: String
        @OptionGroup var output: JSONFlag

        func run() throws {
            let e: Explanation
            do { e = try Explanation.explain(path, home: ScalpelCommand.home) } catch { throw ScalpelCommand.refuse("\(error)") }
            if output.json { try JSON.print(e); return }
            func row(_ l: String, _ v: String) { print(pad(Style.dim(l), 14) + v) }
            print(Style.bold(ScalpelCommand.display(e.path)) + Style.dim(" · \(e.kind)"))
            row("Logical", ByteSize.format(e.sizes.logical))
            row("On disk", ByteSize.format(e.sizes.onDisk))
            row("Reclaimable", Style.bold(ByteSize.format(e.sizes.reclaimable))
                + (e.sizes.reclaimable + (1 << 20) < e.sizes.onDisk ? Style.dim(" (the rest is shared with clones, hard links or snapshots elsewhere)") : ""))
            row("Changed", ScalpelCommand.ago(e.lastModified))
            if let n = e.namedAfter { row("Named after", n) }
            if let p = e.protected { row("Protected", Style.blue(p)) }
            if !e.unreadable.isEmpty { row("Unreadable", Style.yellow("\(e.unreadable.count) folders inside (\(e.unreadable[0].reason))")) }
            if e.findings.isEmpty {
                print("\n" + (e.protected == nil ? "Nothing scalpel recognises — it's yours to judge." : "scalpel never touches this."))
                return
            }
            for f in e.findings.prefix(10) {
                let rel = f.paths.contains(e.path) ? "" : f.paths.contains(where: { e.path.hasPrefix($0 + "/") }) ? Style.dim(" (part of)") : Style.dim(" (inside)")
                print("\n" + ScalpelCommand.badge(f.tier) + "  " + Style.bold(f.title) + rel + Style.dim(" · \(f.category.label)"))
                row("What", f.what)
                row("Why \(f.tier.rawValue)", f.why)
                row("After", f.after)
                row("Removed by", f.removal.label)
                if let o = f.owner { row("Owner", o) }
                row("Reclaimable", ByteSize.format(f.sizes.reclaimable))
            }
            if e.findings.count > 10 { print(Style.dim("\n… and \(e.findings.count - 10) more (--json lists all)")) }
        }
    }

    // MARK: clean

    struct Clean: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Cut findings into the holding area. A dry run unless you pass --yes.",
            discussion: "Owner tools (brew cleanup, xcrun simctl, docker system prune, …) only run with --run-tools.")
        @Option(name: .long, help: "Up to which tier: safe, or review (safe and review).") var tier: Tier = .safe
        @Option(name: .long, parsing: .upToNextOption, help: "Only these categories: \(FindingCategory.allCases.map(\.rawValue).joined(separator: ", ")).")
        var category: [FindingCategory] = []
        @Flag(name: .long, help: "Show the plan only (the default without --yes).") var dryRun = false
        @Flag(name: .long, help: "Carry out the plan.") var yes = false
        @Flag(name: .long, help: "Also run owner cleanup tools for findings that use them.") var runTools = false
        @Flag(name: .long, help: "Include caches used in the last 14 days (they'd regenerate soon, costing SSD writes).") var includeRecent = false
        @OptionGroup var output: JSONFlag

        /// Below talon's free-space floor, recently used caches are fair game: the space is needed now.
        static let floor: UInt64 = 60 << 30
        static let recent: TimeInterval = 14 * 86_400

        func validate() throws {
            if tier == .protected { throw ValidationError("protected items are never cleaned; use --tier safe or review") }
        }

        func run() throws {
            let (_, all) = try ScalpelCommand.findings(home: ScalpelCommand.home, options: FindingsOptions(), duplicates: false)
            let candidates = all.filter { $0.tier <= tier && $0.tier != .protected && $0.removal != .never
                && (category.isEmpty || category.contains($0.category)) }
            // Clearing a cache that's in use only buys space back until it regenerates, and wears the SSD doing it.
            let short = (VolumeSpace.of(ScalpelCommand.home)?.free ?? .max) < Clean.floor
            let isRecent = { (f: Finding) in
                f.regenerationWrites != nil && f.lastUsed.map { Date().timeIntervalSince($0) < Clean.recent } ?? false
            }
            let isTool = { (f: Finding) in if case .ownerTool = f.removal { return true } else { return false } }
            let recent = includeRecent || short ? [] : candidates.filter(isRecent)
            let tools = runTools ? [] : candidates.filter { isTool($0) && !isRecent($0) }
            let plan = candidates.filter { f in !recent.contains { $0.id == f.id } && !tools.contains { $0.id == f.id } }
            let act = yes && !dryRun
            if output.json && !act { try JSON.print(plan); return }
            func bytes(_ fs: [Finding]) -> String { ByteSize.format(fs.reduce(UInt64(0)) { $0 + $1.sizes.reclaimable }) }

            let rewrites = plan.compactMap(\.regenerationWrites).reduce(0, +)
            if !output.json {
                if !plan.isEmpty { ScalpelCommand.printFindings(plan, verbose: false) }
                print("\n" + Style.bold("Plan: ") + "\(plan.count) items, " + Style.green(bytes(plan)) + " reclaimable"
                      + (rewrites > 0 ? Style.dim(" · about \(ByteSize.format(rewrites)) of SSD writes if they regenerate") : ""))
                if !recent.isEmpty {
                    print(Style.dim("left out: \(recent.count) caches used in the last 14 days (\(bytes(recent))) — they'd come straight back; --include-recent adds them"))
                }
                if !tools.isEmpty {
                    print(Style.dim("left out: \(tools.count) owner-tool cleanups (\(bytes(tools))) — --run-tools runs: ")
                          + Set(tools.compactMap { f -> String? in if case .ownerTool(let t) = f.removal { t.display } else { nil } }).sorted().joined(separator: " · "))
                }
            }
            guard !plan.isEmpty else { return }
            guard act else {
                print(Style.dim("dry run — nothing changed. Add --yes to cut these into ~/.talon/holding (kept 7 days)."))
                return
            }

            let cleaner = Cleaner(runOwnerTools: runTools, attachOwnerTools: isatty(STDIN_FILENO) != 0 && !output.json)
            var freed: UInt64 = 0
            var results: [Row] = []
            for f in plan {
                let r = cleaner.apply(f)
                let line: String
                switch r.outcome {
                case .held(let m): freed += f.sizes.reclaimable; line = Style.green("✓ held ") + f.title + Style.dim(" · cut \(m.id)")
                case .trashed: freed += f.sizes.reclaimable; line = Style.green("✓ trashed ") + f.title
                case .cloned(let n, let c, let failures):
                    freed += n
                    line = Style.green("✓ cloned \(c) ") + f.title + (failures.isEmpty ? "" : Style.yellow(" · \(failures.count) skipped: \(failures[0])"))
                case .ran(let t, let out):
                    line = (out.ok ? Style.green("✓ ran ") : Style.red("✗ ran ")) + t.display + (out.ok ? "" : Style.dim(" (exit \(out.status))"))
                    if !out.stdout.isEmpty && !output.json { print(Style.dim(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines))) }
                case .skipped(let why): line = Style.dim("· skipped \(f.title): \(why)")
                case .refused(let why): line = Style.yellow("✗ refused \(f.title): \(why)")
                }
                results.append(Row(finding: f.id, title: f.title, outcome: "\(r.outcome)"))
                if !output.json { print(line) }
            }
            if output.json { try JSON.print(results); return }
            print("\n" + Style.bold("Freed ") + Style.green(ByteSize.format(freed)) + Style.dim(" · restore with `talon scalpel restore <cut-id>`; purged after 7 days"))
        }

        struct Row: Encodable { var finding: String; var title: String; var outcome: String }
    }

    // MARK: holding

    struct Held: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "holding", abstract: "What's in the holding area, and when it's purged.")
        @OptionGroup var output: JSONFlag

        func run() throws {
            let area = HoldingArea()
            let cuts = area.list()
            if output.json { try JSON.print(cuts); return }
            guard !cuts.isEmpty else { print("the holding area is empty"); return }
            var t = Table(headers: ["CUT", "AGE", "ITEMS", "RECLAIMABLE", "PURGES", "WHAT"], right: [2, 3])
            for c in cuts {
                let left = c.purgeDate(hold: area.hold).timeIntervalSinceNow
                t.rows.append([c.id, ScalpelCommand.ago(c.createdAt), "\(c.items.count)", ByteSize.format(c.sizes.reclaimable),
                               left <= 0 ? Style.yellow("due") : "in " + TimeSpan.format(left),
                               truncate(c.title ?? c.items.first.map { ScalpelCommand.display($0.originalPath) } ?? "", 44)])
            }
            print(t.render())
            print(Style.dim("\(ByteSize.format(cuts.reduce(UInt64(0)) { $0 + $1.sizes.reclaimable })) held in \(ScalpelCommand.display(area.root))"))
        }
    }

    struct Restore: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Put a cut back where it came from (never overwrites).")
        @Argument(help: "Cut id or unique prefix, from `talon scalpel holding`.") var cut: String

        func run() throws {
            do {
                let paths = try HoldingArea().restore(cut)
                for p in paths { print(Style.green("✓ restored ") + ScalpelCommand.display(p)) }
            } catch { throw ScalpelCommand.refuse("\(error)") }
        }
    }

    struct Purge: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete held cuts for good. A dry run unless you pass --yes.")
        @Argument(help: "One cut id (or prefix). Without it, every cut older than --older-than.") var cut: String?
        @Option(name: .long, help: "Age, e.g. 7d, 24h.") var olderThan = TimeRange(argument: "7d")!
        @Flag(name: .long, help: "Delete for real.") var yes = false

        func run() throws {
            let area = HoldingArea()
            let targets: [CutManifest]
            do {
                if let cut { targets = [try area.find(cut)] }
                else { targets = area.list().filter { Date().timeIntervalSince($0.createdAt) >= olderThan.seconds } }
            } catch { throw ScalpelCommand.refuse("\(error)") }
            guard !targets.isEmpty else { print("nothing to purge"); return }
            for m in targets {
                print((yes ? "" : Style.dim("would purge ")) + m.id + Style.dim(" · \(ByteSize.format(m.sizes.reclaimable)) · ") + (m.title ?? ""))
            }
            guard yes else { print(Style.dim("dry run — add --yes to delete these for good")); return }
            var freed: UInt64 = 0
            for m in targets {
                do { try area.purge(m.id); freed += m.sizes.reclaimable } catch { stderr(Style.red("talon: ") + "\(error)") }
            }
            print(Style.green("✓ purged ") + ByteSize.format(freed))
        }
    }

    // MARK: dedupe

    struct Dedupe: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replace duplicate files with APFS clones: every path stays, the space comes back. A dry run unless --yes.")
        @Argument(help: "Folder to search.") var path: String
        @Option(name: .long, help: "Ignore files smaller than this.") var minSize = Bytes(argument: "1M")!
        @Flag(name: .long, help: "Show the plan only (the default without --yes).") var dryRun = false
        @Flag(name: .long, help: "Replace the copies.") var yes = false
        @OptionGroup var output: JSONFlag

        func run() throws {
            let root = DiskScanner.canonicalRoot(path)
            let tree = try ScalpelCommand.scan(root, options: .init(recordFilesAtLeast: max(1, minSize.value)))
            let groups = Duplicates.find(tree.files, minSize: minSize.value)
            let act = yes && !dryRun
            if output.json && !act { try JSON.print(groups); return }
            guard !groups.isEmpty else { print("no duplicates of \(ByteSize.format(minSize.value)) or more in \(ScalpelCommand.display(root))"); return }
            let total = groups.reduce(UInt64(0)) { $0 + $1.reclaimable }
            if !output.json {
                for g in groups.prefix(act ? groups.count : 20) {
                    print(Style.bold(ByteSize.format(g.reclaimable)) + "  keep " + ScalpelCommand.display(g.keep.path))
                    for c in g.copies { print("        " + Style.dim("clone → ") + ScalpelCommand.display(c.path)) }
                }
                if !act && groups.count > 20 { print(Style.dim("… and \(groups.count - 20) more groups")) }
                print(Style.bold("\(groups.count) groups, ") + Style.green(ByteSize.format(total)) + " reclaimable")
            }
            guard act else { print(Style.dim("dry run — add --yes to replace the copies with clones")); return }
            // You pointed at this folder, so it's the allowed root; protected paths inside it still refuse.
            var guardrails = CutGuard(allowedRoots: [root], home: ScalpelCommand.home)
            guardrails.checkRunningApps = false
            var freed: UInt64 = 0
            var failures = 0
            for g in groups {
                for c in g.copies {
                    do {
                        try guardrails.check(c.path)
                        freed += try Duplicates.replaceWithClone(original: g.keep.path, duplicate: c.path)
                    } catch {
                        failures += 1
                        stderr(Style.yellow("skipped ") + "\(error)")
                    }
                }
            }
            print(Style.green("✓ freed ") + ByteSize.format(freed) + (failures > 0 ? Style.dim(" · \(failures) skipped") : ""))
        }
    }
}

extension Tier: ExpressibleByArgument {}
extension FindingCategory: ExpressibleByArgument {}
