import Foundation
import Testing
@testable import TalonCore
import TalonModel

/// Builds process lists for one app ("Xcode", key /X.app, responsible pid 100) plus a stranger.
struct World {
    var procs: [ProcessSample] = []
    var apps: [AppUsage] = []

    static func app(mem: [UInt64], cpu: Double = 0, writes: Double = 0) -> World {
        var w = World()
        for (i, m) in mem.enumerated() {
            w.procs.append(ProcessSample(pid: 100 + Int32(i), startTime: 1, responsiblePID: 100, uid: 501, name: "X\(i)",
                                         footprint: m, cpuPercent: cpu / Double(mem.count), diskWriteRate: writes / Double(mem.count),
                                         diskWrittenTotal: 0, parentPID: i == 0 ? 1 : 100))
        }
        w.procs.append(ProcessSample(pid: 900, startTime: 1, responsiblePID: 900, uid: 501, name: "other",
                                     footprint: 1 << 40, cpuPercent: 400, diskWriteRate: 1e9, diskWrittenTotal: 0, parentPID: 1))
        w.apps = [AppUsage(key: "/X.app", name: "Xcode", responsiblePID: 100, processCount: mem.count, footprint: mem.reduce(0, +),
                           cpuPercent: cpu, diskWriteRate: writes),
                  AppUsage(key: "/other", name: "other", responsiblePID: 900, processCount: 1, footprint: 1 << 40, cpuPercent: 400, diskWriteRate: 1e9)]
        return w
    }
}

let GB: UInt64 = 1 << 30

@Suite struct CeilingEngineTests {
    func rule(_ s: Strictness, mem: UInt64? = 4 * GB, cpu: Double? = nil, grace: TimeInterval = 5) -> Ceiling {
        Ceiling(target: .app(key: "/X.app"), label: "Xcode", memory: mem, cpu: cpu, strictness: s, grace: grace, quitGrace: 10)
    }

    /// Run the engine over `seconds` ticks of the same world, collecting every decision.
    func run(_ e: inout CeilingEngine, _ r: Ceiling, _ w: World, from t0: TimeInterval = 0, seconds: Int) -> [CeilingEngine.Decision] {
        (0..<seconds).flatMap { e.evaluate([r], processes: w.procs, apps: w.apps, now: t0 + Double($0)) }
    }

    @Test func resolvesTargets() {
        let w = World.app(mem: [GB, GB, GB])
        #expect(CeilingEngine.resolve(.app(key: "/X.app"), processes: w.procs, apps: w.apps).map(\.pid) == [100, 101, 102])
        #expect(CeilingEngine.resolve(.process(pid: 101, start: 1), processes: w.procs, apps: w.apps).map(\.pid) == [101])
        #expect(CeilingEngine.resolve(.process(pid: 101, start: 2), processes: w.procs, apps: w.apps).isEmpty)  // pid reused
        #expect(Set(CeilingEngine.resolve(.tree(pid: 100, start: 1), processes: w.procs, apps: w.apps).map(\.pid)) == [100, 101, 102])
    }

    @Test func underTheWarnLineDoesNothing() {
        var e = CeilingEngine()
        #expect(run(&e, rule(.quit), .app(mem: [GB, GB]), seconds: 20).isEmpty)
        #expect(e.status([rule(.quit)]).first?.phase == .ok)
    }

    @Test func warnsOnceWhenApproaching() {
        var e = CeilingEngine()
        let r = rule(.pause)
        let d = run(&e, r, .app(mem: [2 * GB, UInt64(1.7 * Double(GB))]), seconds: 10)   // 3.7 of 4 GB
        #expect(d.count == 1)
        guard case .notify = d.first else { Issue.record("expected a notification"); return }
        #expect(e.status([r]).first?.phase == .approaching)
    }

    @Test func graceAbsorbsASpike() {
        var e = CeilingEngine()
        let r = rule(.quit, grace: 5)
        var d = run(&e, r, .app(mem: [5 * GB]), seconds: 3)            // over for 3 s
        d += run(&e, r, .app(mem: [GB]), from: 3, seconds: 5)           // then back down
        #expect(!d.contains { if case .terminate = $0 { true } else { false } })
    }

    @Test(arguments: [Strictness.watch, .warn, .ask, .slowDown, .pause, .quit])
    func eachRungActsOnceAfterGrace(_ s: Strictness) {
        var e = CeilingEngine()
        let r = rule(s, grace: 5)
        let w = World.app(mem: [3 * GB, 2 * GB])
        let early = run(&e, r, w, seconds: 5)                            // t = 0…4: inside grace
        #expect(early.isEmpty)
        let acted = run(&e, r, w, from: 5, seconds: 3)                   // t = 5…7
        let expected: CeilingEngine.Decision = switch s {
        case .watch: .record(r.id, "Xcode crossed its ceiling: 5.00 GB of 4.00 GB memory")
        case .warn: .notify(r.id, "Xcode crossed its ceiling: 5.00 GB of 4.00 GB memory")
        case .ask: .ask(r.id, "Xcode crossed its ceiling: 5.00 GB of 4.00 GB memory")
        case .slowDown: .throttle(r.id, [100, 101], on: true)
        case .pause: .pause(r.id, [100, 101])
        case .quit: .terminate(r.id, [100, 101])
        case .hardCap: .record(r.id, "")
        }
        #expect(acted == [expected])
        #expect(e.status([r]).first?.phase == (s == .ask ? .asking : .enforced))
    }

    @Test func quitEscalatesToKill() {
        var e = CeilingEngine()
        let r = rule(.quit, grace: 0)
        let d = run(&e, r, .app(mem: [5 * GB]), seconds: 12)
        #expect(d == [.terminate(r.id, [100]), .kill(r.id, [100])])
    }

    @Test func hardCapCapsEveryProcessAndStopsTheLargest() {
        var e = CeilingEngine()
        let r = rule(.hardCap, grace: 0)
        var d = e.evaluate([r], processes: World.app(mem: [GB, GB]).procs, apps: World.app(mem: [GB, GB]).apps, now: 0)
        #expect(d == [.kernelCap(r.id, [100, 101], bytes: 4 * GB)])
        // A third process appears and the sum goes over.
        let w = World.app(mem: [GB, 3 * GB, GB])
        d = e.evaluate([r], processes: w.procs, apps: w.apps, now: 1)
        #expect(d == [.kernelCap(r.id, [102], bytes: 4 * GB), .kill(r.id, [101])])
        // Still over half a second later: no second kill yet.
        #expect(e.evaluate([r], processes: w.procs, apps: w.apps, now: 1.5).isEmpty)
    }

    @Test func hardCapOnCPUFallsBackToThrottling() {
        var e = CeilingEngine()
        let r = rule(.hardCap, mem: nil, cpu: 100, grace: 0)
        let d = run(&e, r, .app(mem: [GB], cpu: 250), seconds: 1)
        #expect(d == [.throttle(r.id, [100], on: true)])
    }

    @Test func throttlingLiftsOnlyAfterTheReleaseDelay() {
        var e = CeilingEngine(release: 30)
        let r = rule(.slowDown, mem: nil, cpu: 100, grace: 0)
        _ = run(&e, r, .app(mem: [GB], cpu: 300), seconds: 1)
        let calm = World.app(mem: [GB], cpu: 10)
        let early = run(&e, r, calm, from: 1, seconds: 29)
        #expect(early.isEmpty)                                          // still throttled
        let later = run(&e, r, calm, from: 30, seconds: 3)
        #expect(later.contains(.throttle(r.id, [100], on: false)))
        #expect(e.status([r]).first?.phase == .ok)
    }

    @Test func newProcessesJoinAThrottledTarget() {
        var e = CeilingEngine()
        let r = rule(.slowDown, mem: nil, cpu: 100, grace: 0)
        _ = run(&e, r, .app(mem: [GB], cpu: 300), seconds: 1)
        let d = e.evaluate([r], processes: World.app(mem: [GB, GB], cpu: 300).procs, apps: World.app(mem: [GB, GB], cpu: 300).apps, now: 2)
        #expect(d == [.throttle(r.id, [101], on: true)])
    }

    @Test func fastLaneDoesNotForgetCPU() {
        var e = CeilingEngine()
        let r = rule(.watch, mem: nil, cpu: 100, grace: 0)
        _ = e.evaluate([r], processes: World.app(mem: [GB], cpu: 300).procs, apps: World.app(mem: [GB], cpu: 300).apps, now: 0)
        _ = e.evaluate([r], processes: World.app(mem: [GB], cpu: 0).procs, apps: World.app(mem: [GB], cpu: 0).apps, now: 0.25, memoryOnly: true)
        #expect(e.status([r]).first?.usage.cpu == 300)
    }

    @Test func answersResolveTheAsk() {
        var e = CeilingEngine()
        let r = rule(.ask, grace: 0)
        let w = World.app(mem: [5 * GB])
        _ = run(&e, r, w, seconds: 1)
        #expect(e.status([r]).first?.phase == .asking)
        let (d, raised) = e.answer(r, .raise(by: 1.5), now: 1)
        #expect(raised?.memory == 6 * GB)
        guard case .record = d.first else { Issue.record("expected a record"); return }
        // Under the raised ceiling (5 of 6 GB, past the 90 % line? no: 83 %) nothing more happens.
        #expect(run(&e, raised!, w, from: 2, seconds: 10).isEmpty)

        var e2 = CeilingEngine()
        _ = run(&e2, r, w, seconds: 1)
        #expect(e2.answer(r, .quit, now: 1).decisions == [.terminate(r.id, [100])])
        // A quit answer escalates like the Quit rung.
        #expect(run(&e2, r, w, from: 11, seconds: 1) == [.kill(r.id, [100])])
    }

    @Test func ephemeralTargetsExpire() {
        var e = CeilingEngine()
        let r = Ceiling(target: .tree(pid: 555, start: 9), label: "train.py", memory: GB, strictness: .quit)
        #expect(e.evaluate([r], processes: [], apps: [], now: 0) == [.expired(r.id)])
    }

    @Test func disablingReleasesThrottles() {
        var e = CeilingEngine()
        var r = rule(.slowDown, mem: nil, cpu: 100, grace: 0)
        _ = run(&e, r, .app(mem: [GB], cpu: 300), seconds: 1)
        r.enabled = false
        #expect(run(&e, r, .app(mem: [GB], cpu: 300), from: 1, seconds: 1) == [.throttle(r.id, [100], on: false)])
        #expect(e.status([r]).first?.phase == .disabled)
    }

    @Test func removingReleasesThrottles() {
        var e = CeilingEngine()
        let r = rule(.slowDown, mem: nil, cpu: 100, grace: 0)
        _ = run(&e, r, .app(mem: [GB], cpu: 300), seconds: 1)
        #expect(e.remove(r.id) == [.throttle(r.id, [100], on: false)])
        #expect(e.remove(r.id).isEmpty)
    }

    @Test func fastLaneTracksMemoryCeilingsOnly() {
        var e = CeilingEngine()
        let m = rule(.watch)
        let c = Ceiling(target: .app(key: "/other"), label: "other", cpu: 1000, strictness: .watch)
        let w = World.app(mem: [GB])
        _ = e.evaluate([m, c], processes: w.procs, apps: w.apps, now: 0)
        #expect(e.fastLanePIDs([m, c]) == [100])
    }

    @Test func strictnessParsesCLINames() {
        #expect(Strictness(name: "slow") == .slowDown)
        #expect(Strictness(name: "HARD") == .hardCap)
        #expect(Strictness(name: "nope") == nil)
        #expect(Strictness.allCases.sorted() == Strictness.allCases)
    }
}
