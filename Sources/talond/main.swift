// talond — talon's helper. As a root LaunchDaemon it sees every process and can set kernel memory
// ceilings on running apps; as a per-user LaunchAgent (no admin) it samples and keeps history for
// your own processes. Same binary, same XPC schema.
//
//   talond --allowed-uid 501                 (system daemon; launchd passes this)
//   talond --agent                           (user agent; serves the current user)
//   talond --no-xpc --verbose --duration 30  (sampler + history only, prints each tick)

import Darwin
import Foundation
import TalonDaemon
import TalonIPC
import TalonModel

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("talond: \(message)\n".utf8))
    exit(64)
}

func need<T>(_ value: T?, _ message: String) -> T {
    guard let value else { fail(message) }
    return value
}

// MARK: - Arguments

var allowedUID: uid_t?
var agent = false, xpc = true, verbose = false
var dbPath: String?
var duration: TimeInterval?
var flush: TimeInterval = 60
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--allowed-uid": allowedUID = need(args.next().flatMap { uid_t($0) }, "--allowed-uid needs a number")
    case "--agent": agent = true
    case "--no-xpc": xpc = false
    case "--verbose", "-v": verbose = true
    case "--db": dbPath = need(args.next(), "--db needs a path")
    case "--duration": duration = need(args.next().flatMap(TimeSpan.parse), "--duration needs a time like 30s")
    case "--flush": flush = need(args.next().flatMap(TimeSpan.parse), "--flush needs a time like 60s")
    case "--version": print("talond \(talonVersion) (protocol v\(talonProtocolVersion))"); exit(0)
    case "-h", "--help":
        print("usage: talond [--allowed-uid UID | --agent] [--db PATH] [--no-xpc] [--verbose] [--duration 30s] [--flush 60s]")
        exit(0)
    default: fail("unknown argument \(a)")
    }
}

let isRoot = geteuid() == 0
if isRoot && allowedUID == nil && !agent { fail("as root, --allowed-uid is required (the one user this helper serves)") }
let uid = allowedUID ?? getuid()
let defaultDB = isRoot
    ? "/Library/Application Support/Talon/talon.sqlite"
    : NSHomeDirectory() + "/Library/Application Support/Talon/talon.sqlite"

let daemon = Daemon(options: .init(allowedUID: uid, databasePath: dbPath ?? defaultDB, flushInterval: flush, verbose: verbose))
daemon.start()

var listener: NSXPCListener?
var delegate: ListenerDelegate?
if xpc {
    let name = agent || !isRoot ? TalonService.agent : TalonService.daemon
    delegate = ListenerDelegate(daemon: daemon)
    listener = NSXPCListener(machServiceName: name)
    listener!.delegate = delegate
    listener!.resume()
    log.notice("listening on \(name, privacy: .public) for uid \(uid)")
    if verbose { print("talond: listening on \(name) for uid \(uid)") }
}

// Clean exit on SIGTERM (launchd) and SIGINT (terminal): thaw anything frozen, commit history.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        daemon.shutdown()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}
if let duration {
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        daemon.shutdown()
        exit(0)
    }
}

dispatchMain()
