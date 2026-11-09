import Foundation
import Synchronization
import TalonModel

/// Talks to talond. Prefers the root daemon, falls back to the per-user agent.
public final class TalonClient: @unchecked Sendable {
    public enum Endpoint: String, Sendable {
        case daemon, agent
        case anonymous   // an in-process listener endpoint (tests, an embedded helper)
        var machName: String { self == .daemon ? TalonService.daemon : TalonService.agent }
    }

    public let endpoint: Endpoint
    private let connection: NSXPCConnection

    public init(endpoint: Endpoint) {
        self.endpoint = endpoint
        connection = NSXPCConnection(machServiceName: endpoint.machName, options: endpoint == .daemon ? .privileged : [])
        connection.remoteObjectInterface = NSXPCInterface(with: TalonXPCProtocol.self)
        connection.resume()
    }

    /// Connects to an `NSXPCListener.anonymous()` endpoint.
    public init(listenerEndpoint: NSXPCListenerEndpoint) {
        endpoint = .anonymous
        connection = NSXPCConnection(listenerEndpoint: listenerEndpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: TalonXPCProtocol.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    /// The first endpoint that answers `hello` with a matching protocol, or the most useful error.
    public static func connect(timeout: TimeInterval = 1.5) -> Result<TalonClient, TalonError> {
        var lastError = TalonError(.unreachable, "talond isn't running — `make agent` (no admin) or `sudo make install`")
        for endpoint in [Endpoint.daemon, .agent] {
            let client = TalonClient(endpoint: endpoint)
            do {
                if case .hello(let v, _) = try client.send(.hello, timeout: timeout), v == talonProtocolVersion {
                    return .success(client)
                }
            } catch where error.code == .versionMismatch {
                return .failure(error)
            } catch {
                if error.code != .unreachable && error.code != .timeout { lastError = error }
            }
        }
        return .failure(lastError)
    }

    public func send(_ request: TalonRequest, timeout: TimeInterval = 5) throws(TalonError) -> TalonReply {
        let payload: Data
        do { payload = try TalonCodec.encode(request) } catch { throw TalonError(.badRequest, "\(error)") }

        let result = Mutex<Result<Data, TalonError>?>(nil)
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { err in
            result.withLock { $0 = $0 ?? .failure(TalonError(.unreachable, err.localizedDescription)) }
            done.signal()
        }
        guard let helper = proxy as? TalonXPCProtocol else { throw TalonError(.unreachable, "bad XPC proxy") }
        helper.handle(payload) { data in
            result.withLock { $0 = $0 ?? .success(data) }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw TalonError(.timeout, "talond (\(endpoint.rawValue)) didn't answer within \(Int(timeout))s")
        }
        switch result.withLock({ $0 })! {
        case .failure(let e): throw e
        case .success(let data):
            let reply = try TalonCodec.decode(TalonReply.self, from: data)
            if case .error(let e) = reply { throw e }
            return reply
        }
    }
}
