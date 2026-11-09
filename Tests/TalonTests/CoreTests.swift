import Darwin
import Foundation
import Testing
@testable import TalonCore
import TalonModel

@Suite struct AccumulatorTests {
    @Test func skipsNaN() {
        var a = Accumulator()
        for v in [3.0, .nan, 1, 5, .infinity] { a.add(v) }
        #expect(a.count == 3)
        #expect(a.min == 1 && a.max == 5 && a.avg == 3)
    }

    @Test func emptyIsNaN() {
        let a = Accumulator()
        #expect(a.avg.isNaN && a.minOrNaN.isNaN && a.maxOrNaN.isNaN)
    }
}

@Suite struct TierTests {
    func sample(_ t: TimeInterval, cpu: Double) -> SystemSample {
        var s = SystemSample(time: t)
        s[.cpu] = cpu
        return s
    }

    @Test func rollsBucketsOnBoundaries() {
        let tier = SystemTier(period: 10)
        for t in 0..<25 { tier.add(sample(1000 + Double(t), cpu: Double(t))) }
        let done = tier.drain()
        #expect(done.map(\.start) == [1000, 1010])
        #expect(done[0][.cpu].avg == 4.5)
        #expect(done[0][.cpu].min == 0 && done[0][.cpu].max == 9)
        #expect(done[0][.memUsed].count == 0)          // never reported → NaN in storage
        #expect(tier.pending.map(\.start) == [1020])  // in progress
        #expect(tier.drain(includePartial: true).map(\.start) == [1020])
        #expect(tier.drain(includePartial: true).isEmpty)
    }

    @Test func appTierTurnsRatesIntoTotals() {
        let tier = AppTier(period: 60)
        let app = AppUsage(key: "/Applications/Xcode.app", name: "Xcode", responsiblePID: 10, processCount: 3,
                           footprint: 1 << 30, cpuPercent: 50, diskWriteRate: 1000)
        for t in 0..<4 { tier.add([app], at: 120 + Double(t), interval: 1) }
        let b = tier.drain(includePartial: true)
        let st = try! #require(b.first?.apps["/Applications/Xcode.app"])
        #expect(st.cpuSeconds == 2.0)          // 50 % of a core for 4 s
        #expect(st.bytesWritten == 4000)
        #expect(st.memory.max == Double(1 << 30))
    }

    @Test func foldsTheLongTailIntoOther() {
        let tier = AppTier(period: 60, keep: 2)
        let apps = (0..<6).map { i in
            AppUsage(key: "app\(i)", name: "App \(i)", responsiblePID: Int32(i), processCount: 1,
                     footprint: UInt64(i) << 20, cpuPercent: Double(i), diskWriteRate: 0)
        }
        tier.add(apps, at: 0, interval: 1)
        let b = tier.drain(includePartial: true)[0]
        // top 2 by cpu = app5, app4; by memory = app5, app4; by writes (all 0) = some 2
        #expect(b.apps["app5"] != nil && b.apps["app4"] != nil)
        let other = try! #require(b.apps[AppTier.otherKey])
        let kept = b.apps.keys.filter { $0 != AppTier.otherKey }
        let total = (0..<6).reduce(0.0) { $0 + Double($1) / 100 }
        let keptCPU = kept.reduce(0.0) { $0 + b.apps[$1]!.cpuSeconds }
        #expect(abs(other.cpuSeconds + keptCPU - total) < 1e-9)   // nothing lost
    }
}

@Suite struct RingBufferTests {
    @Test func wrapsOldestFirst() {
        var r = RingBuffer<Int>(capacity: 3)
        #expect(r.last == nil && r.elements.isEmpty)
        for i in 1...5 { r.append(i) }
        #expect(r.elements == [3, 4, 5])
        #expect(r.last == 5 && r.count == 3)
    }
}

@Suite struct PolicyTests {
    let policy = TargetPolicy(allowedUID: 501, selfPID: 999)

    @Test(arguments: [
        (501, TargetFacts(pid: 4242, uid: 501, name: "python3"), true),
        (0, TargetFacts(pid: 4242, uid: 501, name: "python3"), true),           // root caller (sudo talon) is fine
        (502, TargetFacts(pid: 4242, uid: 501, name: "python3"), false),        // another user
        (501, TargetFacts(pid: 4242, uid: 0, name: "mds_stores"), false),       // root-owned target
        (501, TargetFacts(pid: 1, uid: 501, name: "launchd"), false),           // pid 1
        (501, TargetFacts(pid: 0, uid: 501, name: "kernel_task"), false),
        (501, TargetFacts(pid: 999, uid: 501, name: "talond"), false),          // itself
        (501, TargetFacts(pid: 300, uid: 501, name: "WindowServer"), false),    // protected name
        (501, TargetFacts(pid: 301, uid: 501, name: "loginwindow"), false),
    ] as [(uid_t, TargetFacts, Bool)])
    func decides(_ caller: uid_t, _ target: TargetFacts, _ allowed: Bool) {
        #expect((policy.check(callerUID: caller, target: target) == .allow) == allowed)
    }

    @Test func missingTargetIsRefused() {
        #expect(policy.check(callerUID: 501, target: nil) == .refuse("no such process"))
    }

    @Test func enforcerRefusesBeforeTouchingAnything() {
        let e = Enforcer(policy: policy) { pid in TargetFacts(pid: pid, uid: 0, name: "root-thing") }
        guard case .refused = e.freeze(caller: 501, pid: 4242) else { Issue.record("should refuse"); return }
        guard case .refused = e.capMemory(caller: 501, pid: 4242, bytes: 1 << 30) else { Issue.record("should refuse"); return }
    }

    @Test func tinyCeilingsAreRefused() {
        let e = Enforcer(policy: policy) { pid in TargetFacts(pid: pid, uid: 501, name: "x") }
        guard case .refused = e.capMemory(caller: 501, pid: 4242, bytes: 1 << 20) else { Issue.record("should refuse"); return }
    }
}
