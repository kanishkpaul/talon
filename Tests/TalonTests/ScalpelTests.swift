import Darwin
import Foundation
import Testing
import TalonPrivate
@testable import TalonScalpel

/// A canonical (realpath'd) temp folder, removed when the test ends.
final class Sandbox {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("talon-scalpel-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = realPath(base) ?? base
    }

    deinit {
        // Make anything a test locked down removable again.
        if let e = FileManager.default.enumerator(atPath: root) {
            while let rel = e.nextObject() as? String { chmod(root + "/" + rel, 0o755); chflags(root + "/" + rel, 0) }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ rel: String) -> String { root + "/" + rel }

    @discardableResult
    func dir(_ rel: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path(rel), withIntermediateDirectories: true)
        return path(rel)
    }

    /// Random bytes (incompressible, never sparse), flushed so the blocks are allocated now.
    @discardableResult
    func file(_ rel: String, bytes: Int, seed: UInt8 = 0) throws -> String {
        let p = path(rel)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buf in
            var x: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(seed)
            for i in 0..<buf.count { x ^= x << 13; x ^= x >> 7; x ^= x << 17; buf[i] = UInt8(truncatingIfNeeded: x) }
        }
        FileManager.default.createFile(atPath: p, contents: nil)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: p))
        try h.write(contentsOf: data)
        try h.synchronize()
        try h.close()
        return p
    }

    func age(_ rel: String, days: Double) throws {
        let d = Date().addingTimeInterval(-days * 86_400)
        try FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: path(rel))
    }
}

private let MB = 1 << 20
/// Slack for metadata blocks and allocation rounding.
private let slack: UInt64 = 64 << 10

private func scan(_ root: String, record: UInt64? = nil, markers: Set<String> = []) throws -> ScanTree {
    try DiskScanner(options: .init(workers: 3, recordFilesAtLeast: record, markerNames: markers)).scan(root)
}

// MARK: - DiskScanner: the APFS traps

@Suite struct ScalpelScannerTests {
    @Test func clonesAreCountedOnce() throws {
        let s = try Sandbox()
        let a = try s.file("one/a.bin", bytes: 4 * MB)
        try s.dir("two")
        #expect(clonefile(a, s.path("two/b.bin"), 0) == 0)
        sync()

        let ea = try #require(Entry.stat(a)), eb = try #require(Entry.stat(s.path("two/b.bin")))
        #expect(ea.cloneRefCount == 2 && eb.cloneRefCount == 2)   // the refcount includes the file itself
        #expect(ea.cloneID == eb.cloneID)
        #expect(ea.privateSize < slack && eb.privateSize < slack)
        #expect(eb.sharesAllBlocks)

        let t = try scan(s.root)
        let one = try #require(t.sizes(at: s.path("one")))
        #expect(one.reclaimable < slack)                        // deleting one copy frees ~nothing
        #expect(t.totals.reclaimable >= UInt64(4 * MB) && t.totals.reclaimable < UInt64(4 * MB) + slack)  // both: everything
        #expect(t.totals.logical == UInt64(8 * MB))             // Finder's number double-counts
        #expect(t.totals.onDisk >= UInt64(4 * MB) && t.totals.onDisk < UInt64(4 * MB) + slack)
        #expect(t.stats.cloneGroups == 1)

        // Scanning one copy alone: the shared blocks are on disk, but not reclaimable.
        let only = try scan(s.path("one"))
        #expect(only.totals.onDisk >= UInt64(4 * MB))
        #expect(only.totals.reclaimable < slack)
    }

    @Test func hardLinksAreCountedOnce() throws {
        let s = try Sandbox()
        let h = try s.file("one/h.bin", bytes: 4 * MB)
        try s.dir("two")
        #expect(link(h, s.path("two/h2.bin")) == 0)

        // APFS: the inode (FILEID) is shared, LINKID is per name, and PRIVATESIZE claims the full size on each name.
        let e1 = try #require(Entry.stat(h)), e2 = try #require(Entry.stat(s.path("two/h2.bin")))
        #expect(e1.raw.file_id == e2.raw.file_id)
        #expect(e1.raw.link_id != e2.raw.link_id)
        #expect(e1.raw.link_count == 2)

        let t = try scan(s.root)
        #expect(t.totals.logical == UInt64(4 * MB))
        #expect(t.totals.onDisk >= UInt64(4 * MB) && t.totals.onDisk < UInt64(4 * MB) + slack)
        #expect(t.totals.reclaimable >= UInt64(4 * MB) && t.totals.reclaimable < UInt64(4 * MB) + slack)
        #expect(try #require(t.sizes(at: s.path("one"))).reclaimable == 0)
        #expect(t.stats.hardLinkGroups == 1)

        let only = try scan(s.path("one"))
        #expect(only.totals.reclaimable == 0)   // the other name keeps the blocks alive
    }

    @Test func symlinksAreNeverFollowed() throws {
        let s = try Sandbox()
        try s.file("outside/big.bin", bytes: 4 * MB)
        try s.dir("root/sub")
        try FileManager.default.createSymbolicLink(atPath: s.path("root/to-dir"), withDestinationPath: s.path("outside"))
        try FileManager.default.createSymbolicLink(atPath: s.path("root/sub/to-file"), withDestinationPath: s.path("outside/big.bin"))
        let t = try scan(s.path("root"))
        #expect(t.totals.logical < 4096)
        #expect(t.stats.symlinks == 2)
        #expect(t.node(at: s.path("root/to-dir")) == nil)
    }

    @Test func unreadableFoldersAreListed() throws {
        let s = try Sandbox()
        try s.file("root/locked/secret.bin", bytes: 1024)
        try s.file("root/open/fine.bin", bytes: 1024)
        chmod(s.path("root/locked"), 0)
        defer { chmod(s.path("root/locked"), 0o755) }
        let t = try scan(s.path("root"))
        #expect(t.stats.unreadable.map(\.path) == [s.path("root/locked")])
        #expect(t.stats.unreadable.first?.errno == EACCES)
        #expect(t.stats.files == 1)
    }

    @Test func recordsLargeFilesMarkersAndProgress() async throws {
        let s = try Sandbox()
        try s.file("a/big.bin", bytes: 2 * MB)
        try s.file("a/small.bin", bytes: 10)
        try s.file("proj/node_modules/x/index.js", bytes: 10)
        let t = try await DiskScanner(options: .init(workers: 2, recordFilesAtLeast: UInt64(MB), markerNames: ["node_modules"])).scan(s.root)
        #expect(t.files.map(\.path) == [s.path("a/big.bin")])
        #expect(t.markers.compactMap { $0.node.map(t.path(of:)) } == [s.path("proj/node_modules")])
        #expect(t.stats.files == 3 && t.stats.directories == 4)
    }

    @Test func cancels() throws {
        let s = try Sandbox()
        for i in 0..<50 { try s.file("d\(i)/f", bytes: 10) }
        #expect(throws: CancellationError.self) { try DiskScanner().scan(s.root, isCancelled: { true }) }
    }

    @Test func dataVolumeStandsInForSlash() {
        #expect(DiskScanner.canonicalRoot("/") == "/System/Volumes/Data")
    }
}

// MARK: - Holding area and cut checks

@Suite struct ScalpelHoldingTests {
    func area(_ s: Sandbox) throws -> HoldingArea {
        let home = try s.dir("home")
        var g = CutGuard(allowedRoots: [home], home: home)
        g.checkRunningApps = false
        return HoldingArea(root: s.path("holding"), guardrails: g)
    }

    @Test func cutRestorePurgeRoundTrip() throws {
        let s = try Sandbox()
        let h = try area(s)
        try s.file("home/cache/a.bin", bytes: 64 << 10)
        try s.file("home/cache/sub/b.bin", bytes: 10)

        let m = try h.cut([.init(path: s.path("home/cache"))], category: .buildOutput, title: "test")
        #expect(!FileManager.default.fileExists(atPath: s.path("home/cache")))
        #expect(m.items.count == 1 && m.items[0].originalPath == s.path("home/cache"))
        #expect(m.items[0].sizes.logical == UInt64(64 << 10) + 10)
        #expect(FileManager.default.fileExists(atPath: s.path("holding/\(m.id)/manifest.json")))
        #expect(h.list().map(\.id) == [m.id])

        let restored = try h.restore(String(m.id.prefix(12)))
        #expect(restored == [s.path("home/cache")])
        #expect(FileManager.default.fileExists(atPath: s.path("home/cache/sub/b.bin")))
        #expect(h.list().isEmpty)

        let m2 = try h.cut([.init(path: s.path("home/cache"))])
        #expect(try h.purge(olderThan: 7 * 86_400).isEmpty)                                        // still within the hold
        #expect(try h.purge(olderThan: 7 * 86_400, now: Date().addingTimeInterval(8 * 86_400)).map(\.id) == [m2.id])
        #expect(!FileManager.default.fileExists(atPath: s.path("holding/\(m2.id)")))
        #expect(!FileManager.default.fileExists(atPath: s.path("home/cache")))

        let m3 = try h.cut([.init(path: try s.file("home/other.bin", bytes: 10))])
        #expect(try h.purge(m3.id).id == m3.id)
        #expect(h.list().isEmpty)
    }

    @Test func restoreNeverOverwrites() throws {
        let s = try Sandbox()
        let h = try area(s)
        try s.file("home/thing/a.bin", bytes: 10)
        let m = try h.cut([.init(path: s.path("home/thing"))])
        try s.file("home/thing/new.bin", bytes: 20)
        #expect(throws: Refusal.self) { try h.restore(m.id) }
        #expect(FileManager.default.fileExists(atPath: s.path("holding/\(m.id)/items/0-thing/a.bin")))
        #expect(!FileManager.default.fileExists(atPath: s.path("home/thing/a.bin")))
    }

    @Test func refusesOutsideRootsOutwardSymlinksProtectedAndOpenFiles() throws {
        let s = try Sandbox()
        let h = try area(s)
        let outside = try s.file("elsewhere/x.bin", bytes: 10)
        #expect(throws: Refusal.self) { try h.cut([.init(path: outside)]) }
        #expect(throws: Refusal.self) { try h.cut([.init(path: s.path("home"))]) }   // the root itself
        #expect(throws: Refusal.self) { try h.cut([.init(path: s.path("home/../elsewhere/x.bin"))]) }

        try FileManager.default.createSymbolicLink(atPath: s.path("home/escape"), withDestinationPath: s.path("elsewhere"))
        #expect(throws: Refusal.self) { try h.cut([.init(path: s.path("home/escape"))]) }
        #expect(throws: Refusal.self) { try h.cut([.init(path: s.path("home/escape/x.bin"))]) }   // via a symlinked parent

        try s.file("home/.ssh/id", bytes: 10)
        #expect(throws: Refusal.self) { try h.cut([.init(path: s.path("home/.ssh"))]) }
        try s.file("home/fine/a", bytes: 10)
        #expect(throws: Refusal.self) { try h.cut([.init(path: s.path("home/fine"), tier: .protected)]) }

        let busy = try s.file("home/busy/open.bin", bytes: 10)
        let handle = try #require(FileHandle(forReadingAtPath: busy))
        do {
            try h.cut([.init(path: s.path("home/busy"))])
            Issue.record("cut a folder with an open file")
        } catch let r as Refusal {
            #expect(r.reason.contains("in use"))
        }
        try handle.close()
        #expect(throws: Never.self) { try h.cut([.init(path: s.path("home/busy"))]) }
        #expect(FileManager.default.fileExists(atPath: outside))
    }

    @Test func cleanerHoldsAndRefuses() throws {
        let s = try Sandbox()
        let h = try area(s)
        let p = try s.dir("home/dd/Proj-abc")
        try s.file("home/dd/Proj-abc/x.o", bytes: 10)
        let safe = Finding(category: .buildOutput, tier: .safe, title: "t", paths: [p], sizes: Sizes(logical: 10), what: "", why: "",
                           after: "", removal: .holdingArea)
        guard case .held(let m) = Cleaner(holding: h).apply(safe).outcome else { Issue.record("not held"); return }
        #expect(m.findingID == safe.id && m.category == .buildOutput)
        var prot = safe
        prot.tier = .protected
        guard case .refused = Cleaner(holding: h).apply(prot).outcome else { Issue.record("protected was cleaned"); return }
        let tool = Finding(category: .packageCaches, tier: .safe, title: "t", paths: [p], sizes: Sizes(), what: "", why: "", after: "",
                           removal: .ownerTool(.brew))
        guard case .skipped = Cleaner(holding: h).apply(tool).outcome else { Issue.record("ran an owner tool unasked"); return }
    }

    @Test func protection() {
        let home = "/Users/someone"
        #expect(Protection.reason("/System/Library/Kernels", home: home) != nil)
        #expect(Protection.reason("/private/var/vm/swapfile0", home: home) != nil)
        #expect(Protection.reason("/Users/other/Documents", home: home) != nil)
        #expect(Protection.reason(home, home: home) != nil)
        #expect(Protection.reason(home + "/Library/Keychains/login.keychain-db", home: home) != nil)
        #expect(Protection.reason(home + "/Library/Containers/com.apple.Safari", home: home) != nil)
        #expect(Protection.reason(home + "/Pictures/Photos Library.photoslibrary", home: home) != nil)
        #expect(Protection.reason(home + "/Library/Developer/Xcode/DerivedData", home: home) == nil)
    }
}

// MARK: - Duplicates and clone-replace

@Suite struct ScalpelDedupeTests {
    @Test func duplicatesExcludeClones() throws {
        let s = try Sandbox()
        let a = try s.file("a.bin", bytes: 256 << 10, seed: 1)
        try s.file("b.bin", bytes: 256 << 10, seed: 1)   // same bytes, written separately: a real copy
        #expect(clonefile(a, s.path("c.bin"), 0) == 0)
        try s.file("d.bin", bytes: 256 << 10, seed: 2)   // same size, different bytes
        sync()

        let groups = Duplicates.find(try scan(s.root, record: 1).files)
        #expect(groups.count == 1)
        let g = try #require(groups.first)
        #expect(g.copies.count == 1)   // a and c are one file on disk
        #expect(Set([g.keep.path] + g.copies.map(\.path)).contains(s.path("b.bin")))
        #expect(g.reclaimable >= UInt64(256 << 10))

        // Only clones left: nothing to free, so no group.
        try FileManager.default.removeItem(atPath: s.path("b.bin"))
        #expect(Duplicates.find(try scan(s.root, record: 1).files).isEmpty)
    }

    @Test func cloneReplacePreservesTheDuplicatesMetadata() throws {
        let s = try Sandbox()
        let o = try s.file("original.bin", bytes: 512 << 10, seed: 7)
        let d = try s.file("dir/copy.bin", bytes: 512 << 10, seed: 7)
        #expect(setxattr(o, "com.talon.original", "o", 1, 0, 0) == 0)
        #expect(setxattr(d, "com.talon.tag", "hello", 5, 0, 0) == 0)
        #expect(chmod(d, 0o640) == 0)
        let birth = Date(timeIntervalSince1970: 1_500_000_000), modified = Date(timeIntervalSince1970: 1_600_000_000.25)
        try FileManager.default.setAttributes([.creationDate: birth, .modificationDate: modified], ofItemAtPath: d)
        var before = stat()
        lstat(d, &before)
        // macOS adds its own (com.apple.provenance) to files this process creates; compare like for like.
        let dupNames = Duplicates.xattrNames(d), origNames = Duplicates.xattrNames(o)
        #expect(dupNames.contains("com.talon.tag") && !dupNames.contains("com.talon.original"))

        #expect(talon_set_added_time(d, 1_400_000_000, 0) == 0)
        var addedBefore: Int64 = 0, ns: Int64 = 0
        #expect(talon_get_added_time(d, &addedBefore, &ns) == 0)

        let freed = try Duplicates.replaceWithClone(original: o, duplicate: d)
        var addedAfter: Int64 = 0
        #expect(talon_get_added_time(d, &addedAfter, &ns) == 0 && addedAfter == addedBefore && addedBefore == 1_400_000_000)
        #expect(freed >= UInt64(512 << 10))

        #expect(FileManager.default.contentsEqual(atPath: o, andPath: d))
        #expect(Duplicates.xattrNames(d) == dupNames)
        var buf = [UInt8](repeating: 0, count: 16)
        #expect(getxattr(d, "com.talon.tag", &buf, 16, 0, 0) == 5 && String(decoding: buf.prefix(5), as: UTF8.self) == "hello")
        var after = stat()
        lstat(d, &after)
        #expect(after.st_mode & 0o7777 == 0o640)
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
        #expect(after.st_birthtimespec.tv_sec == before.st_birthtimespec.tv_sec)
        #expect(after.st_atimespec.tv_sec == before.st_atimespec.tv_sec)
        #expect(Duplicates.xattrNames(o) == origNames)   // the original is untouched

        let eo = try #require(Entry.stat(o)), ed = try #require(Entry.stat(d))
        #expect(eo.cloneID == ed.cloneID && ed.cloneRefCount == 2)
        #expect(!listing(s.path("dir")).contains { $0.hasPrefix(".talon-clone") })
    }

    @Test func cloneReplaceRefusesDifferentContents() throws {
        let s = try Sandbox()
        let o = try s.file("o", bytes: 4096, seed: 1)
        let d = try s.file("d", bytes: 4096, seed: 2)
        #expect(throws: Duplicates.CloneError.self) { try Duplicates.replaceWithClone(original: o, duplicate: d) }
    }
}

private func listing(_ p: String) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? [] }

// MARK: - Findings on a fake home

@Suite struct ScalpelFindingsTests {
    func git(_ repo: String, _ args: [String], date: String) throws {
        let env = ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let base = ["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                    "-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main"]
        let r = try #require(Shell.run(base + args, environment: env))
        #expect(r.ok, "git \(args): \(r.stderr)")
    }

    func makeHome(_ s: Sandbox) throws -> String {
        let home = try s.dir("home")
        try s.file("home/Library/Developer/Xcode/DerivedData/MyApp-abcdefgh/Build/Products/app.o", bytes: 2 * MB)

        try s.file("home/code/oldproj/package.json", bytes: 100)
        try s.file("home/code/oldproj/node_modules/left-pad/index.js", bytes: 2 * MB)
        try git(s.path("home/code/oldproj"), ["init", "-q"], date: "2023-01-01T00:00:00")
        try git(s.path("home/code/oldproj"), ["add", "package.json"], date: "2023-01-01T00:00:00")
        try git(s.path("home/code/oldproj"), ["commit", "-q", "-m", "init"], date: "2023-01-01T00:00:00")
        try s.age("home/code/oldproj/package.json", days: 700)

        try s.file("home/code/newproj/package.json", bytes: 100)
        try s.file("home/code/newproj/node_modules/x/index.js", bytes: 2 * MB)
        try git(s.path("home/code/newproj"), ["init", "-q"], date: ISO8601DateFormatter().string(from: Date()))
        try git(s.path("home/code/newproj"), ["add", "package.json"], date: ISO8601DateFormatter().string(from: Date()))
        try git(s.path("home/code/newproj"), ["commit", "-q", "-m", "init"], date: ISO8601DateFormatter().string(from: Date()))

        try s.file("home/Library/Application Support/com.talontest.goneapp/data.bin", bytes: 2 * MB)
        try s.file("home/Library/Preferences/com.talontest.goneapp.plist", bytes: 200)
        try s.file("home/Library/Caches/org.talonfixture.installedapp/cache.bin", bytes: 2 * MB)
        try s.file("home/Library/Caches/org.talonfixture.installedapp.helper/cache.bin", bytes: 2 * MB)
        try s.file("home/Library/Caches/com.apple.Something/cache.bin", bytes: 2 * MB)
        try s.file("home/Library/Application Support/net.talonrecent.app/data.bin", bytes: 2 * MB)
        for f in ["Application Support/com.talontest.goneapp/data.bin", "Preferences/com.talontest.goneapp.plist",
                  "Caches/org.talonfixture.installedapp/cache.bin", "Caches/org.talonfixture.installedapp.helper/cache.bin",
                  "Caches/com.apple.Something/cache.bin"] {
            try s.age("home/Library/" + f, days: 400)
        }
        try s.file("home/Downloads/Installer.dmg", bytes: 2 * MB)
        try s.age("home/Downloads/Installer.dmg", days: 90)
        try s.file("home/Downloads/Fresh.dmg", bytes: 2 * MB)
        return home
    }

    func options() -> FindingsOptions {
        var o = FindingsOptions()
        o.runTools = false
        o.findDuplicates = false
        o.inventory = AppInventory(bundleIDs: ["org.talonfixture.installedapp"], launchServicesKnows: { _ in false })
        return o
    }

    @Test func classifiesAFakeHome() throws {
        let s = try Sandbox()
        let home = try makeHome(s)
        let o = options()
        let tree = try DiskScanner(options: FindingsEngine.scanOptions(o)).scan(home)
        let findings = FindingsEngine(home: home, tree: tree, options: o).run()
        let byCategory = Dictionary(grouping: findings, by: \.category)

        let dd = try #require(byCategory[.buildOutput]?.first)
        #expect(dd.tier == .safe && dd.removal == .holdingArea && dd.title.contains("MyApp"))
        #expect(dd.paths == [home + "/Library/Developer/Xcode/DerivedData/MyApp-abcdefgh"])
        #expect(dd.sizes.reclaimable >= UInt64(2 * MB))
        #expect(dd.regenerationWrites == UInt64(2 * MB) && dd.after.contains("SSD"))
        #expect(dd.ownerBundleID == "com.apple.dt.Xcode")

        let stale = byCategory[.staleProjects] ?? []
        #expect(stale.map(\.paths) == [[home + "/code/oldproj/node_modules"]])
        #expect(stale.first?.tier == .review)

        let leftovers = byCategory[.appLeftovers] ?? []
        #expect(leftovers.map(\.ownerBundleID) == ["com.talontest.goneapp"])
        #expect(leftovers.first?.paths == [home + "/Library/Application Support/com.talontest.goneapp",
                                           home + "/Library/Preferences/com.talontest.goneapp.plist"])

        #expect((byCategory[.downloads] ?? []).map(\.title) == ["Installer.dmg"])
        #expect((byCategory[.downloads] ?? []).first?.removal == .trash)
    }

    @Test func whyExplainsOnePath() throws {
        let s = try Sandbox()
        let home = try makeHome(s)
        let e = try Explanation.explain(home + "/Library/Developer/Xcode/DerivedData/MyApp-abcdefgh", home: home, options: options())
        #expect(e.exact?.category == .buildOutput)
        #expect(e.kind == "folder" && e.sizes.logical == UInt64(2 * MB))

        let inside = try Explanation.explain(home + "/Library/Developer/Xcode/DerivedData/MyApp-abcdefgh/Build", home: home, options: options())
        #expect(inside.findings.first?.category == .buildOutput)   // part of a finding

        let leftover = try Explanation.explain(home + "/Library/Caches/org.talonfixture.installedapp", home: home, options: options())
        #expect(leftover.findings.isEmpty && leftover.namedAfter == "org.talonfixture.installedapp")
    }

    @Test func leftoverMatcherIsConservative() {
        let inv = AppInventory(bundleIDs: ["com.vendor.editor", "org.example.App"], launchServicesKnows: { $0 == "net.known.app" })
        #expect(inv.claim("com.apple.Safari") != nil)
        #expect(inv.claim("com.vendor.editor") != nil)
        #expect(inv.claim("COM.VENDOR.EDITOR") != nil)
        #expect(inv.claim("com.vendor.editor.helper") != nil)   // a helper of an installed app
        #expect(inv.claim("com.vendor.other") != nil)           // same vendor: shared data is common
        #expect(inv.claim("net.known.app") != nil)              // LaunchServices
        #expect(inv.claim("io.gone.app") == nil)
        #expect(inv.claim("org.cups.PrintingPrefs") != nil)    // macOS printing, not under com.apple
        #expect(inv.claim("com.segment.storage.oai") != nil)   // an SDK inside another app

        #expect(AppInventory.bundleID(fromEntryName: "com.foo.bar.plist") == "com.foo.bar")
        #expect(AppInventory.bundleID(fromEntryName: "com.foo.bar.savedState") == "com.foo.bar")
        #expect(AppInventory.bundleID(fromEntryName: "Google") == nil)
        #expect(AppInventory.bundleID(fromEntryName: "org.example") == nil)
        #expect(AppInventory.bundleID(fromEntryName: "Some App 2.0.1") == nil)
        #expect(AppInventory.bundleID(fromEntryName: "1.2.3") == nil)
    }
}
