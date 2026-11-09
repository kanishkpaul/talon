import Darwin
import Foundation
import TalonPrivate

/// Walks a tree with `getattrlistbulk(2)` — one syscall per directory batch — and sizes every folder
/// three ways (logical, on disk, reclaimable) with the APFS traps handled:
///
/// - **Clones** share blocks. Each file contributes `ATTR_CMNEXT_PRIVATESIZE`; a full-clone group
///   (same `CLONEID`, `CLONE_REFCNT` > 1, which counts the file itself) adds its shared blocks once, to
///   the smallest folder holding every member seen, and counts them as reclaimable only if every member
///   is inside the scan.
/// - **Hard links** share an inode. APFS gives each *name* its own `ATTR_CMNEXT_LINKID`, and reports the
///   full size as private on every name, so links are grouped by `ATTR_CMN_FILEID` (the inode) instead and
///   counted once, the same way as clone groups.
/// - **Firmlinks / other volumes**: `/` is walked as the Data volume; the scan never leaves the root's
///   device or descends into a mount point, and never follows a symlink.
/// - **Snapshots**: blocks a snapshot still holds aren't private, so they're never called reclaimable.
public struct DiskScanner: Sendable {
    public struct Options: Sendable {
        /// Directory reads in flight at once. Two is the knee on an M5 Air (spike 6.1b): one core of kernel
        /// time; four saves a quarter of the wall time for twice the CPU; eight only adds lock contention.
        public var workers = 2
        /// Keep a `FileRecord` for every file at least this large (large-file and duplicate findings).
        public var recordFilesAtLeast: UInt64?
        /// Note every entry with one of these names (`node_modules`, `.git`, …) for the findings detectors.
        public var markerNames: Set<String> = []
        /// Utility QoS and utility disk I/O priority, so a scan never competes with what you're doing.
        public var lowPriority = true
        public var progressInterval: TimeInterval = 0.2

        public init(workers: Int = 2, recordFilesAtLeast: UInt64? = nil, markerNames: Set<String> = [], lowPriority: Bool = true) {
            self.workers = max(1, workers)
            self.recordFilesAtLeast = recordFilesAtLeast
            self.markerNames = markerNames
            self.lowPriority = lowPriority
        }
    }

    public enum ScanError: Error, CustomStringConvertible {
        case cannotRead(String, Int32)
        public var description: String {
            switch self { case .cannotRead(let p, let e): "can't read \(p): \(String(cString: strerror(e)))" }
        }
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    /// `/` and the system volume show the same data as the Data volume through firmlinks; walk the real one.
    public static func canonicalRoot(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let real = realPath(expanded) ?? (expanded as NSString).standardizingPath
        return real == "/" ? "/System/Volumes/Data" : real
    }

    /// Synchronous scan on bounded utility-QoS threads. `isCancelled` is polled once per directory.
    public func scan(_ path: String, progress: (@Sendable (ScanProgress) -> Void)? = nil,
                     isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> ScanTree {
        let root = DiskScanner.canonicalRoot(path)
        let started = Date()
        let cpu0 = DiskScanner.processCPUSeconds()
        guard let rootEntry = Entry.stat(root) else { throw ScanError.cannotRead(root, errno == 0 ? ENOENT : errno) }

        let state = WalkState(root: root, rootDev: rootEntry.dev, options: options, progress: progress, isCancelled: isCancelled)
        if rootEntry.type == VDIR.rawValue {
            state.start()
            let done = DispatchSemaphore(value: 0)
            for _ in 0..<options.workers {
                let t = Thread {
                    if self.options.lowPriority { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_UTILITY) }
                    state.work()
                    done.signal()
                }
                t.qualityOfService = options.lowPriority ? .utility : .userInitiated
                t.stackSize = 1 << 20
                t.start()
            }
            for _ in 0..<options.workers { done.wait() }
            if state.cancelled { throw CancellationError() }
        } else {
            state.single(rootEntry)
        }
        return state.finish(started: started, cpuSeconds: DiskScanner.processCPUSeconds() - cpu0)
    }

    /// The same scan, off the calling task, cancelled with it.
    public func scan(_ path: String, progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanTree {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<ScanTree, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    c.resume(with: Result { try self.scan(path, progress: progress, isCancelled: { flag.isSet }) })
                }
            }
        } onCancel: { flag.set() }
    }

    /// Sizes for one file or folder: a full walk for a folder, one `getattrlist` for anything else.
    /// A symlink is sized as itself — `scan` would resolve it to its target.
    public func measure(_ path: String) throws -> Sizes {
        if let e = Entry.stat(path), e.type == VLNK.rawValue {
            return Sizes(logical: e.raw.logical, onDisk: e.raw.allocated, reclaimable: e.privateSize)
        }
        return try scan(path).totals
    }

    static func processCPUSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }
}

func realPath(_ path: String) -> String? {
    guard let p = realpath(path, nil) else { return nil }
    defer { free(p) }
    return String(cString: p)
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

// MARK: - Entries

/// One unpacked getattrlistbulk entry.
struct Entry {
    var name: String
    var raw: talon_dirent_t

    var type: UInt32 { raw.obj_type }
    var dev: Int32 { raw.dev }
    var has: UInt32 { raw.has }
    var sharesAllBlocks: Bool { raw.has & UInt32(TALON_HAS_EXTFLAGS) != 0 && raw.ext_flags & UInt64(EF_SHARES_ALL_BLOCKS) != 0 }
    var privateSize: UInt64 {
        raw.has & UInt32(TALON_HAS_PRIVATESIZE) != 0 ? min(raw.private_size, raw.allocated) : raw.allocated
    }
    var cloneRefCount: UInt32 { raw.has & UInt32(TALON_HAS_CLONEREFCNT) != 0 ? raw.clone_refcnt : 0 }
    var cloneID: UInt64? { raw.has & UInt32(TALON_HAS_CLONEID) != 0 ? raw.clone_id : nil }

    static func stat(_ path: String) -> Entry? {
        let size = 4096
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buf.deallocate() }
        var raw = talon_dirent_t()
        let rc = talon_stat_entry(path, buf, size, &raw)
        guard rc == 0 else { errno = rc; return nil }
        let name = raw.name_offset == UInt32.max ? (path as NSString).lastPathComponent
            : String(cString: buf.advanced(by: Int(raw.name_offset)).assumingMemoryBound(to: CChar.self))
        return Entry(name: name, raw: raw)
    }

    func record(path: String) -> FileRecord {
        FileRecord(path: path, logical: raw.logical, allocated: raw.allocated, privateSize: privateSize, fileID: raw.file_id,
                   cloneID: cloneID, cloneRefCount: cloneRefCount, linkCount: raw.link_count, sharesAllBlocks: sharesAllBlocks,
                   modified: Date(timeIntervalSince1970: TimeInterval(raw.mtime)),
                   accessed: Date(timeIntervalSince1970: TimeInterval(raw.atime)))
    }
}

// MARK: - The walk

struct DirNode {
    var name: String
    var parent: Int32
    var depth: Int32
    var firstChild: Int32 = -1
    var nextSibling: Int32 = -1
    /// Files directly inside (after rollup: the whole subtree).
    var files: UInt64 = 0
    var own = Sizes()
    var total = Sizes()
    /// Newest file modification time in the subtree (seconds since 1970). Folder mtimes don't count:
    /// creating `node_modules` shouldn't make a dormant project look active.
    var newest: Int64 = 0
    /// Newest file modification time directly inside, before rollup.
    var ownNewest: Int64 = 0
}

/// An entry the detectors asked about, by name.
public struct Marker: Sendable {
    public var name: String
    /// The folder the entry sits in.
    public var parent: Int32
    /// The entry's own node, when it is a folder.
    public var node: Int32?
}

private struct Group {
    var expected: UInt32   // clone refcount, or hard-link count
    var seen: UInt32 = 0
    var lca: Int32
    var logical: UInt64 = 0
    var shared: UInt64 = 0
}

/// Shared walk state. Every mutable field is touched only under `cond`.
private final class WalkState: @unchecked Sendable {
    let root: String
    let rootDev: Int32
    let options: DiskScanner.Options
    let progress: (@Sendable (ScanProgress) -> Void)?
    let isCancelled: @Sendable () -> Bool

    let cond = NSCondition()
    var queue: [(path: String, node: Int32)] = []
    var inFlight = 0
    var cancelled = false
    var nodes: [DirNode] = []
    var files: [FileRecord] = []
    var markers: [Marker] = []
    var clones: [UInt64: Group] = [:]
    var links: [UInt64: Group] = [:]
    var unreadable: [UnreadablePath] = []
    var otherVolumes: [String] = []
    var fileCount: UInt64 = 0
    var symlinkCount: UInt64 = 0
    var logicalSeen: UInt64 = 0
    var lastProgress = Date.distantPast

    init(root: String, rootDev: Int32, options: DiskScanner.Options, progress: (@Sendable (ScanProgress) -> Void)?,
         isCancelled: @escaping @Sendable () -> Bool) {
        self.root = root
        self.rootDev = rootDev
        self.options = options
        self.progress = progress
        self.isCancelled = isCancelled
    }

    func start() {
        nodes.append(DirNode(name: root, parent: -1, depth: 0))
        queue.append((root, 0))
    }

    /// The root is a file: a one-node tree holding just it.
    func single(_ e: Entry) {
        nodes.append(DirNode(name: (root as NSString).deletingLastPathComponent, parent: -1, depth: 0))
        var local = Local()
        account(e, path: root, into: &local, node: 0)
        merge(local, node: 0, subdirs: [])
    }

    /// Per-directory results, built without the lock and merged once.
    struct Local {
        var own = Sizes()
        var files: UInt64 = 0
        var symlinks: UInt64 = 0
        var newest: Int64 = 0
        var records: [FileRecord] = []
        var markers: [(name: String, isDir: Bool)] = []
        var clones: [(id: UInt64, refcnt: UInt32, shared: UInt64)] = []
        var links: [(id: UInt64, count: UInt32, logical: UInt64, allocated: UInt64)] = []
        var unreadable: [UnreadablePath] = []
        var otherVolumes: [String] = []
    }

    func work() {
        let size = 128 << 10
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        let capacity = size / 32
        let out = UnsafeMutablePointer<talon_dirent_t>.allocate(capacity: capacity)
        defer { buf.deallocate(); out.deallocate() }

        while true {
            cond.lock()
            while queue.isEmpty && inFlight > 0 && !cancelled { cond.wait() }
            if cancelled || queue.isEmpty { cond.broadcast(); cond.unlock(); return }
            let (path, node) = queue.removeLast()
            inFlight += 1
            cond.unlock()

            if isCancelled() {
                cond.lock(); cancelled = true; inFlight -= 1; cond.broadcast(); cond.unlock()
                return
            }
            var local = Local()
            var subdirs: [String] = []
            read(path, node: node, buf: buf, size: size, out: out, capacity: capacity, local: &local, subdirs: &subdirs)
            merge(local, node: node, subdirs: subdirs, parentPath: path)
        }
    }

    private func read(_ path: String, node: Int32, buf: UnsafeMutableRawPointer, size: Int,
                      out: UnsafeMutablePointer<talon_dirent_t>, capacity: Int, local: inout Local, subdirs: inout [String]) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            let e = errno
            if e != ENOENT && e != ENOTDIR { local.unreadable.append(UnreadablePath(path: path, errno: e)) }
            return
        }
        defer { close(fd) }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        while true {
            let n = talon_bulk_read(fd, buf, size, out, Int32(capacity))
            if n < 0 {
                if -n != ENOENT { local.unreadable.append(UnreadablePath(path: path, errno: -n)) }
                return
            }
            if n == 0 { return }
            for i in 0..<Int(n) {
                let raw = out[i]
                guard raw.name_offset != UInt32.max else { continue }
                let name = String(cString: buf.advanced(by: Int(raw.name_offset)).assumingMemoryBound(to: CChar.self))
                let e = Entry(name: name, raw: raw)
                if raw.error != 0 {
                    local.unreadable.append(UnreadablePath(path: prefix + name, errno: Int32(bitPattern: raw.error)))
                    continue
                }
                if options.markerNames.contains(name) { local.markers.append((name, raw.obj_type == VDIR.rawValue)) }
                if raw.obj_type == VDIR.rawValue {
                    if raw.dev != rootDev || raw.mount_status & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 {
                        local.otherVolumes.append(prefix + name)
                    } else {
                        subdirs.append(name)
                    }
                } else {
                    account(e, path: prefix + name, into: &local, node: node)
                }
            }
        }
    }

    /// File accounting. Symlinks are sized as themselves (a few bytes) and never followed.
    func account(_ e: Entry, path: @autoclosure () -> String, into local: inout Local, node: Int32) {
        let raw = e.raw
        local.newest = max(local.newest, raw.mtime)
        if raw.obj_type == VLNK.rawValue { local.symlinks += 1 } else { local.files += 1 }
        let isFile = raw.obj_type == VREG.rawValue
        if isFile, raw.link_count > 1, raw.has & UInt32(TALON_HAS_FILEID) != 0 {
            local.links.append((raw.file_id, raw.link_count, raw.logical, raw.allocated))
        } else if isFile, e.cloneRefCount > 1, let id = e.cloneID {
            let p = e.privateSize
            local.own += Sizes(logical: raw.logical, onDisk: p, reclaimable: p)
            local.clones.append((id, e.cloneRefCount, raw.allocated - p))
        } else {
            local.own += Sizes(logical: raw.logical, onDisk: raw.allocated, reclaimable: e.privateSize)
        }
        if isFile, let min = options.recordFilesAtLeast, raw.logical >= min { local.records.append(e.record(path: path())) }
    }

    private func merge(_ l: Local, node: Int32, subdirs: [String], parentPath: String = "") {
        cond.lock()
        defer { cond.unlock() }
        let n = Int(node)
        nodes[n].own += l.own
        nodes[n].files += l.files
        nodes[n].newest = max(nodes[n].newest, l.newest)
        fileCount += l.files
        symlinkCount += l.symlinks
        logicalSeen &+= l.own.logical
        files.append(contentsOf: l.records)
        unreadable.append(contentsOf: l.unreadable)
        otherVolumes.append(contentsOf: l.otherVolumes)
        for (id, refcnt, shared) in l.clones {
            var g = clones[id] ?? Group(expected: refcnt, lca: node)
            g.seen += 1
            g.expected = max(g.expected, refcnt)
            g.shared = max(g.shared, shared)
            g.lca = lca(g.lca, node)
            clones[id] = g
        }
        for (id, count, logical, allocated) in l.links {
            var g = links[id] ?? Group(expected: count, lca: node, logical: logical, shared: allocated)
            g.seen += 1
            g.lca = lca(g.lca, node)
            links[id] = g
        }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        var childIndex: [String: Int32] = [:]
        for name in subdirs {
            let idx = Int32(nodes.count)
            nodes.append(DirNode(name: name, parent: node, depth: nodes[n].depth + 1, nextSibling: nodes[n].firstChild))
            nodes[n].firstChild = idx
            queue.append((prefix + name, idx))
            childIndex[name] = idx
        }
        for m in l.markers { markers.append(Marker(name: m.name, parent: node, node: m.isDir ? childIndex[m.name] : nil)) }
        if !parentPath.isEmpty { inFlight -= 1 }
        cond.broadcast()

        if let progress, Date().timeIntervalSince(lastProgress) >= options.progressInterval {
            lastProgress = Date()
            let p = ScanProgress(files: fileCount, directories: UInt64(nodes.count), logicalBytes: logicalSeen, currentPath: parentPath)
            cond.unlock()
            progress(p)
            cond.lock()
        }
    }

    private func lca(_ a: Int32, _ b: Int32) -> Int32 {
        var a = a, b = b
        while nodes[Int(a)].depth > nodes[Int(b)].depth { a = nodes[Int(a)].parent }
        while nodes[Int(b)].depth > nodes[Int(a)].depth { b = nodes[Int(b)].parent }
        while a != b { a = nodes[Int(a)].parent; b = nodes[Int(b)].parent }
        return a
    }

    func finish(started: Date, cpuSeconds: Double) -> ScanTree {
        // Shared blocks belong to the smallest folder holding every member seen; reclaimable only
        // when every member is inside the scan.
        for g in clones.values {
            nodes[Int(g.lca)].own.onDisk += g.shared
            if g.seen >= g.expected { nodes[Int(g.lca)].own.reclaimable += g.shared }
        }
        for g in links.values {
            nodes[Int(g.lca)].own.logical += g.logical
            nodes[Int(g.lca)].own.onDisk += g.shared
            if g.seen >= g.expected { nodes[Int(g.lca)].own.reclaimable += g.shared }
        }
        for i in nodes.indices { nodes[i].total = nodes[i].own; nodes[i].ownNewest = nodes[i].newest }
        // Children always come after their parent, so one reverse pass rolls everything up.
        for i in nodes.indices.reversed() where nodes[i].parent >= 0 {
            let p = Int(nodes[i].parent)
            nodes[p].total += nodes[i].total
            nodes[p].files += nodes[i].files
            nodes[p].newest = max(nodes[p].newest, nodes[i].newest)
        }
        let stats = ScanStats(root: root, startedAt: started, seconds: Date().timeIntervalSince(started), cpuSeconds: cpuSeconds,
                              files: fileCount, directories: UInt64(max(0, nodes.count - 1)), symlinks: symlinkCount,
                              cloneGroups: clones.count, hardLinkGroups: links.count,
                              otherVolumes: otherVolumes.sorted(), unreadable: unreadable.sorted { $0.path < $1.path })
        return ScanTree(root: root, nodes: nodes, files: files, markers: markers, stats: stats)
    }
}
