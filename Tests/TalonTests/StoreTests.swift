import Foundation
import Testing
@testable import TalonCore
import TalonModel
@testable import TalonStore

@Suite struct StoreTests {
    func bucket(_ start: TimeInterval, period: TimeInterval, cpu: [Double], temp: Double = .nan) -> SystemBucket {
        var stats = Array(repeating: Accumulator(), count: SystemSeries.allCases.count)
        for v in cpu { stats[SystemSeries.index(of: .cpu)].add(v) }
        stats[SystemSeries.index(of: .cpuTemp)].add(temp)
        return SystemBucket(start: start, period: period, stats: stats)
    }

    @Test func columnNamesAreSnakeCase() {
        #expect(HistoryStore.column(.memUsed) == "mem_used")
        #expect(HistoryStore.column(.cpu) == "cpu")
        #expect(HistoryStore.column(.diskWriteRate) == "disk_write_rate")
    }

    @Test func roundTripsEachTier() throws {
        let store = try HistoryStore.inMemory()
        try store.write(tenSeconds: [bucket(100, period: 10, cpu: [10, 20], temp: 48.25)],
                        minutes: [bucket(60, period: 60, cpu: [5, 15, 40])],
                        hours: [bucket(0, period: 3600, cpu: [30])], appMinutes: [], appHours: [])
        let ten = try store.history(.cpu, from: 0, to: 1000, tier: .tenSeconds)
        #expect(ten == [HistoryPoint(time: 100, min: 15, avg: 15, max: 15)])
        let temp = try store.history(.cpuTemp, from: 0, to: 1000, tier: .tenSeconds)
        #expect(temp.first?.avg == 48.25)                    // centi-degrees survive
        let min = try store.history(.cpu, from: 0, to: 1000, tier: .minute)
        #expect(min.first.map { [$0.min, $0.avg, $0.max] } == [5, 20, 40])
        let missing = try store.history(.swapUsed, from: 0, to: 1000, tier: .minute)
        #expect(missing.first?.avg.isNaN == true)            // never sampled → NULL → NaN
    }

    @Test func mergesARestartedBucketInsteadOfReplacingIt() throws {
        let store = try HistoryStore.inMemory()
        try store.write(tenSeconds: [], minutes: [bucket(60, period: 60, cpu: [10, 10, 10])], hours: [], appMinutes: [], appHours: [])
        try store.write(tenSeconds: [], minutes: [bucket(60, period: 60, cpu: [50])], hours: [], appMinutes: [], appHours: [])
        let p = try #require(try store.history(.cpu, from: 0, to: 1000, tier: .minute).first)
        #expect(p.min == 10 && p.max == 50)
        #expect(p.avg == 20)    // (10×3 + 50×1) / 4
    }

    @Test func appTotalsRankAndSum() throws {
        let store = try HistoryStore.inMemory()
        let now = Date().timeIntervalSince1970
        func app(_ name: String, cpu: Double, mem: Double, written: Double) -> AppStats {
            var s = AppStats(name: name)
            s.cpuSeconds = cpu; s.bytesWritten = written
            s.memory.add(mem); s.memory.add(mem * 2)
            return s
        }
        let b1 = AppBucket(start: now - 120, period: 60, apps: ["/A.app": app("A", cpu: 10, mem: 1_048_576, written: 4096),
                                                                "/B.app": app("B", cpu: 1, mem: 1_073_741_824, written: 1_073_741_824)])
        let b2 = AppBucket(start: now - 60, period: 60, apps: ["/A.app": app("A", cpu: 5, mem: 1_048_576, written: 4096)])
        try store.write(tenSeconds: [], minutes: [], hours: [], appMinutes: [b1, b2], appHours: [])

        let byCPU = try store.topApps(from: now - 3600, by: .cpu, limit: 10)
        #expect(byCPU.map(\.name) == ["A", "B"])
        #expect(byCPU[0].cpuSeconds == 15)
        #expect(byCPU[0].bytesWritten == 8192)
        let byDisk = try store.topApps(from: now - 3600, by: .disk, limit: 1)
        #expect(byDisk.map(\.name) == ["B"])
        #expect(byDisk[0].memoryPeak == 2 << 30)
    }

    @Test func eventsAndRetention() throws {
        let store = try HistoryStore.inMemory()
        let now = Date().timeIntervalSince1970
        try store.record(TalonEvent(time: now - 10, kind: .frozen, pid: 42, message: "paused x"))
        try store.record(TalonEvent(time: now - 5, kind: .thawed, pid: 42, message: "resumed x"))
        #expect(try store.events(from: now - 60, limit: 10).map(\.kind) == [.thawed, .frozen])

        try store.write(tenSeconds: [bucket(now - 8 * 86_400, period: 10, cpu: [1]), bucket(now - 60, period: 10, cpu: [1])],
                        minutes: [], hours: [bucket(now - 400 * 86_400, period: 3600, cpu: [1])], appMinutes: [], appHours: [])
        try store.prune(now: now)
        let counts = try store.rowCounts()
        #expect(counts["sys_10s"] == 1)    // the 8-day-old row is gone
        #expect(counts["sys_1h"] == 1)     // hourly is forever
        #expect(counts["event"] == 2)
    }

    @Test func fileStoreReopensAndUpgradesInPlace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("talon-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("talon.sqlite").path
        do {
            let s = try HistoryStore(path: path)
            try s.write(tenSeconds: [bucket(10, period: 10, cpu: [7])], minutes: [], hours: [], appMinutes: [], appHours: [])
        }
        let again = try HistoryStore(path: path)   // migrations + column checks are idempotent
        #expect(try again.history(.cpu, from: 0, to: 100, tier: .tenSeconds).first?.avg == 7)
        #expect(again.bytesOnDisk > 0)
    }

    @Test func tierChoice() throws {
        let store = try HistoryStore.inMemory()
        #expect(store.tier(for: 6 * 3600) == .tenSeconds)
        #expect(store.tier(for: 7 * 86_400) == .minute)
        #expect(store.tier(for: 365 * 86_400) == .hour)
    }
}
