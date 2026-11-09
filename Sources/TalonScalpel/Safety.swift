import Darwin
import Foundation
import TalonPrivate

/// Paths scalpel never cuts, whatever the user selects: the system, other people's data, and the
/// handful of places in a home folder where "regenerates" is false (keychains, iCloud, mail, keys).
public enum Protection {
    static let systemPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private/var/vm", "/private/var/db", "/Library/Apple",
                                 "/cores", "/private/etc"]
    static let homeRelative = ["Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail",
                               "Library/Messages", "Library/Accounts", "Library/Cookies", "Library/IdentityServices",
                               "Library/Group Containers/group.com.apple", "Library/Containers/com.apple",
                               "Library/Application Support/com.apple.TCC", "Library/Application Support/AddressBook",
                               "Library/Calendars", "Library/Photos", "Library/Biome", "Library/Daemon Containers",
                               ".ssh", ".gnupg", ".talon"]

    /// Why `path` is off-limits, or nil. `path` should be absolute and canonical (see `canonical(_:)`).
    public static func reason(_ path: String, home: String) -> String? {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == "/" || path == h || path == "/System/Volumes/Data" { return "a volume or home root — far too broad to cut" }
        for p in systemPrefixes where path == p || path.hasPrefix(p + "/") {
            return p == "/private/var/vm" ? "macOS swap and sleep image — managed by the kernel" : "macOS system files (sealed or SIP-protected)"
        }
        if path.hasSuffix(".photoslibrary") || path.contains(".photoslibrary/") { return "a Photos library — personal data" }
        if path.hasPrefix(h + "/") {
            let rel = String(path.dropFirst(h.count + 1))
            for p in homeRelative where rel == p || rel.hasPrefix(p + "/") || (p.hasSuffix("com.apple") && rel.hasPrefix(p)) {
                if p == ".talon" { return "talon's own data (the holding area lives here)" }
                if p.contains("com.apple") { return "data belonging to an Apple app or service" }
                if p.contains("Mobile Documents") || p.contains("CloudStorage") { return "cloud-synced files — deleting here deletes them everywhere" }
                return "personal data that doesn't regenerate (\(p))"
            }
        } else if path.hasPrefix("/Users/") && !path.hasPrefix("/Users/Shared") {
            return "another user's files"
        }
        var st = stat()
        if lstat(path, &st) == 0, st.st_flags & UInt32(SF_RESTRICTED) != 0 { return "SIP-protected (restricted flag)" }
        return nil
    }

    /// Absolute path with the parent's symlinks resolved but the last component left alone,
    /// so a symlink is judged as itself and its target judged separately.
    public static func canonical(_ path: String) -> String {
        let expanded = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        let parent = (expanded as NSString).deletingLastPathComponent
        let name = (expanded as NSString).lastPathComponent
        guard let rp = realPath(parent) else { return expanded }
        return rp == "/" ? "/" + name : rp + "/" + name
    }
}

public struct Refusal: Error, CustomStringConvertible, Sendable {
    public var path: String
    public var reason: String
    public var description: String { "\(path): \(reason)" }
    public init(_ path: String, _ reason: String) { self.path = path; self.reason = reason }
}

/// The checks before any cut. Each one refuses rather than guesses.
public struct CutGuard: Sendable {
    /// Cuts must land strictly inside one of these (canonical) folders. The home folder by default.
    public var allowedRoots: [String]
    public var home: String
    public var checkOpenFiles = true
    public var checkRunningApps = true

    public init(allowedRoots: [String]? = nil, home: String = NSHomeDirectory()) {
        let h = realPath(home) ?? home
        self.home = h
        self.allowedRoots = (allowedRoots ?? [h]).map { realPath($0) ?? $0 }
    }

    func inside(_ path: String) -> Bool {
        allowedRoots.contains { root in path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
    }

    /// Throws a `Refusal` explaining the first check that fails.
    public func check(_ rawPath: String, tier: Tier? = nil, ownerBundleID: String? = nil, ownerName: String? = nil) throws {
        let path = Protection.canonical(rawPath)
        var st = stat()
        guard lstat(path, &st) == 0 else { throw Refusal(path, "doesn't exist") }
        guard inside(path) else { throw Refusal(path, "outside the allowed folders (\(allowedRoots.joined(separator: ", ")))") }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            guard let target = realPath(path) else { throw Refusal(path, "a symlink whose target can't be resolved") }
            guard inside(target) else { throw Refusal(path, "a symlink pointing outside the allowed folders (→ \(target))") }
        }
        if tier == .protected { throw Refusal(path, "protected — shown for context, never cleaned") }
        if let why = Protection.reason(path, home: home) { throw Refusal(path, "protected: \(why)") }
        if checkRunningApps, let id = ownerBundleID, RunningApps.bundleIDs().contains(id.lowercased()) {
            throw Refusal(path, "\(ownerName ?? id) is running — quit it first")
        }
        if checkOpenFiles, let holder = OpenFiles.holder(of: path) {
            throw Refusal(path, "in use: \(holder.name) (pid \(holder.pid)) has \(holder.path) open")
        }
    }
}

/// Which process, if any, has something open inside a path. Your own processes only (others aren't
/// visible without root, and can't hold files in your home open without you running them).
public enum OpenFiles {
    public struct Holder: Sendable { public var pid: pid_t; public var name: String; public var path: String }

    public static func holder(of path: String) -> Holder? {
        // The kernel names vnodes by their firmlinked path (/Users/…), but be safe with the Data-volume spelling too.
        var prefixes = [path]
        if path.hasPrefix("/System/Volumes/Data/") { prefixes.append(String(path.dropFirst("/System/Volumes/Data".count))) }
        else { prefixes.append("/System/Volumes/Data" + path) }
        var found = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for pid in allPIDs() where pid > 0 {
            for p in prefixes where talon_pid_holds_path(pid, p, &found, found.count) == 1 {
                return Holder(pid: pid, name: processName(pid), path: cString(found))
            }
        }
        return nil
    }

    static func allPIDs() -> [pid_t] {
        var capacity = 4096
        while true {
            var buf = [pid_t](repeating: 0, count: capacity)
            let n = Int(proc_listallpids(&buf, Int32(capacity * MemoryLayout<pid_t>.size)))
            if n < 0 { return [] }
            if n < capacity { return Array(buf.prefix(n)) }
            capacity *= 2
        }
    }

    static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        let s = cString(buf)
        return s.isEmpty ? "pid \(pid)" : s
    }

    static func processPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return cString(buf)
    }

    static func cString(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Bundle ids of running apps, from process paths — no AppKit, so it works the same in the CLI.
public enum RunningApps {
    /// Lowercased bundle ids of every app bundle with a running process (including helpers' outer app).
    public static func bundleIDs() -> Set<String> {
        var bundles = Set<String>()
        for pid in OpenFiles.allPIDs() where pid > 0 {
            guard let path = OpenFiles.processPath(pid) else { continue }
            // The outermost bundle owns the helpers nested inside it.
            if let r = path.range(of: ".app/") { bundles.insert(String(path[..<r.lowerBound]) + ".app") }
        }
        var ids = Set<String>()
        for b in bundles {
            if let id = AppInventory.bundleID(ofBundleAt: b) { ids.insert(id.lowercased()) }
        }
        return ids
    }
}
