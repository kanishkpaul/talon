import ArgumentParser
import Darwin
import Foundation
import TalonCore
import TalonIPC
import TalonModel
import TalonSensors

@main
struct Talon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "talon",
        abstract: "A firm grip on your Mac: ceilings, health and history.",
        version: "talon \(talonVersion) (protocol v\(talonProtocolVersion))",
        subcommands: [Status.self, Top.self, Health.self, Run.self, CeilingCommand.self, Cap.self, Limit.self, Freeze.self,
                      Thaw.self, History.self, Apps.self, Events.self, Daemon.self],
        defaultSubcommand: Status.self
    )
}

// MARK: - Shared

struct JSONFlag: ParsableArguments {
    @Flag(name: .long, help: "Print JSON instead of a table.") var json = false
}

extension SystemSeries: ExpressibleByArgument {
    public init?(argument: String) {
        let flat = argument.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased()
        guard let match = SystemSeries.allCases.first(where: { $0.rawValue.lowercased() == flat }) else { return nil }
        self = match
    }
    public static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

extension AppMetric: ExpressibleByArgument {}

extension Strictness: ExpressibleByArgument {
    public init?(argument: String) { self.init(name: argument) }
    public static var allValueStrings: [String] { ["watch", "warn", "ask", "slow", "pause", "quit", "hard"] }
}

/// `200%`, `150` → percent of one core (or a 0–100 fraction for --warn).
struct Percent: ExpressibleByArgument {
    var value: Double
    init?(argument: String) {
        guard let v = Double(argument.trimmingCharacters(in: CharacterSet(charactersIn: "% "))), v > 0, v.isFinite else { return nil }
        value = v
    }
}

struct TimeRange: ExpressibleByArgument {
    var seconds: TimeInterval
    init?(argument: String) {
        guard let s = TimeSpan.parse(argument) else { return nil }
        seconds = s
    }
}

struct Bytes: ExpressibleByArgument {
    var value: UInt64
    init?(argument: String) {
        guard let v = try? ByteSize.parse(argument) else { return nil }
        value = v
    }
}

/// Runtime failures print one line and exit — no usage banner. 69 = EX_UNAVAILABLE.
func fail(_ e: TalonError) -> ExitCode {
    stderr(Style.red("talon: ") + e.message)
    switch e.code {
    case .unreachable, .timeout, .versionMismatch: return ExitCode(69)
    default: return ExitCode(1)
    }
}

func daemonClient() throws -> TalonClient {
    switch TalonClient.connect() {
    case .success(let c): return c
    case .failure(let e): throw fail(e)
    }
}

func request(_ r: TalonRequest) throws -> TalonReply {
    let client = try daemonClient()
    do { return try client.send(r) } catch { throw fail(error) }
}

// MARK: - status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "This Mac right now, at a glance.")
    @OptionGroup var output: JSONFlag

    func run() throws {
        let processes = ProcessSampler()
        let system = SystemSampler(temperatureEvery: 1)
        _ = processes.sweep()
        _ = system.sample(processes: nil)
        usleep(500_000)
        let snap = processes.sweep()
        let s = system.sample(processes: snap)
        let mem = SystemSensor.memory()
        let disk = SystemSensor.disk()
        let daemon = try? TalonClient.connect(timeout: 1).get()
        let ds: DaemonStatus? = daemon.flatMap { c in
            if case .status(let st)? = try? c.send(.status) { return st } else { return nil }
        }

        if output.json {
            struct Out: Encodable { var sample: SystemSample; var memory: MemoryInfo?; var disk: DiskSpace?; var daemon: DaemonStatus?; var endpoint: String? }
            try JSON.print(Out(sample: s, memory: mem, disk: disk, daemon: ds, endpoint: daemon?.endpoint.rawValue))
            return
        }

        func row(_ label: String, _ value: String) { print(pad(Style.dim(label), 14) + value) }
        print(Style.bold("talon") + Style.dim(" · \(Host.current().localizedName ?? "this Mac")"))
        row("CPU", "\(meter(s[.cpu] / 100)) \(percent(s[.cpu]))")
        if let m = mem {
            let p: Style.Verdict = m.pressure == .normal ? .good : m.pressure == .warning ? .watch : .bad
            row("Memory", "\(meter(Double(m.used) / Double(m.physical))) \(ByteSize.format(m.used)) of \(ByteSize.format(m.physical)) · pressure \(Style.verdict(p, m.pressure.label))")
            row("Swap", ByteSize.format(m.swapUsed) + Style.dim(" · compressed \(ByteSize.format(m.compressed))"))
        }
        let tp = ThermalPressure(rawValue: Int(s[.thermalPressure].isFinite ? s[.thermalPressure] : 0)) ?? .nominal
        row("Thermal", Style.verdict(tp == .nominal ? .good : tp == .moderate ? .watch : .bad, tp.label)
            + Style.dim(" · CPU die \(SystemSeries.cpuTemp.format(s[.cpuTemp]))"))
        if s[.systemPower].isFinite || s[.batteryCharge].isFinite {
            row("Power", "\(SystemSeries.systemPower.format(s[.systemPower])) · battery \(percent(s[.batteryCharge]))")
        }
        if let d = disk {
            let low = d.free < 60 << 30
            row("Free space", Style.verdict(low ? .watch : .good, ByteSize.format(d.free)) + Style.dim(" of \(ByteSize.format(d.total))"))
        }
        row("SSD writes", SystemSeries.diskWriteRate.format(s[.diskWriteRate]) + Style.dim(" (processes talon can read)"))
        if let ds, let daemon {
            row("talond", Style.green("running") + Style.dim(" as \(ds.euid == 0 ? "root daemon" : "user agent") (\(daemon.endpoint.rawValue)) · \(percent(ds.ownCPUPercent, digits: 2)) CPU · \(ByteSize.format(ds.ownFootprint)) · history \(ByteSize.format(ds.databaseBytes))"))
        } else {
            row("talond", Style.yellow("not running") + Style.dim(" — `make agent` (no admin) or `sudo make install`"))
        }
    }
}

// MARK: - top

struct Top: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "What's using memory, CPU and the SSD — grouped by app.")

    enum SortKey: String, ExpressibleByArgument, CaseIterable { case mem, cpu, disk }

    @Option(name: .shortAndLong, help: "Rows to show.") var n = 15
    @Option(name: .long, help: "Sort by mem, cpu or disk.") var sort: SortKey = .mem
    @Flag(name: .long, help: "One row per process instead of per app.") var procs = false
    @Flag(name: .shortAndLong, help: "Refresh every 2 seconds until Ctrl-C.") var watch = false
    @OptionGroup var output: JSONFlag

    func run() throws {
        let sampler = ProcessSampler()
        _ = sampler.sweep()
        repeat {
            sleep(watch ? 2 : 1)
            let snap = sampler.sweep()
            if output.json { try JSON.print(snap); return }
            if watch { print("\u{1B}[H\u{1B}[2J", terminator: "") }
            render(snap)
        } while watch
    }

    func render(_ snap: ProcessSnapshot) {
        let rows: [(name: String, sub: String, mem: UInt64, cpu: Double, disk: Double)]
        if procs {
            rows = snap.processes.map { ($0.name, "\($0.pid)", $0.footprint, $0.cpuPercent, $0.diskWriteRate) }
        } else {
            rows = snap.apps.map { ($0.name, "\($0.processCount)", $0.footprint, $0.cpuPercent, $0.diskWriteRate) }
        }
        let sorted = rows.sorted {
            switch sort { case .mem: $0.mem > $1.mem; case .cpu: $0.cpu > $1.cpu; case .disk: $0.disk > $1.disk }
        }
        var t = Table(headers: [procs ? "PROCESS" : "APP", procs ? "PID" : "PROCS", "MEMORY", "CPU", "WRITES/s"], right: [1, 2, 3, 4])
        for r in sorted.prefix(n) {
            t.rows.append([truncate(r.name, 32), r.sub, ByteSize.format(r.mem), String(format: "%.1f%%", r.cpu),
                           r.disk >= 1 ? ByteSize.format(r.disk) : Style.dim("0")])
        }
        print(t.render())
        let note = snap.denied > 0 ? " · \(snap.denied) system processes need talond as root to read" : ""
        print(Style.dim("\(snap.readable) processes · sweep \(String(format: "%.1f", snap.sweepSeconds * 1000)) ms\(note)"))
    }
}

// MARK: - health

struct Health: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Battery, SSD, thermals, memory and disk — read straight from the hardware.")
    @Flag(name: .long, help: "List every temperature sensor.") var sensors = false
    @OptionGroup var output: JSONFlag

    func run() throws {
        let r = HealthProbe.report()
        if output.json { try JSON.print(r); return }

        func section(_ title: String) { print("\n" + Style.bold(title)) }
        func row(_ label: String, _ value: String) { print("  " + pad(Style.dim(label), 22) + value) }

        if let b = r.battery {
            section("Battery")
            let health = b.rawHealthPercent
            row("Health (raw)", Style.verdict(health >= 85 ? .good : health >= 80 ? .watch : .bad, String(format: "%.1f%%", health))
                + Style.dim(" · nominal \(b.nominalCapacity) of \(b.designCapacity) mAh design"))
            row("Cycles", Style.verdict(b.cycleCount < 800 ? .good : b.cycleCount < 1000 ? .watch : .bad, "\(b.cycleCount)")
                + Style.dim(" of ~1,000 rated (\(b.cycleCount / 10)%)"))
            row("Charge", "\(b.chargePercent)% · " + (b.externalConnected ? (b.isCharging ? "charging" : "plugged in, not charging") : "on battery"))
            if let w = b.systemPower { row("System power", String(format: "%.1f W", w) + (b.adapterPower.map { Style.dim(String(format: " · %.1f W from charger", $0)) } ?? "")) }
            if let t = b.temperature { row("Temperature", String(format: "%.1f °C", t)) }
        }
        if let s = r.ssd {
            section("SSD" + Style.dim(" · \(s.model)"))
            row("Wear", Style.verdict(s.percentUsed < 10 ? .good : s.percentUsed < 80 ? .watch : .bad, "\(s.percentUsed)%")
                + Style.dim(" · spare \(s.availableSpare)% (threshold \(s.spareThreshold)%)"))
            row("Written / read", "\(ByteSize.format(s.bytesWritten)) / \(ByteSize.format(s.bytesRead))")
            row("Media errors", Style.verdict(s.mediaErrors == 0 ? .good : .bad, "\(s.mediaErrors)")
                + (s.criticalWarning != 0 ? Style.red(" · critical warning 0x\(String(s.criticalWarning, radix: 16))") : ""))
            row("Unsafe shutdowns", "\(s.unsafeShutdowns)" + Style.dim(" · \(s.powerCycles) power cycles"))
            row("Temperature", "\(s.temperature) °C")
        }
        section("Thermals")
        let p = r.thermal.pressure
        row("Pressure", p.map { Style.verdict($0 == .nominal ? .good : $0 == .moderate ? .watch : .bad, $0.label) } ?? "unavailable")
        if let c = r.thermal.cpuMax { row("CPU die (hottest)", String(format: "%.1f °C", c)) }
        if let c = r.thermal.soc2Max { row("PMU2 die (hottest)", String(format: "%.1f °C", c)) }
        if let h = r.thermal.hottest { row("Hottest sensor", "\(h.name) " + String(format: "%.1f °C", h.celsius)) }
        row("Sensors", "\(r.thermal.sensors.count)")
        if sensors {
            for (k, v) in r.thermal.sensors.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
                print("    " + pad(k, 24) + String(format: "%5.1f °C", v))
            }
        }
        if let m = r.memory {
            section("Memory")
            row("Used", "\(ByteSize.format(m.used)) of \(ByteSize.format(m.physical)) · pressure \(m.pressure.label)")
            row("App / wired / compr", "\(ByteSize.format(m.app)) / \(ByteSize.format(m.wired)) / \(ByteSize.format(m.compressed))")
            row("Swap", Style.verdict(m.swapUsed < 2 << 30 ? .good : .watch, ByteSize.format(m.swapUsed))
                + Style.dim(" — swap is SSD writes; watch it grow"))
        }
        if let d = r.disk {
            section("Disk")
            row("Free", Style.verdict(d.free >= 60 << 30 ? .good : .watch, ByteSize.format(d.free)) + Style.dim(" of \(ByteSize.format(d.total))"))
        }
        if !r.unavailable.isEmpty {
            section("Unavailable")
            r.unavailable.forEach { print("  " + Style.yellow($0)) }
        }
    }
}

// MARK: - run

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command under a kernel-enforced memory ceiling (no admin needed).",
        discussion: """
        The kernel stops the process if it crosses the ceiling — it never gets past it.
        Example: talon run --mem 6G -- python train.py
        Ceilings are per process; children the command spawns are watched and reported, and get
        their own budget in a later release.
        """)

    @Option(name: .long, help: "Kernel memory ceiling on the command itself, e.g. 300M, 6G.") var mem: Bytes?
    @Option(name: .long, help: "Memory budget for the command and every process it spawns, e.g. 10G.") var treeMem: Bytes?
    @Option(name: .long, help: "CPU budget for the whole tree, e.g. 200% (two cores).") var cpu: Percent?
    @Option(name: .long, help: "What the budget does when crossed: watch, warn, slow, pause, quit, hard.") var strict: Strictness = .quit
    @Option(name: .long, help: "How long the tree may stay over its budget before talon acts.") var grace = TimeRange(argument: "3s")!
    @Flag(name: .long, help: "Always print a summary (peak memory, runtime) when the command ends.") var report = false
    @Argument(parsing: .postTerminator, help: "The command, after --.") var command: [String] = []

    func validate() throws {
        if command.isEmpty { throw ValidationError("give the command after --, e.g. talon run --mem 6G -- python train.py") }
        if let m = mem, m.value < 16 << 20 { throw ValidationError("a ceiling under 16 MB would stop almost anything instantly") }
        if let m = treeMem, m.value < 16 << 20 { throw ValidationError("a budget under 16 MB would stop almost anything instantly") }
        if strict == .ask { throw ValidationError("`ask` needs the app; for talon run use watch, warn, slow, pause, quit or hard") }
    }

    func run() throws {
        let name0 = (command[0] as NSString).lastPathComponent
        let budget: Ceiling? = treeMem == nil && cpu == nil ? nil
            : Ceiling(target: .tree(pid: 0, start: 0), label: name0, memory: treeMem?.value, cpu: cpu?.value,
                      strictness: strict, grace: grace.seconds, quitGrace: 5)
        let launcher = CappedLauncher(memoryCeiling: mem?.value, budget: budget) { msg in
            stderr(Style.yellow("talon: ") + msg)
        }
        let r: CappedLauncher.Result
        do { r = try launcher.run(command) } catch { stderr("talon: \(error)"); throw ExitCode(127) }
        let name = (command[0] as NSString).lastPathComponent
        if r.hitCeiling, let m = mem {
            stderr(Style.red("talon: \(name) hit its \(ByteSize.format(m.value)) memory ceiling and was stopped by the kernel")
                   + Style.dim(" (last seen at \(ByteSize.format(r.peakFootprint)) after \(TimeSpan.format(r.seconds)))"))
        } else if report {
            let how = r.signal.map { "killed by signal \($0)" } ?? "exited \(r.exitCode)"
            stderr(Style.dim("talon: \(name) \(how) · peak \(ByteSize.format(r.peakFootprint))"
                + (r.peakTreeFootprint > r.peakFootprint ? " (with children \(ByteSize.format(r.peakTreeFootprint)))" : "")
                + " · \(TimeSpan.format(r.seconds))"))
        }
        throw ExitCode(r.exitCode)
    }
}

// MARK: - ceilings

struct CeilingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ceiling",
        abstract: "Put a ceiling on an app or process, and choose how hard talon holds the line.",
        discussion: """
        Strictness, from gentlest: watch · warn · ask · slow · pause · quit · hard
        Examples:
          talon ceiling add Xcode --mem 8G --strict ask
          talon ceiling add Safari --cpu 150% --strict slow
          talon ceiling add 4242 --mem 2G --strict quit --grace 10s
        """,
        subcommands: [List.self, Add.self, Remove.self, Toggle.self, Answer.self],
        defaultSubcommand: List.self)

    static func fetch() throws -> ([Ceiling], [CeilingStatus]) {
        guard case .ceilings(let rules, let states) = try request(.ceilings) else { return ([], []) }
        return (rules, states)
    }

    /// An id prefix (as `list` prints it) or a label.
    static func find(_ ref: String, in rules: [Ceiling]) throws -> Ceiling {
        let matches = rules.filter { $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) || $0.label.lowercased() == ref.lowercased() }
        guard matches.count == 1 else {
            throw fail(TalonError(.notFound, matches.isEmpty ? "no ceiling matches \"\(ref)\" — see `talon ceiling list`" : "\"\(ref)\" matches several ceilings; use the id"))
        }
        return matches[0]
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Every ceiling, with live usage and state.")
        @OptionGroup var output: JSONFlag

        func run() throws {
            let (rules, states) = try CeilingCommand.fetch()
            if output.json {
                struct Row: Encodable { var ceiling: Ceiling; var status: CeilingStatus? }
                try JSON.print(rules.map { r in Row(ceiling: r, status: states.first { $0.id == r.id }) })
                return
            }
            guard !rules.isEmpty else { print("no ceilings yet — try: talon ceiling add Xcode --mem 8G --strict ask"); return }
            var t = Table(headers: ["ID", "TARGET", "CEILING", "STRICT", "USING", "STATE"], right: [4])
            for r in rules {
                let st = states.first { $0.id == r.id }
                let using = st.flatMap { s in s.worst.map { "\($0.format(s.usage[$0])) (\(Int((s.ratio * 100).rounded()))%)" } } ?? "—"
                let phase = st?.phase ?? .ok
                let colored: String = switch phase {
                case .ok: Style.green("ok")
                case .approaching, .over: Style.yellow(phase.rawValue)
                case .enforced, .asking: Style.red(phase.rawValue + (st?.lastAction.map { ": \($0)" } ?? ""))
                case .gone, .disabled: Style.dim(phase.rawValue)
                }
                t.rows.append([String(r.id.uuidString.prefix(8)).lowercased(), truncate(r.label, 24), r.summary, r.strictness.label, using, colored])
            }
            print(t.render())
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add (or replace) a ceiling on an app, a process, or a process tree.")
        @Argument(help: "An app name (Xcode), an app bundle path, or a pid.") var target: String
        @Flag(name: .long, help: "With a pid: include every process it spawns.") var tree = false
        @Option(name: .long, help: "Memory ceiling, e.g. 8G.") var mem: Bytes?
        @Option(name: .long, help: "CPU ceiling in percent of one core, e.g. 200%.") var cpu: Percent?
        @Option(name: .long, help: "SSD write-rate ceiling per second, e.g. 50M.") var writes: Bytes?
        @Option(name: .long, help: "watch, warn, ask, slow, pause, quit or hard.") var strict: Strictness = .warn
        @Option(name: .long, help: "Warn from this share of the ceiling, e.g. 90%.") var warn = Percent(argument: "90")!
        @Option(name: .long, help: "How long it may stay over before talon acts.") var grace = TimeRange(argument: "5s")!
        @Option(name: .long, help: "Quit: time between SIGTERM and SIGKILL.") var quitGrace = TimeRange(argument: "10s")!

        func validate() throws {
            if mem == nil && cpu == nil && writes == nil { throw ValidationError("give at least one of --mem, --cpu, --writes") }
        }

        func run() throws {
            let (rules, _) = try CeilingCommand.fetch()
            let (resolved, label) = try resolveTarget()
            // One ceiling per target: adding again replaces it.
            let existing = rules.first { $0.target == resolved }
            let c = Ceiling(id: existing?.id ?? UUID(), target: resolved, label: label, memory: mem?.value, cpu: cpu?.value,
                            writeRate: writes.map { Double($0.value) }, strictness: strict, warnFraction: min(warn.value, 100) / 100,
                            grace: grace.seconds, quitGrace: quitGrace.seconds, createdAt: existing?.createdAt ?? Date())
            if case .ok(let msg) = try request(.setCeiling(c)) { print(Style.green("✓ ") + msg) }
            if strict == .ask { print(Style.dim("  the Talon app shows the ask panel; answer here with `talon ceiling answer \(label) raise|pause|quit|ignore`")) }
            if strict == .hardCap, mem != nil { print(Style.dim("  kernel limits on running apps need talond as root; as an agent talon stops the largest process instead")) }
        }

        private func resolveTarget() throws -> (CeilingTarget, String) {
            if let pid = Int32(target) {
                guard let raw = ProcessSensor.read(pid) else { throw fail(TalonError(.notFound, "no process \(pid) you can see")) }
                let name = ProcessSensor.name(pid)
                return (tree ? .tree(pid: pid, start: raw.startTime) : .process(pid: pid, start: raw.startTime), name)
            }
            if target.hasSuffix(".app") {
                let path = (target as NSString).standardizingPath
                return (.app(key: path), ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
            }
            let sampler = ProcessSampler()
            let apps = sampler.sweep().apps
            let q = target.lowercased()
            let hits = Dictionary(grouping: apps.filter { $0.name.lowercased() == q }, by: \.key)
            if hits.count == 1, let a = hits.values.first?.first { return (.app(key: a.key), a.name) }
            if hits.count > 1 { throw fail(TalonError(.badRequest, "\(target) matches several apps: \(hits.keys.sorted().joined(separator: ", ")) — pass the path")) }
            let fuzzy = Set(apps.filter { $0.name.lowercased().contains(q) }.map(\.name)).sorted()
            throw fail(TalonError(.notFound, "no running app called \(target)" + (fuzzy.isEmpty ? " — pass its .app path" : ". Did you mean: \(fuzzy.prefix(5).joined(separator: ", "))?")))
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a ceiling (and undo any slow-down it applied).")
        @Argument(help: "Ceiling id prefix or label.") var ceiling: String
        func run() throws {
            let c = try CeilingCommand.find(ceiling, in: CeilingCommand.fetch().0)
            if case .ok(let msg) = try request(.removeCeiling(id: c.id)) { print(Style.green("✓ ") + msg) }
        }
    }

    struct Toggle: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "toggle", abstract: "Turn a ceiling off or back on.")
        @Argument(help: "Ceiling id prefix or label.") var ceiling: String
        func run() throws {
            var c = try CeilingCommand.find(ceiling, in: CeilingCommand.fetch().0)
            c.enabled.toggle()
            if case .ok(let msg) = try request(.setCeiling(c)) { print(Style.green("✓ ") + msg) }
        }
    }

    struct Answer: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Answer an Ask ceiling: raise, pause, quit or ignore.")
        @Argument(help: "Ceiling id prefix or label.") var ceiling: String
        @Argument(help: "raise, pause, quit or ignore.") var choice: String
        @Option(name: .long, help: "With raise: multiply the ceiling by this.") var by = 1.25

        func run() throws {
            let c = try CeilingCommand.find(ceiling, in: CeilingCommand.fetch().0)
            let answer: AskChoice = switch choice.lowercased() {
            case "raise": .raise(by: by)
            case "pause": .pause
            case "quit": .quit
            case "ignore": .ignore
            default: throw ValidationError("answer raise, pause, quit or ignore")
            }
            if case .ok(let msg) = try request(.answer(id: c.id, choice: answer)) { print(Style.green("✓ ") + msg) }
        }
    }
}

// MARK: - helper verbs

struct Cap: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Hard memory ceiling on a running process (needs talond as root).")
    @Argument(help: "Process ID.") var pid: Int32
    @Option(name: .long, help: "Ceiling, e.g. 2G.") var mem: Bytes

    func run() throws {
        if case .ok(let msg) = try request(.capMemory(pid: pid, bytes: mem.value)) { print(Style.green("✓ ") + msg) }
    }
}

struct Limit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the kernel memory ceiling on a process.")
    @Argument(help: "Process ID.") var pid: Int32

    func run() throws {
        if case .memoryLimit(let a, let i, let fatal) = try request(.memoryLimit(pid: pid)) {
            if a <= 0 && i <= 0 { print("pid \(pid): no kernel memory ceiling") }
            else { print("pid \(pid): \(a) MB active / \(i) MB inactive" + (fatal ? " · fatal (the kernel stops it)" : " · soft")) }
        }
    }
}

struct Freeze: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause a process in place (SIGSTOP). talond resumes it if it ever exits.")
    @Argument(help: "Process ID.") var pid: Int32
    func run() throws { if case .ok(let msg) = try request(.freeze(pid: pid)) { print(Style.green("✓ ") + msg) } }
}

struct Thaw: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume a paused process.")
    @Argument(help: "Process ID.") var pid: Int32
    func run() throws { if case .ok(let msg) = try request(.thaw(pid: pid)) { print(Style.green("✓ ") + msg) } }
}

// MARK: - history

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A system series over time, from talond's history.",
        discussion: "Series: " + SystemSeries.allCases.map(\.rawValue).joined(separator: ", "))

    @Argument(help: "Which series, e.g. cpu, memUsed, swapUsed, cpuTemp, systemPower.") var series: SystemSeries
    @Option(name: .long, help: "How far back: 15m, 1h, 24h, 7d, 1y.") var range = TimeRange(argument: "1h")!
    @Option(name: .long, help: "Points to show.") var points = 60
    @OptionGroup var output: JSONFlag

    func run() throws {
        guard case .history(let h) = try request(.history(series: series, range: range.seconds, maxPoints: points)) else { return }
        if output.json { try JSON.print(h); return }
        let avgs = h.points.map(\.avg).filter(\.isFinite)
        guard !avgs.isEmpty else { print("no \(series.label.lowercased()) history yet for the last \(TimeSpan.format(range.seconds))"); return }
        let lo = h.points.map(\.min).filter(\.isFinite).min()!, hi = h.points.map(\.max).filter(\.isFinite).max()!
        print(Style.bold(series.label) + Style.dim(" · last \(TimeSpan.format(range.seconds)) · \(h.points.count) points at \(h.tier.rawValue)"))
        print(Style.blue(sparkline(h.points.map(\.avg))))
        print(Style.dim("min ") + series.format(lo) + Style.dim("   avg ") + series.format(avgs.reduce(0, +) / Double(avgs.count))
              + Style.dim("   max ") + series.format(hi) + Style.dim("   now ") + series.format(avgs.last!))
    }
}

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Which apps used the most CPU, memory or SSD writes over a period.")
    @Option(name: .long, help: "How far back: 1h, 24h, 7d.") var range = TimeRange(argument: "24h")!
    @Option(name: .long, help: "Rank by cpu, memory or disk.") var by: AppMetric = .disk
    @Option(name: .shortAndLong, help: "Rows to show.") var n = 15
    @OptionGroup var output: JSONFlag

    func run() throws {
        guard case .topApps(let apps) = try request(.topApps(range: range.seconds, by: by, limit: n)) else { return }
        if output.json { try JSON.print(apps); return }
        guard !apps.isEmpty else { print("no app history yet — talond commits once a minute"); return }
        var t = Table(headers: ["APP", "CPU TIME", "PEAK MEM", "AVG MEM", "WRITTEN"], right: [1, 2, 3, 4])
        for a in apps {
            t.rows.append([truncate(a.name, 32), TimeSpan.format(a.cpuSeconds), ByteSize.format(a.memoryPeak),
                           ByteSize.format(a.memoryAverage), ByteSize.format(a.bytesWritten)])
        }
        print(Style.dim("last \(TimeSpan.format(range.seconds)), by \(by.rawValue)"))
        print(t.render())
    }
}

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Ceilings set, processes paused, pressure changes.")
    @Option(name: .long, help: "How far back.") var range = TimeRange(argument: "7d")!
    @Option(name: .shortAndLong, help: "Rows to show.") var n = 30
    @OptionGroup var output: JSONFlag

    func run() throws {
        guard case .events(let events) = try request(.events(range: range.seconds, limit: n)) else { return }
        if output.json { try JSON.print(events); return }
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm:ss"
        for e in events.reversed() {
            print(Style.dim(f.string(from: Date(timeIntervalSince1970: e.time))) + "  " + pad(e.kind.rawValue, 22) + e.message)
        }
        if events.isEmpty { print("no events in the last \(TimeSpan.format(range.seconds))") }
    }
}

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Is talond running, and what does it cost?")
    @OptionGroup var output: JSONFlag

    func run() throws {
        guard case .status(let s) = try request(.status) else { return }
        if output.json { try JSON.print(s); return }
        func row(_ l: String, _ v: String) { print(pad(Style.dim(l), 16) + v) }
        row("talond", "\(s.version) · protocol v\(s.protocolVersion) · pid \(s.pid) · \(s.euid == 0 ? "root daemon" : "user agent (uid \(s.euid))")")
        row("Serving", "uid \(s.allowedUID)")
        row("Up", TimeSpan.format(Date().timeIntervalSince(s.startedAt)))
        row("Own cost", "\(percent(s.ownCPUPercent, digits: 2)) CPU · \(ByteSize.format(s.ownFootprint)) memory · \(ByteSize.format(s.ownBytesWritten)) written")
        row("Sweep", String(format: "%.1f ms", s.lastSweepMillis) + " · \(s.readableProcesses) readable, \(s.deniedProcesses) denied")
        row("History", "\(ByteSize.format(s.databaseBytes)) · \(s.databasePath)")
        if !s.frozen.isEmpty { row("Paused", s.frozen.map(String.init).joined(separator: ", ")) }
    }
}
