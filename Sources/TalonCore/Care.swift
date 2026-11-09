import Foundation
import TalonModel

/// Care: turns history into a short list of specific, honest advice. Pure, so every rule is tested
/// with hand-made inputs. Thresholds are deliberately conservative: an insight that cries wolf
/// teaches you to ignore the next one.
public enum Care {
    public static let freeSpaceFloor: Double = 60 * 1_073_741_824   // below this macOS gets tight

    public static func insights(_ i: CareInputs) -> [Insight] {
        var out: [Insight] = []
        out += ssd(i)
        out += battery(i)
        out += memory(i)
        out += thermal(i)
        out += storage(i)
        out += stability(i)
        return out.sorted { ($0.severity, $1.area.rawValue) > ($1.severity, $0.area.rawValue) }
    }

    // MARK: SSD

    static func ssd(_ i: CareInputs) -> [Insight] {
        var out: [Insight] = []
        let total = i.writers.reduce(0.0) { $0 + Double($1.bytesWritten) }
        if let top = i.writers.first, Double(top.bytesWritten) >= 10 * 1_073_741_824 {
            let share = total > 0 ? Double(top.bytesWritten) / total * 100 : 0
            let others = i.writers.dropFirst().prefix(2).map { "\($0.name) \(ByteSize.format($0.bytesWritten))" }
            out.append(Insight(
                id: "ssd.top-writer.\(top.key)", area: .ssd,
                severity: Double(top.bytesWritten) >= 70 * 1_073_741_824 ? .watch : .info,
                title: "\(top.name) wrote \(ByteSize.format(top.bytesWritten)) to the SSD this week",
                detail: String(format: "%.0f%% of everything talon saw written.", share) + (others.isEmpty ? "" : " Next: \(others.joined(separator: ", ")).")
                    + " Writes are what wear an SSD; reads are free.",
                suggestion: "If that's a cache or a log, a ceiling on its write rate (talon ceiling add \(top.name) --writes 5M --strict slow) keeps it in check."))
        }
        // Daily rate from the drive's own counter (includes macOS, swap, everything).
        let perDay = zip(i.days, i.days.dropFirst()).compactMap { a, b -> Double? in
            guard let w0 = a.ssdBytesWritten, let w1 = b.ssdBytesWritten, w1 >= w0 else { return nil }
            return Double(w1 - w0)
        }
        if perDay.count >= 3 {
            let avg = perDay.reduce(0, +) / Double(perDay.count)
            if avg >= 80 * 1_073_741_824 {
                out.append(Insight(id: "ssd.daily-rate", area: .ssd, severity: .watch,
                                   title: "The SSD is taking \(ByteSize.format(avg)) a day",
                                   detail: "Averaged over \(perDay.count) days from the drive's own counter. Typical light use is 10–40 GB a day.",
                                   suggestion: "Check the top writers above, and swap: memory pressure turns into SSD writes."))
            }
        }
        if let first = i.days.first(where: { $0.ssdPercentUsed != nil }), let last = i.days.last(where: { $0.ssdPercentUsed != nil }),
           let u0 = first.ssdPercentUsed, let u1 = last.ssdPercentUsed {
            let spanDays = max(1, (last.time - first.time) / 86_400)
            if u1 > u0, spanDays >= 30 {
                let perYear = Double(u1 - u0) / spanDays * 365
                let years = Double(100 - u1) / perYear
                out.append(Insight(id: "ssd.wear-forecast", area: .ssd, severity: years < 5 ? .watch : .info,
                                   title: "SSD wear is \(u1)% — about \(Int(years.rounded())) years left at this pace",
                                   detail: String(format: "It rose %d point%@ over %.0f days.", u1 - u0, u1 - u0 == 1 ? "" : "s", spanDays)))
            } else if u1 == 0 {
                out.append(Insight(id: "ssd.healthy", area: .ssd, severity: .good, title: "SSD wear is 0%",
                                   detail: "The drive reports no measurable wear" + (last.ssdBytesWritten.map { " after \(ByteSize.format($0)) written." } ?? ".")))
            }
        }
        return out
    }

    // MARK: Battery

    static func battery(_ i: CareInputs) -> [Insight] {
        var out: [Insight] = []
        // Hours plugged in with the battery held near full: the habit that ages a battery fastest.
        let week = i.now - 7 * 86_400
        let charger = Dictionary((i.hourly[.onCharger] ?? []).map { ($0.time, $0) }, uniquingKeysWith: { a, _ in a })
        var parked = 0
        for p in i.hourly[.batteryCharge] ?? [] where p.time >= week {
            if p.min >= 95, let c = charger[p.time], c.avg >= 0.99 { parked += 1 }
        }
        if parked >= 48 {
            out.append(Insight(
                id: "battery.parked-full", area: .battery, severity: parked >= 96 ? .act : .watch,
                title: "The battery sat at 95–100 % on the charger for \(parked) hours this week",
                detail: "Lithium-ion ages fastest held full and warm. Plugged-in desk use is exactly when this happens.",
                suggestion: "Turn on Optimized Battery Charging, or set a charge limit, in System Settings › Battery › Charging."))
        }
        if let last = i.days.last, let h = last.batteryHealthPercent {
            if h < 80 {
                out.append(Insight(id: "battery.service", area: .battery, severity: .act,
                                   title: String(format: "Battery capacity is down to %.0f%% of design", h),
                                   detail: "Below 80 %, Apple considers the battery consumed; runtime and peak power both suffer.",
                                   suggestion: "Check System Settings › Battery › Battery Health, and consider a service appointment."))
            } else if let cycles = last.cycleCount, cycles >= 800 {
                out.append(Insight(id: "battery.cycles", area: .battery, severity: .watch,
                                   title: "\(cycles) charge cycles", detail: "The battery is rated for about 1,000 cycles."))
            } else if let first = i.days.first(where: { $0.batteryHealthPercent != nil }), let h0 = first.batteryHealthPercent,
                      (last.time - first.time) >= 30 * 86_400 {
                let perYear = (h0 - h) / ((last.time - first.time) / 86_400) * 365
                out.append(Insight(id: "battery.trend", area: .battery, severity: perYear > 8 ? .watch : .good,
                                   title: String(format: "Battery health %.1f%%, losing about %.1f points a year", h, max(0, perYear)),
                                   detail: "From nominal capacity, recorded daily."))
            }
        }
        return out
    }

    // MARK: Memory

    static func memory(_ i: CareInputs) -> [Insight] {
        let swap = (i.hourly[.swapUsed] ?? []).filter { $0.time >= i.now - 7 * 86_400 }.map(\.max).filter(\.isFinite).max() ?? 0
        let pressureEvents = i.events.filter { $0.kind == .memoryPressureChange && $0.message.hasSuffix("→ critical") }.count
        guard swap >= max(4 * 1_073_741_824, Double(i.physicalMemory) * 0.25) || pressureEvents > 0 else { return [] }
        let hogs = i.memoryHogs.prefix(3).map { "\($0.name) (peak \(ByteSize.format($0.memoryPeak)))" }.joined(separator: ", ")
        return [Insight(
            id: "memory.swap", area: .memory, severity: swap >= Double(i.physicalMemory) * 0.5 || pressureEvents > 0 ? .act : .watch,
            title: "Swap reached \(ByteSize.format(swap)) this week" + (pressureEvents > 0 ? ", with critical memory pressure \(pressureEvents)×" : ""),
            detail: "Swap is memory spilling onto the SSD: slower, and every page is a write." + (hogs.isEmpty ? "" : " Biggest users: \(hogs)."),
            suggestion: "A memory ceiling with Ask on the biggest user keeps it from pushing everything else into swap.")]
    }

    // MARK: Heat

    static func thermal(_ i: CareInputs) -> [Insight] {
        let throttles = i.events.filter { $0.kind == .throttling }
        guard !throttles.isEmpty else { return [] }
        let busiest = throttles.compactMap { e -> String? in
            guard let r = e.message.range(of: "busiest: ") else { return nil }
            return e.message[r.upperBound...].split(separator: " ").first.map(String.init)
        }
        let common = Dictionary(grouping: busiest, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        return [Insight(
            id: "thermal.throttling", area: .thermal, severity: throttles.count >= 5 ? .watch : .info,
            title: "The chip slowed itself down \(throttles.count)× this week to stay cool",
            detail: "A fanless Air trades clock speed for heat under sustained load." + (common.map { " Most often while \($0) was busiest." } ?? ""),
            suggestion: "Long jobs finish sooner capped below the throttling point: try a CPU ceiling with Slow down.")]
    }

    // MARK: Storage

    static func storage(_ i: CareInputs) -> [Insight] {
        let pts = (i.hourly[.diskFree] ?? []).filter { $0.avg.isFinite }
        let free = i.latest?[.diskFree] ?? pts.last?.avg ?? .nan
        guard free.isFinite else { return [] }
        if free < freeSpaceFloor {
            return [Insight(id: "storage.low", area: .storage, severity: .act,
                            title: "Only \(ByteSize.format(free)) free",
                            detail: "Below about 60 GB, macOS has less room for swap, updates and snapshots.",
                            suggestion: "talon scalpel scan ~ shows exactly what each cleanup would give back.")]
        }
        // Linear trend over the last 30 days of hourly averages.
        guard pts.count >= 48, let t0 = pts.first?.time else { return [] }
        let xs = pts.map { ($0.time - t0) / 86_400 }, ys = pts.map(\.avg)
        let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let cov = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }, varx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard varx > 0 else { return [] }
        let slope = cov / varx   // bytes per day
        guard slope < -1_073_741_824 else { return [] }   // shrinking by more than 1 GB a day
        let days = (free - freeSpaceFloor) / -slope
        return [Insight(
            id: "storage.forecast", area: .storage, severity: days < 30 ? .act : days < 90 ? .watch : .info,
            title: "Free space will cross 60 GB in about \(Int(days.rounded())) days",
            detail: "It's falling by \(ByteSize.format(-slope)) a day (trend over \(Int(xs.last!.rounded())) days); \(ByteSize.format(free)) free now.",
            suggestion: "talon scalpel scan ~ shows where it went.")]
    }

    // MARK: Stability

    static func stability(_ i: CareInputs) -> [Insight] {
        guard let first = i.days.first(where: { $0.unsafeShutdowns != nil }), let last = i.days.last(where: { $0.unsafeShutdowns != nil }),
              let u0 = first.unsafeShutdowns, let u1 = last.unsafeShutdowns, u1 > u0 else { return [] }
        return [Insight(id: "stability.unsafe-\(u1)", area: .stability, severity: u1 - u0 >= 3 ? .act : .watch,
                        title: "\(u1 - u0) unsafe shutdown\(u1 - u0 == 1 ? "" : "s") since \(first.day)",
                        detail: "The SSD counted power being cut without a clean shutdown: a forced restart, a drained battery, or a kernel panic.",
                        suggestion: "If you didn't force a restart, check Console › Crash Reports for panic logs.")]
    }
}
