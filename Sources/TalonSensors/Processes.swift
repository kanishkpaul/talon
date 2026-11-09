import Darwin
import TalonModel
import TalonPrivate

/// Raw per-process counters from one `proc_pid_rusage` call.
public struct RawProcess: Sendable {
    public var pid: pid_t
    public var startTime: UInt64     // mach absolute time — with pid, the process's identity
    public var footprint: UInt64
    public var cpuNanoseconds: UInt64
    public var diskWritten: UInt64
    public var diskRead: UInt64
}

/// libproc wrappers. As a normal user ~440 of ~680 processes are readable; as root, all of them.
public enum ProcessSensor {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()

    public static func machToNanoseconds(_ t: UInt64) -> UInt64 {
        timebase.numer == timebase.denom ? t : t / timebase.denom * timebase.numer + t % timebase.denom * timebase.numer / timebase.denom
    }

    public static func allPIDs() -> [pid_t] {
        var capacity = 4096
        while true {
            var buf = [pid_t](repeating: 0, count: capacity)
            let n = Int(proc_listallpids(&buf, Int32(capacity * MemoryLayout<pid_t>.size)))
            if n < 0 { return [] }
            if n < capacity { return Array(buf.prefix(n)) }
            capacity *= 2
        }
    }

    public static func read(_ pid: pid_t) -> RawProcess? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        return RawProcess(pid: pid, startTime: info.ri_proc_start_abstime, footprint: info.ri_phys_footprint,
                          cpuNanoseconds: machToNanoseconds(info.ri_user_time &+ info.ri_system_time),
                          diskWritten: info.ri_diskio_byteswritten, diskRead: info.ri_diskio_bytesread)
    }

    /// Footprint only — the cheap call for the fast lane that watches capped processes.
    public static func footprint(_ pid: pid_t) -> UInt64? { read(pid)?.footprint }

    public struct Info: Sendable {
        public var uid: uid_t
        public var parent: pid_t
        public var stopped: Bool
        public var startSeconds: UInt64
    }

    public static func info(_ pid: pid_t) -> Info? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        return Info(uid: bsd.pbi_uid, parent: pid_t(bsd.pbi_ppid), stopped: bsd.pbi_status == UInt32(SSTOP),
                    startSeconds: bsd.pbi_start_tvsec)
    }

    public static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        let s = cString(buf)
        return s.isEmpty ? "pid \(pid)" : s
    }

    public static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return cString(buf)
    }

    static func cString(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func responsible(_ pid: pid_t) -> pid_t { talon_responsible_pid(pid) }
    public static var responsibleAvailable: Bool { talon_responsible_available() }

    /// A stable key and a display name for the app responsible for `pid`:
    /// `/Applications/Safari.app` → "Safari"; a bare binary → its path and process name.
    public static func appIdentity(_ pid: pid_t) -> (key: String, name: String) {
        guard let path = path(pid) else { let n = name(pid); return ("proc:" + n, n) }
        if let r = path.range(of: ".app/") {
            let bundle = String(path[..<r.lowerBound]) + ".app"
            let display = bundle.split(separator: "/").last.map { String($0.dropLast(4)) } ?? name(pid)
            return (bundle, display)
        }
        return (path, name(pid))
    }
}
