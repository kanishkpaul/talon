// Spike 1 — Can we sample every process several times a second for <1% CPU?
//
// Reads memory footprint, CPU time and disk I/O for every PID via proc_pid_rusage,
// groups helpers under their "responsible" app (like Activity Monitor), and
// measures this program's own CPU and memory cost.
//
// Usage: sampler [--hz 4] [--seconds 20]

import Darwin
import Foundation

// MARK: - Args

var hz = 1.0          // full sweep rate (every process)
var fastHz = 0.0      // fast rate for watched (capped) apps only; 0 = off
var watchN = 5        // how many apps to treat as "capped" for the test
var seconds = 20.0
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--hz": hz = Double(it.next() ?? "") ?? hz
    case "--seconds": seconds = Double(it.next() ?? "") ?? seconds
    case "--fast-hz": fastHz = Double(it.next() ?? "") ?? fastHz
    case "--watch": watchN = Int(it.next() ?? "") ?? watchN
    default: break
    }
}

// MARK: - Private: responsible PID (groups "Chrome Helper" under "Google Chrome")

typealias RespFn = @convention(c) (pid_t) -> pid_t
let respSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") // RTLD_DEFAULT
let responsiblePID: RespFn? = respSym.map { unsafeBitCast($0, to: RespFn.self) }

// MARK: - Helpers

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func ticksToNs(_ t: UInt64) -> Double { Double(t) * Double(timebase.numer) / Double(timebase.denom) }

func rusage(_ pid: pid_t) -> rusage_info_v4? {
    var info = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    return r == 0 ? info : nil
}

func name(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    proc_name(pid, &buf, UInt32(buf.count))
    let s = String(cString: buf)
    return s.isEmpty ? "pid \(pid)" : s
}

func allPIDs() -> [pid_t] {
    var buf = [pid_t](repeating: 0, count: 8192)
    let n = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    return Array(buf.prefix(Int(max(n, 0))))
}

func selfCPUns() -> Double {
    var u = Darwin.rusage()
    getrusage(RUSAGE_SELF, &u)
    let t = { (tv: timeval) in Double(tv.tv_sec) * 1e9 + Double(tv.tv_usec) * 1e3 }
    return t(u.ru_utime) + t(u.ru_stime)
}

func fmtBytes(_ b: UInt64) -> String {
    let mb = Double(b) / 1_048_576
    return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

// MARK: - Sample loop

struct Row { var footprint: UInt64; var cpuNs: Double; var diskW: UInt64; var resp: pid_t }

var prev: [pid_t: Row] = [:]
var cpuPct: [pid_t: Double] = [:]
var tickDurations: [Double] = []
var readable = 0, denied = 0, total = 0
let tickHz = max(hz, fastHz)
let interval = 1.0 / tickHz
let fullEvery = max(1, Int((tickHz / hz).rounded()))
let ticks = Int(seconds * tickHz)

func rowFor(_ pid: pid_t, _ r: rusage_info_v4) -> Row {
    Row(footprint: r.ri_phys_footprint, cpuNs: ticksToNs(r.ri_user_time + r.ri_system_time),
        diskW: r.ri_diskio_byteswritten, resp: prev[pid]?.resp ?? (responsiblePID?(pid) ?? pid))
}

// Warm-up sweep (so the first real tick has deltas)
for pid in allPIDs() { if let r = rusage(pid) { prev[pid] = rowFor(pid, r) } }

// "Capped" set for the test: every process belonging to the top-N apps by memory
var appMem: [pid_t: UInt64] = [:]
for row in prev.values { appMem[row.resp, default: 0] += row.footprint }
let cappedApps = Set(appMem.sorted { $0.value > $1.value }.prefix(watchN).map(\.key))
var watched: [pid_t] = prev.filter { cappedApps.contains($0.value.resp) }.map(\.key)

let wallStart = Date()
let cpuStart = selfCPUns()
print("Full sweep at \(hz) Hz" + (fastHz > 0 ? ", plus \(watched.count) processes of \(watchN) capped apps at \(fastHz) Hz" : "") + ", for \(Int(seconds))s…")

var fullTicks: [Double] = [], fastTicks: [Double] = []
for i in 0..<ticks {
    let t0 = Date()
    if i % fullEvery == 0 {
        let pids = allPIDs()
        var next: [pid_t: Row] = [:]
        readable = 0; denied = 0; total = pids.count
        for pid in pids {
            guard let r = rusage(pid) else { denied += 1; continue }
            readable += 1
            let row = rowFor(pid, r)
            if let p = prev[pid] { cpuPct[pid] = (row.cpuNs - p.cpuNs) / (Double(fullEvery) * interval * 1e9) * 100 }
            next[pid] = row
        }
        prev = next
        watched = prev.filter { cappedApps.contains($0.value.resp) }.map(\.key)
        fullTicks.append(Date().timeIntervalSince(t0))
    } else {
        for pid in watched { if let r = rusage(pid) { prev[pid]!.footprint = r.ri_phys_footprint } }
        fastTicks.append(Date().timeIntervalSince(t0))
    }
    let dt = Date().timeIntervalSince(t0)
    if dt < interval { usleep(useconds_t((interval - dt) * 1e6)) }
}
tickDurations = fullTicks

let wall = Date().timeIntervalSince(wallStart)
let cpuUsed = selfCPUns() - cpuStart
let selfFootprint = rusage(getpid())?.ri_phys_footprint ?? 0

// MARK: - Report

struct Group { var name: String; var footprint: UInt64 = 0; var cpu: Double = 0; var procs = 0 }
var groups: [pid_t: Group] = [:]
for (pid, row) in prev {
    var g = groups[row.resp] ?? Group(name: name(row.resp))
    g.footprint += row.footprint; g.cpu += cpuPct[pid] ?? 0; g.procs += 1
    groups[row.resp] = g
}

let avgTickMs = tickDurations.reduce(0, +) / Double(tickDurations.count) * 1000
let maxTickMs = (tickDurations.max() ?? 0) * 1000
print("""

── Result ─────────────────────────────────────────────
Processes seen:       \(total)  (readable \(readable), denied \(denied) — denied need the admin helper)
Responsible-app API:  \(responsiblePID == nil ? "NOT available" : "available")
Full sweep cost:      avg \(String(format: "%.2f", avgTickMs)) ms, max \(String(format: "%.2f", maxTickMs)) ms
Fast check cost:      \(fastTicks.isEmpty ? "n/a" : String(format: "avg %.3f ms", fastTicks.reduce(0,+)/Double(fastTicks.count)*1000))
Own CPU:              \(String(format: "%.2f", cpuUsed / (wall * 1e9) * 100))% of one core   (target < 1%)
Own memory:           \(fmtBytes(selfFootprint))

Top apps by memory (helpers grouped under their app):
""")
for g in groups.values.sorted(by: { $0.footprint > $1.footprint }).prefix(10) {
    let n = String(g.name.prefix(30)).padding(toLength: 30, withPad: " ", startingAt: 0)
    let m = fmtBytes(g.footprint); let mp = String(repeating: " ", count: max(0, 9 - m.count)) + m
    print("  \(n) \(mp)  " + String(format: "%5.1f%% CPU  %3d procs", g.cpu, g.procs))
}
