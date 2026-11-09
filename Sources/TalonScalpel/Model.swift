import Foundation

/// The three numbers scalpel shows for anything on disk. Only `reclaimable` drives decisions:
/// it's what deleting the item would actually give back, after clones, hard links and snapshots.
public struct Sizes: Codable, Sendable, Equatable, Hashable {
    /// What Finder shows: the sum of file lengths.
    public var logical: UInt64 = 0
    /// Blocks allocated, with shared clone blocks and hard links counted once.
    public var onDisk: UInt64 = 0
    /// Bytes freed if this were deleted: blocks no clone, hard link or snapshot outside it still holds.
    public var reclaimable: UInt64 = 0

    public init(logical: UInt64 = 0, onDisk: UInt64 = 0, reclaimable: UInt64 = 0) {
        self.logical = logical
        self.onDisk = onDisk
        self.reclaimable = reclaimable
    }

    public static func + (a: Sizes, b: Sizes) -> Sizes {
        Sizes(logical: a.logical &+ b.logical, onDisk: a.onDisk &+ b.onDisk, reclaimable: a.reclaimable &+ b.reclaimable)
    }
    public static func += (a: inout Sizes, b: Sizes) { a = a + b }
}

/// A folder in the map, sized by reclaimable bytes.
public struct FolderSummary: Codable, Sendable {
    public var path: String
    public var sizes: Sizes
    public var files: UInt64
    public var lastModified: Date?
    public var children: [FolderSummary]
}

/// A folder the scan couldn't open. Listed, never silently skipped, so totals are honest about gaps.
public struct UnreadablePath: Codable, Sendable, Hashable {
    public var path: String
    public var errno: Int32
    public var reason: String

    public init(path: String, errno: Int32) {
        self.path = path
        self.errno = errno
        reason = errno == EPERM ? "needs Full Disk Access" : String(cString: strerror(errno))
    }
}

/// A file the scan kept details for (large files, duplicate candidates).
public struct FileRecord: Codable, Sendable, Hashable {
    public var path: String
    public var logical: UInt64
    public var allocated: UInt64
    /// Bytes freed by deleting this file alone (`ATTR_CMNEXT_PRIVATESIZE`), or `allocated` where unsupported.
    public var privateSize: UInt64
    public var fileID: UInt64
    public var cloneID: UInt64?
    public var cloneRefCount: UInt32
    public var linkCount: UInt32
    public var sharesAllBlocks: Bool
    public var modified: Date
    public var accessed: Date
}

public struct ScanStats: Codable, Sendable {
    public var root: String
    public var startedAt: Date
    public var seconds: Double
    /// CPU time the scan's threads used (user + system), for the "invisible to the system" budget.
    public var cpuSeconds: Double
    public var files: UInt64
    public var directories: UInt64
    public var symlinks: UInt64
    public var cloneGroups: Int
    public var hardLinkGroups: Int
    /// Folders left out because they are another volume or a mount point.
    public var otherVolumes: [String]
    public var unreadable: [UnreadablePath]
}

public struct ScanProgress: Sendable {
    public var files: UInt64
    public var directories: UInt64
    public var logicalBytes: UInt64
    public var currentPath: String
}

// MARK: - Findings

public enum Tier: String, Codable, Sendable, CaseIterable, Comparable {
    /// Regenerates by itself and holds no unique data.
    case safe
    /// Probably unneeded, but it's the user's call.
    case review
    /// Shown for context; never cleaned.
    case protected

    public static func < (a: Tier, b: Tier) -> Bool { a.rank < b.rank }
    private var rank: Int { switch self { case .safe: 0; case .review: 1; case .protected: 2 } }
}

public enum FindingCategory: String, Codable, Sendable, CaseIterable {
    case buildOutput = "build-output"
    case simulators
    case packageCaches = "package-caches"
    case containers
    case aiModels = "ai-models"
    case staleProjects = "stale-projects"
    case appLeftovers = "app-leftovers"
    case downloads
    case duplicates
    case largeOld = "large-old"
    case snapshots
    case system
    case other

    public var label: String {
        switch self {
        case .buildOutput: "Developer build output"
        case .simulators: "Simulators"
        case .packageCaches: "Package caches"
        case .containers: "Containers and VMs"
        case .aiModels: "AI models"
        case .staleProjects: "Stale projects"
        case .appLeftovers: "App leftovers"
        case .downloads: "Downloads debris"
        case .duplicates: "Duplicates"
        case .largeOld: "Large & old files"
        case .snapshots: "Local snapshots"
        case .system: "System"
        case .other: "Other"
        }
    }
}

/// How a finding leaves the disk.
public enum Removal: Codable, Sendable, Equatable {
    /// Moved to `~/.talon/holding/` (same volume, instant), purged after the hold period.
    case holdingArea
    /// The owning tool cleans up after itself; scalpel only runs it when asked.
    case ownerTool(OwnerTool)
    /// Moved to the Trash.
    case trash
    /// Duplicates become APFS clones of one copy: both paths stay, the space comes back.
    case cloneReplace
    case never

    public var label: String {
        switch self {
        case .holdingArea: "holding area"
        case .ownerTool(let t): t.display
        case .trash: "trash"
        case .cloneReplace: "replace with clone"
        case .never: "never"
        }
    }
}

/// A cleanup command owned by the tool that made the data.
public struct OwnerTool: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var command: [String]
    public var note: String

    public init(name: String, command: [String], note: String) {
        self.name = name
        self.command = command
        self.note = note
    }

    public var display: String { command.joined(separator: " ") }
}

public struct Finding: Codable, Sendable, Identifiable {
    /// Stable across scans: category plus the first path.
    public var id: String
    public var category: FindingCategory
    public var tier: Tier
    public var title: String
    public var paths: [String]
    /// The app or tool that made it, when known (a name, plus a bundle id when there is one).
    public var owner: String?
    public var ownerBundleID: String?
    public var lastUsed: Date?
    public var sizes: Sizes
    /// One line: what it is.
    public var what: String
    /// Why it's in this tier.
    public var why: String
    /// What happens after it's gone.
    public var after: String
    public var removal: Removal
    /// Bytes the SSD will write again if this regenerates — the cost of clearing a cache that comes back.
    public var regenerationWrites: UInt64?

    public init(category: FindingCategory, tier: Tier, title: String, paths: [String], owner: String? = nil,
                ownerBundleID: String? = nil, lastUsed: Date? = nil, sizes: Sizes, what: String, why: String,
                after: String, removal: Removal, regenerationWrites: UInt64? = nil) {
        id = Finding.makeID(category, paths.first ?? title)
        self.category = category
        self.tier = tier
        self.title = title
        self.paths = paths
        self.owner = owner
        self.ownerBundleID = ownerBundleID
        self.lastUsed = lastUsed
        self.sizes = sizes
        self.what = what
        self.why = why
        self.after = after
        self.removal = removal
        self.regenerationWrites = regenerationWrites
    }

    /// FNV-1a — short, stable across runs (Swift's Hasher is seeded per process).
    static func makeID(_ category: FindingCategory, _ key: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in (category.rawValue + ":" + key).utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16).leftPad(16)
    }
}

/// What `talon scalpel scan --json` prints.
public struct ScanReport: Codable, Sendable {
    public var stats: ScanStats
    public var totals: Sizes
    public var folders: [FolderSummary]
    public var findings: [Finding]
    public var volume: VolumeSpace?

    public init(stats: ScanStats, totals: Sizes, folders: [FolderSummary], findings: [Finding], volume: VolumeSpace?) {
        self.stats = stats
        self.totals = totals
        self.folders = folders
        self.findings = findings
        self.volume = volume
    }
}

/// The container's real free space — not the "available incl. purgeable" estimate.
public struct VolumeSpace: Codable, Sendable {
    public var path: String
    public var total: UInt64
    public var free: UInt64
    /// What Finder calls available, which counts purgeable space macOS may or may not give back.
    public var availableIncludingPurgeable: UInt64?

    public static func of(_ path: String) -> VolumeSpace? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let block = UInt64(s.f_bsize)
        let important = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return VolumeSpace(path: path, total: UInt64(s.f_blocks) * block, free: UInt64(s.f_bavail) * block,
                           availableIncludingPurgeable: important.map { UInt64(max(0, $0)) })
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}
