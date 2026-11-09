import CoreServices
import Darwin
import Foundation
import TalonModel

public struct FindingsOptions: Sendable {
    /// A repo with no commit (and no edited file) for this long has stale dependencies.
    public var staleProjectAge: TimeInterval = 180 * 86_400
    public var downloadsAge: TimeInterval = 30 * 86_400
    public var largeFileSize: UInt64 = 1 << 30
    public var largeFileAge: TimeInterval = 180 * 86_400
    public var duplicateMinSize: UInt64 = 16 << 20
    /// Leftovers something wrote to recently aren't leftovers: something still uses them.
    public var leftoverQuietPeriod: TimeInterval = 30 * 86_400
    /// Findings smaller than this are noise (snapshots and protected context are always shown).
    public var minimumBytes: UInt64 = 1 << 20
    /// Run the read-only listings (`xcrun simctl list`, `tmutil listlocalsnapshots`).
    public var runTools = true
    public var findDuplicates = true
    /// Installed apps; discovered on first use when nil.
    public var inventory: AppInventory?
    public var now = Date()

    public init() {}
}

/// Turns a scan into findings. Location detectors look in the places tools keep their data; tree
/// detectors use what the scan noted on the way (dependency folders, large files). Only findings that
/// overlap `scope` are produced, so `why <path>` reuses the same rules on one path.
public struct FindingsEngine: Sendable {
    public static let markerNames: Set<String> = ["node_modules", ".venv", "venv", "target", ".build"]

    /// DiskScanner options that collect what the tree detectors need.
    public static func scanOptions(_ o: FindingsOptions, workers: Int = 2) -> DiskScanner.Options {
        DiskScanner.Options(workers: workers, recordFilesAtLeast: min(o.largeFileSize, o.duplicateMinSize), markerNames: markerNames)
    }

    public var home: String
    public var tree: ScanTree?
    public var scope: String
    public var options: FindingsOptions

    public init(home: String = NSHomeDirectory(), tree: ScanTree?, scope: String? = nil, options: FindingsOptions = FindingsOptions()) {
        self.home = realPath(home) ?? home
        self.tree = tree
        self.scope = scope ?? tree?.root ?? self.home
        self.options = options
    }

    public func run() -> [Finding] {
        var out: [Finding] = []
        out += buildOutput()
        out += simulators()
        out += packageCaches()
        out += containers()
        out += aiModels()
        out += staleProjects()
        out += appLeftovers()
        out += downloads()
        let covered = out.flatMap(\.paths)
        out += duplicates()
        out += largeOld(excluding: covered)
        out += snapshots()
        out += system()
        let order = Dictionary(uniqueKeysWithValues: FindingCategory.allCases.enumerated().map { ($1, $0) })
        return out
            .filter { $0.sizes.reclaimable >= options.minimumBytes || $0.category == .snapshots || $0.tier == .protected }
            .sorted { (order[$0.category] ?? 0, $1.sizes.reclaimable, $0.title) < (order[$1.category] ?? 0, $0.sizes.reclaimable, $1.title) }
    }

    // MARK: - Helpers

    func overlaps(_ path: String) -> Bool {
        path == scope || path.hasPrefix(scope + "/") || scope.hasPrefix(path + "/") || scope == "/"
    }

    func list(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0 != ".DS_Store" }.sorted()
    }

    func isDir(_ path: String) -> Bool { AppInventory.isDirectory(path) }
    func exists(_ path: String) -> Bool { var st = stat(); return lstat(path, &st) == 0 }

    /// Sizes and newest modification: from the tree when it walked the path, else a fresh walk.
    func measure(_ path: String) -> (sizes: Sizes, newest: Date?) {
        if let t = tree, let n = t.node(at: path) { return (t.sizes(of: n), t.lastModified(of: n)) }
        guard let t = try? DiskScanner(options: .init(workers: 2)).scan(path) else { return (Sizes(), nil) }
        if let e = Entry.stat(path), e.type != VDIR.rawValue { return (t.totals, Date(timeIntervalSince1970: TimeInterval(e.raw.mtime))) }
        return (t.totals, t.lastModified(of: 0))
    }

    func ago(_ d: Date?) -> String {
        guard let d else { return "never" }
        let s = options.now.timeIntervalSince(d)
        if s < 86_400 { return "today" }
        let days = Int(s / 86_400)
        if days < 60 { return "\(days) days ago" }
        if days < 730 { return "\(days / 30) months ago" }
        return "\(days / 365) years ago"
    }

    func regen(_ s: Sizes) -> String {
        "If it regenerates, about \(ByteSize.format(s.logical)) is written to the SSD again."
    }

    /// Dependency and build folders nested in another one belong to it.
    func nested(_ path: String) -> Bool {
        let parts = path.dropFirst(home.count).split(separator: "/").dropLast()
        return parts.contains { FindingsEngine.markerNames.contains(String($0)) || $0 == ".talon" || $0 == "Trash" || $0 == ".Trash" }
    }

    /// Marker folders the scan noted, plus the scan root itself when it is one.
    func markers(named names: Set<String>) -> [String] {
        guard let t = tree else { return [] }
        var out = t.markers.filter { names.contains($0.name) && $0.node != nil }.map { t.path(of: $0.node!) }
        if names.contains((t.root as NSString).lastPathComponent) { out.append(t.root) }
        return out.filter { overlaps($0) && !nested($0) }.sorted()
    }

    // MARK: - Developer build output

    func buildOutput() -> [Finding] {
        var out: [Finding] = []
        let xcode = home + "/Library/Developer/Xcode"
        let dd = xcode + "/DerivedData"
        for name in list(dd) where isDir(dd + "/" + name) {
            let path = dd + "/" + name
            guard overlaps(path) else { continue }
            let (s, last) = measure(path)
            let project = name.hasSuffix(".noindex") ? name : name.split(separator: "-").dropLast().joined(separator: "-")
            let what = name.hasSuffix(".noindex") ? "Xcode's shared \(name.replacingOccurrences(of: ".noindex", with: "")) for all projects."
                : "Xcode's build products, index and intermediates for \(project)."
            out.append(Finding(category: .buildOutput, tier: .safe, title: "DerivedData · \(project.isEmpty ? name : project)", paths: [path],
                               owner: "Xcode", ownerBundleID: "com.apple.dt.Xcode", lastUsed: last, sizes: s, what: what,
                               why: "Xcode rebuilds it from source; nothing in it is unique. Last touched \(ago(last)).",
                               after: "The next Xcode build of \(project.isEmpty ? "these projects" : project) is a full build, and indexing starts over. " + regen(s),
                               removal: .holdingArea, regenerationWrites: s.logical))
        }
        let archives = xcode + "/Archives"
        if isDir(archives), overlaps(archives) {
            let (s, last) = measure(archives)
            out.append(Finding(category: .buildOutput, tier: .review, title: "Xcode Archives", paths: [archives], owner: "Xcode",
                               ownerBundleID: "com.apple.dt.Xcode", lastUsed: last, sizes: s,
                               what: "Archived builds you made for distribution, with their debug symbols (dSYMs).",
                               why: "Not regenerable: the dSYMs symbolicate crash reports from builds you shipped.",
                               after: "Crash reports from those builds can't be symbolicated unless the dSYMs are uploaded elsewhere.",
                               removal: .holdingArea))
        }
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            let ds = xcode + "/\(platform) DeviceSupport"
            for name in list(ds) where isDir(ds + "/" + name) {
                let path = ds + "/" + name
                guard overlaps(path) else { continue }
                let (s, last) = measure(path)
                out.append(Finding(category: .buildOutput, tier: .safe, title: "\(platform) DeviceSupport · \(name)", paths: [path],
                                   owner: "Xcode", ownerBundleID: "com.apple.dt.Xcode", lastUsed: last, sizes: s,
                                   what: "Debug symbols Xcode copied from a \(platform) device running \(name).",
                                   why: "Copied again automatically from the device; last used \(ago(last)).",
                                   after: "The next time you debug on a device running this version, Xcode copies the symbols again (a few minutes). " + regen(s),
                                   removal: .holdingArea, regenerationWrites: s.logical))
            }
        }
        for path in markers(named: ["target"]) where exists((path as NSString).deletingLastPathComponent + "/Cargo.toml") {
            let (s, last) = measure(path)
            let project = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            out.append(Finding(category: .buildOutput, tier: .safe, title: "Cargo target · \(project)", paths: [path], owner: "Cargo",
                               lastUsed: last, sizes: s, what: "Rust build output for \(project).",
                               why: "cargo rebuilds it from source. Last built \(ago(last)).",
                               after: "The next `cargo build` of \(project) compiles everything from scratch. " + regen(s),
                               removal: .holdingArea, regenerationWrites: s.logical))
        }
        for path in markers(named: [".build"]) where exists((path as NSString).deletingLastPathComponent + "/Package.swift") {
            let (s, last) = measure(path)
            let project = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            out.append(Finding(category: .buildOutput, tier: .safe, title: "SwiftPM .build · \(project)", paths: [path], owner: "SwiftPM",
                               lastUsed: last, sizes: s, what: "Swift package build output and checkouts for \(project).",
                               why: "swift build recreates it (re-fetching dependencies). Last built \(ago(last)).",
                               after: "The next `swift build` of \(project) resolves and compiles everything from scratch. " + regen(s),
                               removal: .holdingArea, regenerationWrites: s.logical))
        }
        let gradle = home + "/.gradle/caches"
        if isDir(gradle), overlaps(gradle) {
            let (s, last) = measure(gradle)
            out.append(Finding(category: .buildOutput, tier: .safe, title: "Gradle caches", paths: [gradle], owner: "Gradle", lastUsed: last,
                               sizes: s, what: "Downloaded dependencies and build caches for every Gradle project.",
                               why: "Gradle re-downloads and rebuilds what it needs.",
                               after: "The next Gradle build re-downloads its dependencies. " + regen(s),
                               removal: .holdingArea, regenerationWrites: s.logical))
        }
        return out
    }

    // MARK: - Simulators

    func simulators() -> [Finding] {
        let devices = home + "/Library/Developer/CoreSimulator/Devices"
        guard options.runTools, overlaps(devices), isDir(devices),
              let r = Shell.run(["xcrun", "simctl", "list", "-j", "devices"], timeout: 30), r.ok,
              let json = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return [] }
        var paths: [String] = [], names: [String] = []
        for (runtime, list) in byRuntime {
            for d in list where (d["isAvailable"] as? Bool) == false {
                guard let udid = d["udid"] as? String else { continue }
                let path = devices + "/" + udid
                guard isDir(path), overlaps(path) else { continue }
                paths.append(path)
                names.append("\(d["name"] as? String ?? udid) (\(runtime.split(separator: ".").last ?? ""))")
            }
        }
        guard !paths.isEmpty else { return [] }
        let s = paths.map { measure($0).sizes }.reduce(Sizes(), +)
        return [Finding(category: .simulators, tier: .safe, title: "\(paths.count) unavailable simulator\(paths.count == 1 ? "" : "s")",
                        paths: paths.sorted(), owner: "Simulator", ownerBundleID: "com.apple.iphonesimulator", sizes: s,
                        what: "Simulators whose runtime is gone: " + names.sorted().prefix(5).joined(separator: ", ") + (names.count > 5 ? ", …" : ""),
                        why: "They can't boot any more, so nothing can use them.",
                        after: "Nothing changes; Xcode never offered them.", removal: .ownerTool(.simctl))]
    }

    // MARK: - Package caches

    func packageCaches() -> [Finding] {
        let table: [(String, OwnerTool, String)] = [
            ("Library/Caches/Homebrew", .brew, "Homebrew's downloaded bottles and source archives."),
            (".npm/_cacache", .npm, "npm's content-addressed download cache."),
            ("Library/pnpm/store", .pnpm, "pnpm's global package store."),
            (".local/share/pnpm/store", .pnpm, "pnpm's global package store."),
            ("Library/Caches/Yarn", .yarn, "Yarn's package cache."),
            (".yarn/berry/cache", .yarn, "Yarn Berry's global package cache."),
            (".bun/install/cache", .bun, "Bun's package cache."),
            ("Library/Caches/pip", .pip, "pip's wheel and HTTP cache."),
            (".cache/uv", .uv, "uv's package and environment cache."),
            ("miniconda3/pkgs", .conda, "conda's package cache."),
            ("anaconda3/pkgs", .conda, "conda's package cache."),
            ("miniforge3/pkgs", .conda, "conda's package cache."),
            (".conda/pkgs", .conda, "conda's package cache."),
            ("Library/Caches/CocoaPods", .pods, "CocoaPods' pod cache."),
        ]
        var out: [Finding] = []
        for (rel, tool, what) in table {
            let path = home + "/" + rel
            guard isDir(path), overlaps(path) else { continue }
            let (s, last) = measure(path)
            out.append(Finding(category: .packageCaches, tier: .safe, title: "\(tool.name) cache", paths: [path], owner: tool.name,
                               lastUsed: last, sizes: s, what: what,
                               why: "A download cache: \(tool.name) fetches anything it needs again. \(tool.note)",
                               after: "Installs that need these packages download them again. " + regen(s),
                               removal: .ownerTool(tool), regenerationWrites: s.logical))
        }
        return out
    }

    // MARK: - Containers and VMs

    func containers() -> [Finding] {
        let candidates: [(String, String, String)] = [
            ("Library/Containers/com.docker.docker/Data/vms", "Docker Desktop", "Docker Desktop's Linux VM disk: images, containers, volumes and build cache."),
            (".orbstack", "OrbStack", "OrbStack's Linux machines and container data."),
            ("Library/Group Containers/HUAQ24HBR6.dev.orbstack", "OrbStack", "OrbStack's Linux machines and container data."),
            (".local/share/containers/podman/machine", "Podman", "Podman machine disk images."),
        ]
        var out: [Finding] = []
        for (rel, name, what) in candidates {
            let path = home + "/" + rel
            guard isDir(path), overlaps(path) else { continue }
            let (s, last) = measure(path)
            out.append(Finding(category: .containers, tier: .review, title: name, paths: [path], owner: name, lastUsed: last, sizes: s,
                               what: what + " The disk image is sparse: its logical size overstates what it uses.",
                               why: "Holds images and volumes that may be your only copy; prune from inside the tool so it can say what goes.",
                               after: "Removed images are pulled again when next needed; removed volumes are gone.",
                               removal: .ownerTool(.docker)))
        }
        return out
    }

    // MARK: - AI models

    func aiModels() -> [Finding] {
        var out: [Finding] = []
        let env = ProcessInfo.processInfo.environment
        let hub = env["HF_HUB_CACHE"] ?? (env["HF_HOME"].map { $0 + "/hub" } ?? home + "/.cache/huggingface/hub")
        for name in list(hub) where name.hasPrefix("models--") || name.hasPrefix("datasets--") {
            let path = hub + "/" + name
            guard isDir(path), overlaps(path) else { continue }
            let parts = name.components(separatedBy: "--")
            let model = parts.dropFirst().joined(separator: "/")
            let isMLX = model.lowercased().contains("mlx")
            let (s, last) = measure(path)
            out.append(Finding(category: .aiModels, tier: .review, title: (isMLX ? "MLX · " : "Hugging Face · ") + model, paths: [path],
                               owner: isMLX ? "MLX (Hugging Face cache)" : "Hugging Face", lastUsed: last, sizes: s,
                               what: "\(parts.first == "datasets" ? "Dataset" : "Model") \(model), cached by the Hugging Face hub library.",
                               why: "Re-downloadable, but large and possibly pinned to a revision you rely on. Last changed \(ago(last)).",
                               after: "Loading \(model) again re-downloads it (\(ByteSize.format(s.logical))).", removal: .holdingArea))
        }
        out += ollama()
        for root in [home + "/.lmstudio/models", home + "/.cache/lm-studio/models"] {
            for publisher in list(root) where isDir(root + "/" + publisher) {
                for model in list(root + "/" + publisher) where isDir(root + "/" + publisher + "/" + model) {
                    let path = root + "/" + publisher + "/" + model
                    guard overlaps(path) else { continue }
                    let (s, last) = measure(path)
                    out.append(Finding(category: .aiModels, tier: .review, title: "LM Studio · \(publisher)/\(model)", paths: [path],
                                       owner: "LM Studio", ownerBundleID: "ai.elementlabs.lmstudio", lastUsed: last, sizes: s,
                                       what: "Model \(publisher)/\(model), downloaded by LM Studio.",
                                       why: "Re-downloadable, but large. Last changed \(ago(last)).",
                                       after: "LM Studio re-downloads it (\(ByteSize.format(s.logical))) if you load it again.",
                                       removal: .holdingArea))
                }
            }
        }
        return out
    }

    /// One finding per Ollama model, sized by the blobs no other model shares.
    func ollama() -> [Finding] {
        let root = home + "/.ollama/models"
        let manifests = root + "/manifests"
        guard isDir(manifests), overlaps(root) else { return [] }
        var models: [(name: String, manifest: String, blobs: [String])] = []
        guard let walker = FileManager.default.enumerator(atPath: manifests) else { return [] }
        while let rel = walker.nextObject() as? String {
            let path = manifests + "/" + rel
            guard !isDir(path), let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var digests = ((json["layers"] as? [[String: Any]]) ?? []).compactMap { $0["digest"] as? String }
            if let c = (json["config"] as? [String: Any])?["digest"] as? String { digests.append(c) }
            let parts = rel.split(separator: "/")
            let name = parts.count >= 2 ? parts.suffix(2).joined(separator: ":") : rel
            let display = parts.count >= 3 && parts[parts.count - 3] != "library" ? parts[parts.count - 3] + "/" + name : name
            models.append((display, path, digests.map { root + "/blobs/" + $0.replacingOccurrences(of: ":", with: "-") }))
        }
        let useCount = Dictionary(models.flatMap(\.blobs).map { ($0, 1) }, uniquingKeysWith: +)
        return models.map { m in
            var s = Sizes()
            var newest: Date?
            for b in m.blobs {
                guard let e = Entry.stat(b) else { continue }
                s.logical += e.raw.logical
                s.onDisk += useCount[b, default: 1] > 1 ? 0 : e.raw.allocated
                s.reclaimable += useCount[b, default: 1] > 1 ? 0 : e.privateSize
                let changed = Date(timeIntervalSince1970: TimeInterval(e.raw.mtime))
                newest = max(newest ?? changed, changed)
            }
            return Finding(category: .aiModels, tier: .review, title: "Ollama · \(m.name)", paths: [m.manifest], owner: "Ollama",
                           lastUsed: newest, sizes: s, what: "Model \(m.name), pulled by Ollama.",
                           why: "Re-downloadable with `ollama pull`, but large.",
                           after: "Ollama will re-download this model (\(ByteSize.format(s.logical))) if you use it again.",
                           removal: .ownerTool(.ollamaRemove(m.name)))
        }
    }

    // MARK: - Stale projects

    func staleProjects() -> [Finding] {
        var out: [Finding] = []
        let deps = markers(named: ["node_modules"]).map { ($0, "npm") }
            + markers(named: [".venv", "venv"]).filter { exists($0 + "/pyvenv.cfg") }.map { ($0, "python") }
        var repoCache: [String: Date?] = [:]
        for (path, kind) in deps {
            guard let repo = repoRoot(containing: path) else { continue }
            let activity: Date?
            if let cached = repoCache[repo] { activity = cached } else { activity = lastActivity(repo: repo); repoCache[repo] = activity }
            guard let activity, options.now.timeIntervalSince(activity) >= options.staleProjectAge else { continue }
            let (s, _) = measure(path)
            let project = (repo as NSString).lastPathComponent
            let restore = kind == "npm" ? "`npm install` (or pnpm / yarn / bun install)" : "`uv sync` or `pip install -r requirements.txt`"
            out.append(Finding(category: .staleProjects, tier: .review,
                               title: "\(kind == "npm" ? "node_modules" : "virtualenv") · \(project)", paths: [path],
                               owner: kind == "npm" ? "npm" : "Python", lastUsed: activity, sizes: s,
                               what: kind == "npm" ? "Installed JavaScript dependencies for \(project)." : "A Python virtual environment for \(project).",
                               why: "No commit or edited file in \(project) for \(ago(activity).replacingOccurrences(of: " ago", with: "")); reinstallable from the lockfile.",
                               after: "Run \(restore) in \(project) before working on it again.", removal: .holdingArea,
                               regenerationWrites: s.logical))
        }
        return out
    }

    /// The nearest folder above `path` (up to the home folder) holding a `.git` entry.
    func repoRoot(containing path: String) -> String? {
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count >= home.count && dir != "/" {
            if exists(dir + "/.git") { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The later of the last commit (the HEAD reflog, else `git log`) and the newest file outside
    /// dependency folders and `.git`.
    func lastActivity(repo: String) -> Date? {
        var latest: Date? = lastCommit(repo: repo)
        if let t = tree, let n = t.node(at: repo) {
            var dates = [t.ownLastModified(of: n)]
            for c in t.children(of: n) where !FindingsEngine.markerNames.contains(t.name(of: c)) && t.name(of: c) != ".git" {
                dates.append(t.lastModified(of: c))
            }
            for d in dates.compactMap({ $0 }) { latest = max(latest ?? d, d) }
        }
        return latest
    }

    func lastCommit(repo: String) -> Date? {
        var gitDir = repo + "/.git"
        if !isDir(gitDir), let text = try? String(contentsOfFile: gitDir, encoding: .utf8), text.hasPrefix("gitdir:") {
            let p = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = p.hasPrefix("/") ? p : repo + "/" + p
        }
        // Reflog lines end "<name> <email> <unix-time> <tz>\t<message>"; no process needed.
        if let log = try? String(contentsOfFile: gitDir + "/logs/HEAD", encoding: .utf8),
           let line = log.split(separator: "\n").last,
           let head = line.split(separator: "\t").first {
            let fields = head.split(separator: " ")
            if fields.count >= 2, let t = TimeInterval(fields[fields.count - 2]) { return Date(timeIntervalSince1970: t) }
        }
        guard options.runTools, let r = Shell.run(["git", "-C", repo, "log", "-1", "--format=%ct"], timeout: 10), r.ok,
              let t = TimeInterval(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    // MARK: - App leftovers

    func appLeftovers() -> [Finding] {
        var groups: [String: (id: String, paths: [String])] = [:]
        for loc in AppInventory.leftoverLocations {
            let dir = home + "/" + loc
            for name in list(dir) {
                guard let id = AppInventory.bundleID(fromEntryName: name), !AppInventory.isApple(id) else { continue }
                let path = dir + "/" + name
                guard overlaps(path) else { continue }
                groups[id.lowercased(), default: (id, [])].paths.append(path)
            }
        }
        guard !groups.isEmpty else { return [] }
        let inventory = options.inventory ?? AppInventory.discover(home: home)
        // Each id is judged on its own; an app's extensions (com.x.app.widget, …) then share one finding.
        var families: [String: (ids: [String], paths: [String], sizes: Sizes, newest: Date?)] = [:]
        for (_, g) in groups.sorted(by: { $0.key < $1.key }) {
            guard inventory.claim(g.id) == nil else { continue }
            var s = Sizes()
            var newest: Date?
            for p in g.paths {
                let m = measure(p)
                s += m.sizes
                if let n = m.newest { newest = max(newest ?? n, n) }
            }
            // Something wrote here recently, so something still uses it.
            if let newest, options.now.timeIntervalSince(newest) < options.leftoverQuietPeriod { continue }
            let family = g.id.lowercased().split(separator: ".").prefix(3).joined(separator: ".")
            var f = families[family] ?? ([], [], Sizes(), nil)
            f.ids.append(g.id)
            f.paths += g.paths
            f.sizes += s
            if let n = newest { f.newest = max(f.newest ?? n, n) }
            families[family] = f
        }
        let days = Int(options.leftoverQuietPeriod / 86_400)
        return families.sorted(by: { $0.key < $1.key }).map { _, f in
            let id = f.ids.min(by: { $0.count < $1.count }) ?? f.ids[0]
            let more = f.ids.count > 1 ? " and \(f.ids.count - 1) extension\(f.ids.count == 2 ? "" : "s")" : ""
            return Finding(category: .appLeftovers, tier: .review, title: "Leftovers · \(id)" + more, paths: f.paths.sorted(),
                           owner: "\(id) (not installed)", ownerBundleID: id, lastUsed: f.newest, sizes: f.sizes,
                           what: "Settings, caches and data left by \(f.ids.sorted().joined(separator: ", ")), no longer installed.",
                           why: "No installed app, helper or same-vendor app claims \(f.ids.count == 1 ? "this id" : "these ids"), neither LaunchServices nor Spotlight knows an app with \(f.ids.count == 1 ? "it" : "them"), and nothing has written here in \(days)+ days (last: \(ago(f.newest))).",
                           after: "If you reinstall the app, it starts fresh — its settings and local data are gone.",
                           removal: .holdingArea)
        }
    }

    // MARK: - Downloads

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "zip", "xip", "iso"]

    func downloads() -> [Finding] {
        let dir = home + "/Downloads"
        var out: [Finding] = []
        for name in list(dir) where FindingsEngine.installerExtensions.contains((name as NSString).pathExtension.lowercased()) {
            let path = dir + "/" + name
            guard overlaps(path) else { continue }
            let added = Spotlight.date(path, kMDItemDateAdded) ?? Entry.stat(path).map { Date(timeIntervalSince1970: TimeInterval($0.raw.mtime)) }
            guard let added, options.now.timeIntervalSince(added) >= options.downloadsAge else { continue }
            let (s, _) = measure(path)
            let kind = (name as NSString).pathExtension.lowercased() == "zip" ? "archive" : "installer"
            out.append(Finding(category: .downloads, tier: .review, title: name, paths: [path], owner: "Downloads", lastUsed: added, sizes: s,
                               what: "A downloaded \(kind), added \(ago(added)).",
                               why: "Installers and archives are usually done with once opened; you may still want this one.",
                               after: "Gone from Downloads; recoverable from the Trash until you empty it.", removal: .trash))
        }
        return out
    }

    // MARK: - Duplicates, large & old

    /// Personal files only: app data in Library and dot-folders is the owning app's business.
    func personal(_ path: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return true }
        let rel = path.dropFirst(home.count + 1)
        return !rel.hasPrefix("Library/") && !rel.split(separator: "/").contains { $0.hasPrefix(".") }
            && !nested(path) && Protection.reason(path, home: home) == nil
    }

    func duplicates() -> [Finding] {
        guard options.findDuplicates, let t = tree else { return [] }
        let candidates = t.files.filter { $0.logical >= options.duplicateMinSize && personal($0.path) && overlaps($0.path) }
        return Duplicates.find(candidates, minSize: options.duplicateMinSize).map { g in
            let name = (g.keep.path as NSString).lastPathComponent
            let logical = g.copies.reduce(0) { $0 + $1.logical }
            return Finding(category: .duplicates, tier: .review, title: "\(g.copies.count + 1)× \(name)", paths: [g.keep.path] + g.copies.map(\.path),
                           lastUsed: g.copies.map(\.modified).max(), sizes: Sizes(logical: logical, onDisk: g.reclaimable, reclaimable: g.reclaimable),
                           what: "Identical contents (SHA-256) at \(g.copies.count + 1) paths; the first is kept.",
                           why: "Each copy holds its own blocks. Replacing copies with APFS clones frees them and keeps every path.",
                           after: "Every path still opens the same file; editing one no longer changes the others' disk usage until it diverges.",
                           removal: .cloneReplace)
        }
    }

    func largeOld(excluding covered: [String]) -> [Finding] {
        guard let t = tree else { return [] }
        let coveredSet = covered
        return t.files.filter { f in
            f.logical >= options.largeFileSize && personal(f.path) && overlaps(f.path)
                && !coveredSet.contains { f.path == $0 || f.path.hasPrefix($0 + "/") }
        }.compactMap { f in
            let used = Spotlight.date(f.path, kMDItemLastUsedDate) ?? max(f.accessed, f.modified)
            guard options.now.timeIntervalSince(used) >= options.largeFileAge else { return nil }
            let s = Sizes(logical: f.logical, onDisk: f.allocated, reclaimable: f.linkCount > 1 ? 0 : f.privateSize)
            return Finding(category: .largeOld, tier: .review, title: (f.path as NSString).lastPathComponent, paths: [f.path], lastUsed: used,
                           sizes: s, what: "A \(ByteSize.format(f.logical)) file, last opened \(ago(used)).",
                           why: "Big and unused for a long time — but only you know whether it matters.",
                           after: "Gone from its folder; recoverable from the Trash until you empty it.", removal: .trash)
        }
    }

    // MARK: - Snapshots and system

    var scopeIsWide: Bool { scope == home || scope == "/" || scope == "/System/Volumes/Data" }

    func snapshots() -> [Finding] {
        guard options.runTools, scopeIsWide, let r = Shell.run(["tmutil", "listlocalsnapshots", "/"], timeout: 20), r.ok else { return [] }
        let names = r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("com.apple.") }
        guard !names.isEmpty else { return [] }
        return [Finding(category: .snapshots, tier: .review, title: "\(names.count) local Time Machine snapshot\(names.count == 1 ? "" : "s")",
                        paths: names, owner: "Time Machine", ownerBundleID: "com.apple.backup.launcher", sizes: Sizes(),
                        what: "Point-in-time copies of the startup volume: " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : ""),
                        why: "They hold blocks of files you've since deleted or changed. macOS doesn't report how much each holds without admin rights, so the size is unknown.",
                        after: "Space the snapshots alone held comes back; restoring to those points in time is no longer possible.",
                        removal: .ownerTool(OwnerTool(name: "Time Machine", command: ["tmutil", "deletelocalsnapshots", "/"],
                                                      note: "Deletes every local snapshot of the startup volume.")))]
    }

    func system() -> [Finding] {
        var out: [Finding] = []
        if scopeIsWide {
            let vm = "/private/var/vm"
            var s = Sizes()
            for name in list(vm) {
                guard let e = Entry.stat(vm + "/" + name) else { continue }
                s += Sizes(logical: e.raw.logical, onDisk: e.raw.allocated, reclaimable: 0)
            }
            if s.logical > 0 {
                out.append(Finding(category: .system, tier: .protected, title: "Swap and sleep image", paths: [vm], owner: "macOS", sizes: s,
                                   what: "Memory macOS paged out to the SSD, plus the sleep image.",
                                   why: "Managed by the kernel; it shrinks on its own when memory pressure drops.",
                                   after: "Never removed by scalpel.", removal: .never))
            }
        }
        let icloud = home + "/Library/Mobile Documents"
        if isDir(icloud), overlaps(icloud), let t = tree, let n = t.node(at: icloud) {
            out.append(Finding(category: .system, tier: .protected, title: "iCloud Drive", paths: [icloud], owner: "iCloud",
                               sizes: Sizes(logical: t.sizes(of: n).logical, onDisk: t.sizes(of: n).onDisk, reclaimable: 0),
                               what: "Your iCloud Drive files (downloaded copies take space; cloud-only ones don't).",
                               why: "Deleting here deletes everywhere. Use Finder's Remove Download to free local space instead.",
                               after: "Never removed by scalpel.", removal: .never))
        }
        return out
    }
}

/// Spotlight metadata, the only record of when a file was last *opened* (atime is updated lazily).
public enum Spotlight {
    public static func date(_ path: String, _ key: CFString) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, key) as? Date
    }
}
