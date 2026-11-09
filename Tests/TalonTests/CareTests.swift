import Foundation
import Testing
@testable import TalonCore
import TalonDaemon
import TalonIPC
import TalonModel

@Suite struct CareTests {
    let now: TimeInterval = 1_800_000_000
    let gib = 1_073_741_824.0

    func inputs(days: [HealthDay] = [], writers: [AppTotal] = [], hourly: [SystemSeries: [HistoryPoint]] = [:],
                events: [TalonEvent] = [], latest: SystemSample? = nil) -> CareInputs {
        CareInputs(now: now, days: days, writers: writers, memoryHogs: [AppTotal(key: "/X.app", name: "Xcode", cpuSeconds: 0,
                   memoryPeak: 9 << 30, memoryAverage: 6 << 30, bytesWritten: 0)], physicalMemory: 16 << 30,
                   latest: latest, hourly: hourly, events: events)
    }

    func day(_ n: Int, written: Double, used: Int = 0, nominal: Int = 4300, shutdowns: UInt64 = 20) -> HealthDay {
        var d = HealthDay(day: "d\(n)", time: now - Double(30 - n) * 86_400, battery: nil, ssd: nil)
        d.ssdBytesWritten = UInt64(written); d.ssdPercentUsed = used; d.nominalCapacity = nominal; d.designCapacity = 4629
        d.unsafeShutdowns = shutdowns; d.cycleCount = 100
        return d
    }

    func hours(_ count: Int, _ f: (Int) -> (Double, Double, Double)) -> [HistoryPoint] {
        (0..<count).map { i in let v = f(i); return HistoryPoint(time: now - Double(count - i) * 3600, min: v.0, avg: v.1, max: v.2) }
    }

    @Test func quietMacSaysLittle() {
        let found = Care.insights(inputs(days: (0..<5).map { day($0, written: 12e12 + Double($0) * 20 * gib) }))
        #expect(found.allSatisfy { $0.severity <= .info })
        #expect(found.contains { $0.id == "ssd.healthy" })
    }

    @Test func namesTheTopWriter() {
        let w = [AppTotal(key: "/D.app", name: "Docker", cpuSeconds: 0, memoryPeak: 0, memoryAverage: 0, bytesWritten: 90 << 30),
                 AppTotal(key: "/S.app", name: "Safari", cpuSeconds: 0, memoryPeak: 0, memoryAverage: 0, bytesWritten: 10 << 30)]
        let i = Care.insights(inputs(writers: w)).first { $0.area == .ssd }
        #expect(i?.title == "Docker wrote 90.0 GB to the SSD this week")
        #expect(i?.severity == .watch)
        #expect(i?.detail.hasPrefix("90%") == true)
    }

    @Test func heavyDailyWritesFromTheDrivesCounter() {
        let days = (0..<6).map { day($0, written: 12e12 + Double($0) * 120 * gib) }
        #expect(Care.insights(inputs(days: days)).contains { $0.id == "ssd.daily-rate" && $0.severity == .watch })
    }

    @Test func wearForecast() {
        let days = [day(0, written: 0, used: 2), day(30, written: 0, used: 3)]
        let i = Care.insights(inputs(days: days)).first { $0.id == "ssd.wear-forecast" }
        #expect(i != nil)
        #expect(i?.title.contains("3%") == true)
    }

    @Test func batteryParkedAtFull() {
        let charge = hours(7 * 24) { _ in (98, 99, 100) }
        let plugged = hours(7 * 24) { _ in (1, 1, 1) }
        let i = Care.insights(inputs(hourly: [.batteryCharge: charge, .onCharger: plugged])).first { $0.id == "battery.parked-full" }
        #expect(i?.severity == .act)
        #expect(i?.suggestion?.contains("Charging") == true)
        // Same hours on battery: nothing.
        let unplugged = hours(7 * 24) { _ in (0, 0, 0) }
        #expect(!Care.insights(inputs(hourly: [.batteryCharge: charge, .onCharger: unplugged])).contains { $0.id == "battery.parked-full" })
    }

    @Test func wornBatteryNeedsService() {
        #expect(Care.insights(inputs(days: [day(0, written: 0, nominal: 3600)])).contains { $0.id == "battery.service" && $0.severity == .act })
    }

    @Test func swapAndPressure() {
        let swap = hours(24) { i in (1e9, 2e9, i == 10 ? 9 * gib : 3e9) }
        let i = Care.insights(inputs(hourly: [.swapUsed: swap])).first { $0.id == "memory.swap" }
        #expect(i?.severity == .act)               // 9 GB on 16 GB is over half
        #expect(i?.detail.contains("Xcode") == true)
        #expect(!Care.insights(inputs(hourly: [.swapUsed: hours(24) { _ in (0, 1e9, 2e9) }])).contains { $0.area == .memory })
    }

    @Test func throttlingNamesTheUsualSuspect() {
        let ev = (0..<5).map { TalonEvent(time: now - Double($0) * 3600, kind: .throttling,
                                          message: "throttling: P cores at 70% … · busiest: python3.13 93%, Xcode 40%") }
        let i = Care.insights(inputs(events: ev)).first { $0.area == .thermal }
        #expect(i?.title == "The chip slowed itself down 5× this week to stay cool")
        #expect(i?.detail.contains("python3.13") == true)
    }

    @Test func freeSpaceForecastAndFloor() {
        // 150 GB free, falling 5 GB a day → crosses 60 GB in ~18 days.
        let falling = hours(10 * 24) { i in let v = 200 * self.gib - Double(i) / 24 * 5 * self.gib; return (v, v, v) }
        var s = SystemSample(time: now)
        s[.diskFree] = falling.last!.avg
        let f = Care.insights(inputs(hourly: [.diskFree: falling], latest: s)).first { $0.id == "storage.forecast" }
        #expect(f?.severity == .act)
        s[.diskFree] = 40 * gib
        #expect(Care.insights(inputs(latest: s)).contains { $0.id == "storage.low" })
    }

    @Test func unsafeShutdowns() {
        let i = Care.insights(inputs(days: [day(0, written: 0, shutdowns: 20), day(5, written: 0, shutdowns: 21)]))
        #expect(i.contains { $0.area == .stability && $0.severity == .watch })
    }

    @Test func mostSevereFirst() {
        var s = SystemSample(time: now)
        s[.diskFree] = 10 * gib
        let all = Care.insights(inputs(days: [day(0, written: 0)], latest: s))
        #expect(all.first?.severity == .act)
        #expect(all.map(\.severity) == all.map(\.severity).sorted(by: >))
    }

    @Test func daemonServesCare() throws {
        let h = DaemonXPCTests.Harness()
        guard case .care = try h.client.send(.care) else { Issue.record("no care reply"); return }
    }
}
