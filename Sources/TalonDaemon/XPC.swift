import Darwin
import Foundation
import TalonIPC
import TalonModel

/// One per XPC connection; remembers who connected (from the audit token, via euid — never a pid).
public final class ConnectionHandler: NSObject, TalonXPCProtocol, @unchecked Sendable {
    let daemon: Daemon
    let callerUID: uid_t

    public init(daemon: Daemon, callerUID: uid_t) {
        self.daemon = daemon
        self.callerUID = callerUID
    }

    public func handle(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        let response: TalonReply
        do {
            response = daemon.handle(try TalonCodec.decode(TalonRequest.self, from: request), callerUID: callerUID)
        } catch {
            response = .error(error)
        }
        reply((try? TalonCodec.encode(response)) ?? Data())
    }
}

public final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let daemon: Daemon
    public init(daemon: Daemon) { self.daemon = daemon }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        let uid = c.effectiveUserIdentifier
        guard uid == daemon.options.allowedUID || uid == 0 else {
            log.notice("rejected XPC connection from uid \(uid)")
            return false
        }
        c.exportedInterface = NSXPCInterface(with: TalonXPCProtocol.self)
        c.exportedObject = ConnectionHandler(daemon: daemon, callerUID: uid)
        c.resume()
        return true
    }
}
