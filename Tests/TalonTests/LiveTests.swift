// Tests that read this Mac's real sensors and processes. No root needed.
import Darwin
import Foundation
import Testing
import TalonCore
import TalonDaemon
import TalonIPC
import TalonModel
import TalonSensors

@Suite struct SensorTests {
    @Test func readsOwnProcess() throws {
        let me = try #require(ProcessSensor.read(getpid()))
        #expect(me.footprint > 0)
        #expect(ProcessSensor.allPIDs().contains(getpid()))
        #expect(ProcessSensor.info(getpid())?.uid == getuid())
    }

    @Test func sweepSeesItselfWithRates() throws {
        let s = ProcessSampler()
        _ = s.sweep()
        var x = 0.0
        for i in 0..<3_000_000 { x += sqrt(Double(i)) }   // burn a little CPU between sweeps
        #expect(x > 0)
        let snap = s.sweep()
        let me = try #require(snap.processes.first { $0.pid == getpid() })
        #expect(me.cpuPercent > 0)
        #expect(snap.apps.reduce(0) { $0 + $1.processCount } == snap.readable)
        #expect(snap.sweepSeconds < 0.5)
    }

    @Test func systemSensorsAnswer() throws {
        let m = try #require(SystemSensor.memory())
        #expect(m.physical > 0 && m.used > 0 && m.used <= m.physical + m.compressed)
        #expect(SystemSensor.cpuTicks() != nil)
        let d = try #require(SystemSensor.disk())
        #expect(d.free > 0 && d.free < d.total)
    }

    @Test func systemSampleHasCPUOnSecondReading() {
        let s = SystemSampler()
        _ = s.sample(processes: nil)
        usleep(200_000)
        let sample = s.sample(processes: nil)
        #expect(sample[.cpu].isFinite)
        #expect(sample[.memUsed] > 0)
    }

    @Test func powerFormula() {
        // On battery: V × discharge current. Plugged in: adapter minus what charges the battery.
        #expect(abs((BatterySensorPowerProbe.power(12_300, -291, 0, 492, false) ?? 0) - 3.579) < 0.01)
        #expect(abs((BatterySensorPowerProbe.power(12_300, 1_000, 30_000, nil, true) ?? 0) - 17.7) < 0.01)
        #expect(BatterySensorPowerProbe.power(nil, nil, nil, 5_000, true) == 5)
    }
}

@Suite struct LauncherTests {
    @Test func passesExitCodesThrough() throws {
        let r = try CappedLauncher(memoryCeiling: nil).run(["/bin/sh", "-c", "exit 7"])
        #expect(r.exitCode == 7 && r.signal == nil && !r.hitCeiling)
    }

    @Test func kernelStopsARunawayAtTheCeiling() throws {
        // dd allocates its whole 600 MB block buffer; the 100 MB ceiling must stop it.
        let r = try CappedLauncher(memoryCeiling: 100 << 20).run(["/bin/dd", "if=/dev/zero", "of=/dev/null", "bs=600m", "count=1"])
        #expect(r.signal == SIGKILL)
        #expect(r.exitCode == 137)
        #expect(r.hitCeiling)
    }

    @Test func underTheCeilingRunsNormally() throws {
        let r = try CappedLauncher(memoryCeiling: 200 << 20).run(["/bin/dd", "if=/dev/zero", "of=/dev/null", "bs=20m", "count=1"])
        #expect(r.exitCode == 0 && !r.hitCeiling)
    }

    @Test func unknownCommand() {
        #expect(throws: CappedLauncher.LaunchError.self) { try CappedLauncher(memoryCeiling: nil).run(["no-such-command-talon"]) }
    }

    @Test func findsChildren() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 5 & sleep 5 & wait"]
        try p.run()
        defer { p.terminate(); kill(-p.processIdentifier, SIGTERM) }
        usleep(300_000)
        let kids = ProcessTree.descendants(of: p.processIdentifier)
        #expect(kids.count >= 2)
        for k in kids { kill(k, SIGTERM) }
    }
}

/// The real daemon logic, over real XPC, through an anonymous listener — no launchd, no root.
@Suite(.serialized) struct DaemonXPCTests {
    final class Harness {
        let daemon: Daemon
        let listener = NSXPCListener.anonymous()
        let delegate: ListenerDelegate
        let client: TalonClient

        init() {
            daemon = Daemon(options: .init(allowedUID: getuid(), databasePath: nil, flushInterval: 2))
            delegate = ListenerDelegate(daemon: daemon)
            listener.delegate = delegate
            listener.resume()
            client = TalonClient(listenerEndpoint: listener.endpoint)
            daemon.start()
        }

        deinit {
            daemon.shutdown()
            listener.invalidate()
        }
    }

    func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        return p
    }

    @Test func endToEnd() async throws {
        let h = Harness()
        guard case .hello(let v, _) = try h.client.send(.hello) else { Issue.record("no hello"); return }
        #expect(v == talonProtocolVersion)

        try await Task.sleep(for: .milliseconds(2600))   // a couple of 1 Hz ticks

        guard case .status(let st) = try h.client.send(.status) else { Issue.record("no status"); return }
        #expect(st.allowedUID == getuid())
        #expect(st.readableProcesses > 0)
        #expect(st.latest?[.memUsed] ?? 0 > 0)

        guard case .processes(let snap) = try h.client.send(.processes) else { Issue.record("no processes"); return }
        #expect(snap.processes.contains { $0.pid == getpid() })

        guard case .history(let hist) = try h.client.send(.history(series: .cpu, range: 600, maxPoints: 100)) else {
            Issue.record("no history"); return
        }
        #expect(hist.tier == .live)
        #expect(hist.points.count >= 2)
    }

    @Test func freezeThawAndShutdownSafety() async throws {
        let h = Harness()
        let sleeper = try spawnSleeper()
        defer { sleeper.terminate() }
        let pid = sleeper.processIdentifier
        usleep(100_000)

        guard case .ok = try h.client.send(.freeze(pid: pid)) else { Issue.record("freeze failed"); return }
        #expect(ProcessSensor.info(pid)?.stopped == true)
        guard case .status(let st) = try h.client.send(.status) else { return }
        #expect(st.frozen == [pid])

        guard case .ok = try h.client.send(.thaw(pid: pid)) else { Issue.record("thaw failed"); return }
        #expect(ProcessSensor.info(pid)?.stopped == false)

        // Frozen when the daemon goes away → resumed by shutdown.
        _ = try h.client.send(.freeze(pid: pid))
        #expect(ProcessSensor.info(pid)?.stopped == true)
        h.daemon.shutdown()
        #expect(ProcessSensor.info(pid)?.stopped == false)
    }

    @Test func refusalsComeBackAsTypedErrors() throws {
        let h = Harness()
        #expect(throws: TalonError.self) { try h.client.send(.freeze(pid: 1)) }
        do { _ = try h.client.send(.capMemory(pid: 1, bytes: 1 << 30)) } catch { #expect(error.code == .refused) }
        // A different caller uid is refused by the daemon itself, before any lookup.
        if case .error(let e) = h.daemon.handle(.freeze(pid: getpid()), callerUID: getuid() + 1) {
            #expect(e.code == .refused)
        } else {
            Issue.record("foreign caller was not refused")
        }
    }

    @Test func eventsAreRecorded() throws {
        let h = Harness()
        let sleeper = try spawnSleeper()
        defer { sleeper.terminate() }
        usleep(100_000)
        _ = try h.client.send(.freeze(pid: sleeper.processIdentifier))
        _ = try h.client.send(.thaw(pid: sleeper.processIdentifier))
        guard case .events(let ev) = try h.client.send(.events(range: 60, limit: 10)) else { Issue.record("no events"); return }
        #expect(ev.map(\.kind).contains(.frozen))
        #expect(ev.map(\.kind).contains(.thawed))
        #expect(ev.map(\.kind).contains(.daemonStarted))
    }
}
