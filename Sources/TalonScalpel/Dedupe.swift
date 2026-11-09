import CryptoKit
import Darwin
import Foundation
import TalonPrivate

/// A set of files with identical contents. `keep` stays as it is; each of `copies` can become a clone of it.
public struct DuplicateGroup: Codable, Sendable {
    public var keep: FileRecord
    public var copies: [FileRecord]
    /// Bytes freed by turning every copy into a clone of `keep`: each copy's private blocks.
    public var reclaimable: UInt64 { copies.reduce(0) { $0 + $1.privateSize } }
}

/// Size → partial hash → full hash. Files that are already full clones of each other (same `CLONEID`)
/// or hard links (same inode) are one file, not duplicates: replacing them would free nothing.
public enum Duplicates {
    public static func find(_ files: [FileRecord], minSize: UInt64 = 1) -> [DuplicateGroup] {
        let bySize = Dictionary(grouping: files.filter { $0.logical >= max(1, minSize) }, by: \.logical)
        var groups: [DuplicateGroup] = []
        for (_, same) in bySize where same.count > 1 {
            let distinct = collapse(same)
            guard distinct.count > 1 else { continue }
            let byPartial = Dictionary(grouping: distinct) { partialHash($0.path) }
            for (partial, p) in byPartial where partial != nil && p.count > 1 {
                let byFull = Dictionary(grouping: p) { fullHash($0.path) }
                for (full, f) in byFull where full != nil && f.count > 1 {
                    // Keep the oldest copy: it's most likely the one other things point at.
                    let sorted = f.sorted { ($0.modified, $0.path) < ($1.modified, $1.path) }
                    groups.append(DuplicateGroup(keep: sorted[0], copies: Array(sorted.dropFirst())))
                }
            }
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// One representative per clone family and per inode.
    static func collapse(_ files: [FileRecord]) -> [FileRecord] {
        var seenClone = Set<UInt64>(), seenInode = Set<UInt64>()
        var out: [FileRecord] = []
        for f in files.sorted(by: { $0.path < $1.path }) {
            if !seenInode.insert(f.fileID).inserted { continue }
            if f.cloneRefCount > 1, let c = f.cloneID, !seenClone.insert(c).inserted { continue }
            out.append(f)
        }
        return out
    }

    static let chunk = 64 << 10

    /// SHA-256 of the first and last 64 KB — cheap, and enough to split almost every same-size pair.
    static func partialHash(_ path: String) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        _ = fcntl(h.fileDescriptor, F_NOCACHE, 1)
        var hasher = SHA256()
        do {
            // read(upToCount:) returns nil at end of file, not empty data.
            hasher.update(data: try h.read(upToCount: chunk) ?? Data())
            let end = try h.seekToEnd()
            if end > UInt64(chunk) * 2 {
                try h.seek(toOffset: end - UInt64(chunk))
                hasher.update(data: try h.read(upToCount: chunk) ?? Data())
            }
        } catch { return nil }
        return Data(hasher.finalize())
    }

    static func fullHash(_ path: String) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        _ = fcntl(h.fileDescriptor, F_NOCACHE, 1)  // don't push the user's working set out of the cache
        var hasher = SHA256()
        do {
            while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        } catch { return nil }
        return Data(hasher.finalize())
    }

    // MARK: - Replace with a clone

    public enum CloneError: Error, CustomStringConvertible {
        case changed(String)
        case unsupported(String, String)
        case io(String, String, Int32)
        public var description: String {
            switch self {
            case .changed(let p): "\(p) changed since it was hashed — skipped"
            case .unsupported(let p, let why): "\(p): \(why)"
            case .io(let p, let what, let e): "\(p): \(what) failed: \(String(cString: strerror(e)))"
            }
        }
    }

    /// Turns `duplicate` into an APFS clone of `original`: clonefile(2) to a temporary name beside it,
    /// give the clone the duplicate's own metadata (extended attributes, mode, flags, birth/modify/access
    /// dates), then rename(2) over the duplicate — atomic, so no moment exists where the path is missing.
    /// Returns the bytes freed.
    @discardableResult
    public static func replaceWithClone(original: String, duplicate: String) throws -> UInt64 {
        var so = stat(), sd = stat()
        guard lstat(original, &so) == 0 else { throw CloneError.io(original, "stat", errno) }
        guard lstat(duplicate, &sd) == 0 else { throw CloneError.io(duplicate, "stat", errno) }
        guard (so.st_mode & S_IFMT) == S_IFREG, (sd.st_mode & S_IFMT) == S_IFREG else { throw CloneError.unsupported(duplicate, "not a regular file") }
        guard so.st_dev == sd.st_dev else { throw CloneError.unsupported(duplicate, "on another volume than the original") }
        guard so.st_ino != sd.st_ino else { throw CloneError.unsupported(duplicate, "a hard link to the original") }
        guard sd.st_nlink == 1 else { throw CloneError.unsupported(duplicate, "has other hard links, which a clone would split off") }
        guard sd.st_uid == getuid() else { throw CloneError.unsupported(duplicate, "owned by another user") }
        let locked = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND | SF_RESTRICTED)
        guard sd.st_flags & locked == 0 else { throw CloneError.unsupported(duplicate, "locked or system-protected") }
        guard so.st_size == sd.st_size, let h = fullHash(original), h == fullHash(duplicate) else {
            throw CloneError.changed(duplicate)
        }
        let freed = Entry.stat(duplicate)?.privateSize ?? UInt64(sd.st_blocks) * 512

        let dir = (duplicate as NSString).deletingLastPathComponent
        let tmp = dir + "/.talon-clone-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        guard clonefile(original, tmp, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else { throw CloneError.io(duplicate, "clonefile", errno) }
        var addedS: Int64 = 0, addedNs: Int64 = 0
        let hasAdded = talon_get_added_time(duplicate, &addedS, &addedNs) == 0
        do {
            try copyMetadata(from: duplicate, stat: sd, to: tmp)
            // Last look: if the duplicate moved under us, leave it alone.
            var now = stat()
            guard lstat(duplicate, &now) == 0, now.st_ino == sd.st_ino, now.st_mtimespec.tv_sec == sd.st_mtimespec.tv_sec,
                  now.st_mtimespec.tv_nsec == sd.st_mtimespec.tv_nsec, now.st_size == sd.st_size else { throw CloneError.changed(duplicate) }
            guard rename(tmp, duplicate) == 0 else { throw CloneError.io(duplicate, "rename", errno) }
        } catch {
            unlink(tmp)
            throw error
        }
        // Finder's Date Added belongs to the path's history, not the new inode's; set it after the rename.
        if hasAdded { _ = talon_set_added_time(duplicate, addedS, addedNs) }
        return freed
    }

    /// Replaces the clone's metadata (inherited from the original) with the duplicate's.
    static func copyMetadata(from src: String, stat sd: stat, to dst: String) throws {
        for name in xattrNames(dst) where removexattr(dst, name, XATTR_NOFOLLOW) != 0 {
            throw CloneError.io(dst, "removexattr \(name)", errno)
        }
        for name in xattrNames(src) {
            let size = getxattr(src, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { throw CloneError.io(src, "getxattr \(name)", errno) }
            var buf = [UInt8](repeating: 0, count: size)
            let got = getxattr(src, name, &buf, size, 0, XATTR_NOFOLLOW)
            guard got >= 0, setxattr(dst, name, buf, got, 0, XATTR_NOFOLLOW) == 0 else { throw CloneError.io(dst, "setxattr \(name)", errno) }
        }
        // ACLs ride along via copyfile; mode, owner and dates are set explicitly below.
        _ = copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_ACL))
        guard chmod(dst, sd.st_mode & 0o7777) == 0 else { throw CloneError.io(dst, "chmod", errno) }
        if sd.st_gid != getgid() { _ = lchown(dst, sd.st_uid, sd.st_gid) }
        let rc = talon_set_times(dst, Int64(sd.st_birthtimespec.tv_sec), Int64(sd.st_birthtimespec.tv_nsec),
                                 Int64(sd.st_mtimespec.tv_sec), Int64(sd.st_mtimespec.tv_nsec),
                                 Int64(sd.st_atimespec.tv_sec), Int64(sd.st_atimespec.tv_nsec))
        guard rc == 0 else { throw CloneError.io(dst, "setting dates", rc) }
        if sd.st_flags != 0 { _ = lchflags(dst, sd.st_flags) }
    }

    static func xattrNames(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: size)
        let got = listxattr(path, &buf, size, XATTR_NOFOLLOW)
        guard got > 0 else { return [] }
        return buf.prefix(got).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }
}
