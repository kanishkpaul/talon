import Foundation
import Testing
import TalonModel
@testable import TalonIPC

@Suite struct CodecTests {
    @Test(arguments: [
        TalonRequest.hello, .status, .processes, .health, .history(series: .cpuTemp, range: 3600, maxPoints: 120),
        .topApps(range: 86_400, by: .disk, limit: 10), .events(range: 60, limit: 5),
        .capMemory(pid: 42, bytes: 6 << 30), .memoryLimit(pid: 42), .freeze(pid: 7), .thaw(pid: 7),
    ])
    func requestsRoundTrip(_ r: TalonRequest) throws {
        #expect(try TalonCodec.decode(TalonRequest.self, from: TalonCodec.encode(r)) == r)
    }

    @Test func nanSurvivesTheWire() throws {
        let reply = TalonReply.history(HistorySeries(series: .ssdTemp, tier: .live,
                                                     points: [HistoryPoint(time: 1, min: .nan, avg: .nan, max: .nan)]))
        guard case .history(let h) = try TalonCodec.decode(TalonReply.self, from: TalonCodec.encode(reply)) else {
            Issue.record("wrong case"); return
        }
        #expect(h.points[0].avg.isNaN)
    }

    @Test func versionMismatchIsExplained() throws {
        struct Envelope: Codable { var version: Int; var body: TalonRequest }
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        let old = try e.encode(Envelope(version: talonProtocolVersion + 1, body: .hello))
        #expect(throws: TalonError(.versionMismatch, "protocol v\(talonProtocolVersion + 1), expected v\(talonProtocolVersion) — rebuild talon and talond together")) {
            try TalonCodec.decode(TalonRequest.self, from: old)
        }
    }

    @Test func garbageIsABadRequest() {
        do {
            _ = try TalonCodec.decode(TalonRequest.self, from: Data("nope".utf8))
            Issue.record("should throw")
        } catch {
            #expect(error.code == .badRequest)
        }
    }
}
