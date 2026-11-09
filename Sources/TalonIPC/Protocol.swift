import Foundation
import TalonModel

/// Bump when a `TalonRequest` / `TalonReply` case changes shape. Old clients get a clear error.
public let talonProtocolVersion = 1
public let talonVersion = "0.1.0"

public enum TalonService {
    /// The root LaunchDaemon (`sudo make install`). Full process visibility, can set kernel ceilings.
    public static let daemon = "dev.kanishk.talond"
    /// The same binary as a per-user LaunchAgent (`make agent`). No admin, sees only your processes.
    public static let agent = "dev.kanishk.talond.agent"
}

/// Every verb the helper understands. Typed, never a passthrough: there is no "run this" request.
public enum TalonRequest: Codable, Sendable, Equatable {
    case hello
    case status
    case processes
    case history(series: SystemSeries, range: TimeInterval, maxPoints: Int)
    case topApps(range: TimeInterval, by: AppMetric, limit: Int)
    case events(range: TimeInterval, limit: Int)
    case capMemory(pid: Int32, bytes: UInt64)
    case memoryLimit(pid: Int32)
    case freeze(pid: Int32)
    case thaw(pid: Int32)
}

public enum TalonReply: Codable, Sendable {
    case hello(protocolVersion: Int, daemonVersion: String)
    case status(DaemonStatus)
    case processes(ProcessSnapshot)
    case history(HistorySeries)
    case topApps([AppTotal])
    case events([TalonEvent])
    case memoryLimit(activeMB: Int32, inactiveMB: Int32, fatal: Bool)
    case ok(String)
    case error(TalonError)
}

public struct TalonError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        case refused        // the safety policy said no
        case notFound
        case failed         // the kernel or a sensor said no
        case badRequest
        case versionMismatch
        case unreachable    // no daemon answering
        case timeout
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
    public var description: String { message }
}

public struct DaemonStatus: Codable, Sendable {
    public var version: String
    public var protocolVersion: Int
    public var pid: Int32
    public var euid: UInt32
    public var allowedUID: UInt32
    public var startedAt: Date
    public var ownCPUPercent: Double        // averaged since start
    public var ownFootprint: UInt64
    public var ownBytesWritten: UInt64      // the SSD cost of talon itself
    public var databasePath: String
    public var databaseBytes: UInt64
    public var readableProcesses: Int
    public var deniedProcesses: Int
    public var lastSweepMillis: Double
    public var frozen: [Int32]
    public var latest: SystemSample?

    public init(version: String, protocolVersion: Int, pid: Int32, euid: UInt32, allowedUID: UInt32, startedAt: Date,
                ownCPUPercent: Double, ownFootprint: UInt64, ownBytesWritten: UInt64, databasePath: String,
                databaseBytes: UInt64, readableProcesses: Int, deniedProcesses: Int, lastSweepMillis: Double,
                frozen: [Int32], latest: SystemSample?) {
        self.version = version; self.protocolVersion = protocolVersion; self.pid = pid; self.euid = euid
        self.allowedUID = allowedUID; self.startedAt = startedAt; self.ownCPUPercent = ownCPUPercent
        self.ownFootprint = ownFootprint; self.ownBytesWritten = ownBytesWritten; self.databasePath = databasePath
        self.databaseBytes = databaseBytes; self.readableProcesses = readableProcesses
        self.deniedProcesses = deniedProcesses; self.lastSweepMillis = lastSweepMillis; self.frozen = frozen
        self.latest = latest
    }
}

/// The wire format. Binary property lists carry NaN (unavailable readings) natively; JSON does not.
public enum TalonCodec {
    struct VersionOnly: Codable { var version: Int }

    struct Envelope<T: Codable>: Codable {
        var version: Int
        var body: T
    }

    public static func encode<T: Codable>(_ value: T) throws -> Data {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return try e.encode(Envelope(version: talonProtocolVersion, body: value))
    }

    public static func decode<T: Codable>(_ type: T.Type, from data: Data) throws(TalonError) -> T {
        do {
            let env = try PropertyListDecoder().decode(Envelope<T>.self, from: data)
            guard env.version == talonProtocolVersion else {
                throw TalonError(.versionMismatch, "protocol v\(env.version), expected v\(talonProtocolVersion) — rebuild talon and talond together")
            }
            return env.body
        } catch let e as TalonError {
            throw e
        } catch {
            // A version mismatch can also surface as a shape mismatch; peek at the version alone.
            if let v = try? PropertyListDecoder().decode(VersionOnly.self, from: data), v.version != talonProtocolVersion {
                throw TalonError(.versionMismatch, "protocol v\(v.version), expected v\(talonProtocolVersion) — rebuild talon and talond together")
            }
            throw TalonError(.badRequest, "undecodable message: \(error)")
        }
    }
}

/// The XPC surface: one method carrying an encoded request, one encoded reply.
@objc(TalonXPCProtocol)
public protocol TalonXPCProtocol {
    func handle(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}
