import Darwin
import Foundation

/// `talon scalpel why <path>`: everything scalpel knows about one path.
public struct Explanation: Codable, Sendable {
    public var path: String
    public var kind: String
    public var sizes: Sizes
    public var lastModified: Date?
    /// Why it's off-limits, when it is.
    public var protected: String?
    /// Findings that are this path, contain it, or sit inside it.
    public var findings: [Finding]
    /// The app the path is named after, when it's named after a bundle id.
    public var namedAfter: String?
    public var unreadable: [UnreadablePath]

    /// The finding that is exactly this path, if any.
    public var exact: Finding? { findings.first { $0.paths.contains(path) } }

    public static func explain(_ rawPath: String, home: String = NSHomeDirectory(), options: FindingsOptions = FindingsOptions()) throws -> Explanation {
        let path = Protection.canonical(rawPath)
        var st = stat()
        guard lstat(path, &st) == 0 else { throw Refusal(path, "doesn't exist") }
        let kind: String = switch st.st_mode & S_IFMT {
        case S_IFDIR: "folder"
        case S_IFLNK: "symlink → " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "?")
        case S_IFREG: "file"
        default: "other"
        }
        var o = options
        o.findDuplicates = false
        let h = realPath(home) ?? home
        if (st.st_mode & S_IFMT) == S_IFLNK {
            // A symlink is explained as itself; its target is never walked.
            let e = Entry.stat(path)
            let s = e.map { Sizes(logical: $0.raw.logical, onDisk: $0.raw.allocated, reclaimable: $0.privateSize) } ?? Sizes()
            return Explanation(path: path, kind: kind, sizes: s, lastModified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                               protected: Protection.reason(path, home: h), findings: [], namedAfter: nil, unreadable: [])
        }
        let tree = try DiskScanner(options: FindingsEngine.scanOptions(o)).scan(path)
        let findings = FindingsEngine(home: h, tree: tree, scope: tree.root, options: o).run()
        let named = path.split(separator: "/").reversed().lazy.compactMap { AppInventory.bundleID(fromEntryName: String($0)) }.first
        let modified = (st.st_mode & S_IFMT) == S_IFDIR ? tree.lastModified(of: 0) : Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        return Explanation(path: tree.root, kind: kind, sizes: tree.totals, lastModified: modified,
                           protected: Protection.reason(tree.root, home: h), findings: findings, namedAfter: named,
                           unreadable: tree.stats.unreadable)
    }
}
