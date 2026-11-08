// Spike 5a — talond: a root LaunchDaemon reachable over XPC.
//
// Safety rules baked in from day one:
//   • Only accepts XPC connections from one user ID (yours, fixed at install time).
//   • Only acts on processes owned by that same user — never system/root processes.

import Darwin
import Foundation

@_silgen_name("memorystatus_control")
func memorystatus_control(_ command: UInt32, _ pid: Int32, _ flags: UInt32,
                          _ buffer: UnsafeMutableRawPointer?, _ size: Int) -> Int32

private let MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES: UInt32 = 7
private let MEMORYSTATUS_MEMLIMIT_ATTR_FATAL: UInt32 = 1

private struct MemlimitProps {
    var active: Int32, activeAttr: UInt32, inactive: Int32, inactiveAttr: UInt32
}

final class Helper: NSObject, HelperProtocol {
    let allowedUID: uid_t
    init(allowedUID: uid_t) { self.allowedUID = allowedUID }

    func status(reply: @escaping (String) -> Void) {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var readable = 0
        for pid in pids.prefix(n) {
            var info = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if rc == 0 { readable += 1 }
        }
        reply("helper running as uid \(getuid()) · can read \(readable) of \(n) processes · serving uid \(allowedUID) only")
    }

    func capMemory(pid: Int32, megabytes: Int32, reply: @escaping (Int32, String) -> Void) {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            reply(ESRCH, "refused: pid \(pid) not found"); return
        }
        guard info.pbi_uid == allowedUID else {
            reply(EPERM, "refused: pid \(pid) belongs to uid \(info.pbi_uid), not you (\(allowedUID))"); return
        }
        var props = MemlimitProps(active: megabytes, activeAttr: MEMORYSTATUS_MEMLIMIT_ATTR_FATAL,
                                  inactive: megabytes, inactiveAttr: MEMORYSTATUS_MEMLIMIT_ATTR_FATAL)
        let rc = memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES, pid, 0, &props, MemoryLayout<MemlimitProps>.size)
        if rc == 0 { reply(0, "hard cap of \(megabytes) MB set on pid \(pid)") }
        else { let e = errno; reply(e, "memorystatus_control failed: \(String(cString: strerror(e)))") }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let helper: Helper
    init(helper: Helper) { self.helper = helper }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard c.effectiveUserIdentifier == helper.allowedUID else {
            NSLog("talond: rejected connection from uid \(c.effectiveUserIdentifier)")
            return false
        }
        c.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        c.exportedObject = helper
        c.resume()
        return true
    }
}

@main
struct Daemon {
    static func main() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--allowed-uid"), i + 1 < args.count, let uid = uid_t(args[i + 1]) else {
            FileHandle.standardError.write("usage: talond --allowed-uid <uid>\n".data(using: .utf8)!)
            exit(64)
        }
        let delegate = ListenerDelegate(helper: Helper(allowedUID: uid))
        let listener = NSXPCListener(machServiceName: helperMachName)
        listener.delegate = delegate
        listener.resume()
        NSLog("talond: listening on \(helperMachName) for uid \(uid)")
        RunLoop.main.run()
    }
}
