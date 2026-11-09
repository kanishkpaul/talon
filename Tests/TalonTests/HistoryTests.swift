import Foundation
import Testing
@testable import TalonCore
import TalonDaemon
import TalonIPC
import TalonModel
import TalonSensors
@testable import TalonStore

@Suite struct HealthHistoryTests {
    func day(_ d: String, cycles: Int, nominal: Int, written: UInt64, unsafe: UInt64) -> HealthDay {
        HealthDay(day: d, time: 0,
                  battery: BatteryHealth(cycleCount: cycles, designCapacity: 4629, nominalCapacity: nominal, fullChargeCapacity: nominal,
                                         chargePercent: 80, isCharging: false, externalConnected: false, voltage: 12, amperage: 0,
                                         systemPower: nil, adapterPower: nil, temperature: nil),
                  ssd: SSDHealth(model: "SSD", percentUsed: 0, availableSpare: 100, spareThreshold: 99, criticalWarning: 0,
                                 temperature: 35, bytesWritten: written, bytesRead: 0, powerOnHours: 0, powerCycles: 0,
                                 unsafeShutdowns: unsafe, mediaErrors: 0))
    }

    @Test func daysRoundTripOldestFirst() throws {
        let store = try HistoryStore.inMemory()
        try store.record(day("2026-11-07", cycles: 97, nominal: 4330, written: 12_000_000_000_000, unsafe: 20))
        try store.record(day("2026-11-08", cycles: 98, nominal: 4320, written: 12_050_000_000_000, unsafe: 20))
        try store.record(day("2026-11-08", cycles: 98, nominal: 4319, written: 12_060_000_000_000, unsafe: 21))  // same day: replaced
        let days = try store.healthDays(limit: 10)
        #expect(days.map(\.day) == ["2026-11-07", "2026-11-08"])
        #expect(days.last?.nominalCapacity == 4319)
        #expect(abs((days.last?.batteryHealthPercent ?? 0) - 93.30) < 0.01)
        #expect(try store.healthDays(limit: 1).map(\.day) == ["2026-11-08"])
    }

    @Test func dayStringIsISO() {
        #expect(HealthDay.dayString(Date(timeIntervalSince1970: 0)).count == 10)
    }

    @Test func appHistoryTurnsTotalsIntoRates() throws {
        let store = try HistoryStore.inMemory()
        var st = AppStats(name: "A")
        st.cpuSeconds = 30          // half a core over a minute
        st.bytesWritten = 60 * 1024 * 1024
        st.memory.add(1_073_741_824)
        try store.write(tenSeconds: [], minutes: [], hours: [], appMinutes: [AppBucket(start: 600, period: 60, apps: ["/A.app": st])], appHours: [])
        let pts = try store.appHistory(key: "/A.app", from: 0, to: 10_000, hourly: false)
        #expect(pts.count == 1)
        #expect(abs(pts[0].cpuPercent - 50) < 0.01)
        #expect(abs(pts[0].writeRate - 1_048_576) < 1)
        #expect(pts[0].memoryPeak == Double(1 << 30))
        #expect(try store.appHistory(key: "/B.app", from: 0, to: 10_000, hourly: false).isEmpty)
    }
}

@Suite struct ClockTests {
    @Test func clustersReport() throws {
        _ = ClockSensor.read()   // primes
        usleep(300_000)
        let clocks = try #require(ClockSensor.read())
        #expect(!clocks.isEmpty)
        for c in clocks {
            #expect(c.maxMHz > 500)
            #expect(c.busy >= 0 && c.busy <= 1)
            #expect(c.avgMHz <= c.maxMHz * 1.01)
        }
        #expect(clocks.contains { $0.name.hasPrefix("P") })
    }
}

@Suite(.serialized) struct AppHistoryXPCTests {
    @Test func ownAppHasHistoryBeforeTheFirstCommit() async throws {
        let h = DaemonXPCTests.Harness()
        try await Task.sleep(for: .milliseconds(2600))
        guard case .processes(let snap) = try h.client.send(.processes),
              let me = snap.processes.first(where: { $0.pid == getpid() }),
              let app = snap.apps.first(where: { $0.responsiblePID == me.responsiblePID }) else {
            Issue.record("can't find this test's app"); return
        }
        guard case .appHistory(let pts) = try h.client.send(.appHistory(key: app.key, range: 3600, maxPoints: 100)) else {
            Issue.record("no app history"); return
        }
        #expect(!pts.isEmpty)                  // served from the in-memory minute bucket
        #expect(pts.last!.memoryAverage > 0)
        guard case .healthHistory = try h.client.send(.healthHistory(days: 30)) else { Issue.record("no health history"); return }
    }
}
