import Foundation

/// The result of a scan: one node per folder (files are summed into their folder, except the ones
/// kept as `FileRecord`s), immutable once built.
public final class ScanTree: Sendable {
    public let root: String
    let nodes: [DirNode]
    /// Files at least `Options.recordFilesAtLeast` in size.
    public let files: [FileRecord]
    public let markers: [Marker]
    public let stats: ScanStats

    init(root: String, nodes: [DirNode], files: [FileRecord], markers: [Marker], stats: ScanStats) {
        self.root = root
        self.nodes = nodes
        self.files = files
        self.markers = markers
        self.stats = stats
    }

    public var totals: Sizes { nodes.first?.total ?? Sizes() }
    public var rootNode: Int32 { 0 }

    public func path(of node: Int32) -> String {
        var parts: [String] = []
        var i = node
        while i > 0 { parts.append(nodes[Int(i)].name); i = nodes[Int(i)].parent }
        guard !parts.isEmpty else { return root }
        return (root.hasSuffix("/") ? root : root + "/") + parts.reversed().joined(separator: "/")
    }

    public func sizes(of node: Int32) -> Sizes { nodes[Int(node)].total }
    public func fileCount(of node: Int32) -> UInt64 { nodes[Int(node)].files }
    public func parent(of node: Int32) -> Int32? { node > 0 ? nodes[Int(node)].parent : nil }
    public func name(of node: Int32) -> String { nodes[Int(node)].name }

    public func lastModified(of node: Int32) -> Date? {
        let t = nodes[Int(node)].newest
        return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
    }

    /// Newest file directly inside the folder (not its subfolders).
    public func ownLastModified(of node: Int32) -> Date? {
        let t = nodes[Int(node)].ownNewest
        return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
    }

    public func children(of node: Int32) -> [Int32] {
        var out: [Int32] = []
        var c = nodes[Int(node)].firstChild
        while c >= 0 { out.append(c); c = nodes[Int(c)].nextSibling }
        return out
    }

    public func child(of node: Int32, named name: String) -> Int32? {
        var c = nodes[Int(node)].firstChild
        while c >= 0 { if nodes[Int(c)].name == name { return c }; c = nodes[Int(c)].nextSibling }
        return nil
    }

    /// True when `path` is the root or inside it.
    public func contains(_ path: String) -> Bool { path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }

    /// The folder node at `path`, if the scan walked it.
    public func node(at path: String) -> Int32? {
        guard contains(path) else { return nil }
        var i: Int32 = 0
        for part in path.dropFirst(root.count).split(separator: "/") {
            guard let c = child(of: i, named: String(part)) else { return nil }
            i = c
        }
        return i
    }

    /// Sizes of a folder the scan walked.
    public func sizes(at path: String) -> Sizes? { node(at: path).map(sizes(of:)) }

    /// The map: the biggest folders under `node` by reclaimable bytes, `depth` levels deep.
    public func summary(of node: Int32 = 0, top: Int = 10, depth: Int = 2) -> [FolderSummary] {
        guard depth > 0 else { return [] }
        return children(of: node)
            .sorted { sizes(of: $0).reclaimable > sizes(of: $1).reclaimable }
            .prefix(top)
            .map { c in
                FolderSummary(path: path(of: c), sizes: sizes(of: c), files: fileCount(of: c), lastModified: lastModified(of: c),
                              children: summary(of: c, top: max(1, top / 3), depth: depth - 1))
            }
    }
}
