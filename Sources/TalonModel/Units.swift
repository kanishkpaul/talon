import Foundation

/// Byte sizes as people type them: `300M`, `6G`, `1.5GiB`, `512mb`, `2048` (bytes).
/// Binary units throughout (1G = 1024³), matching how macOS reports memory.
public enum ByteSize {
    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case invalid(String)
        public var description: String {
            switch self { case .invalid(let s): "can't read \"\(s)\" as a size — try 300M, 6G or 1.5GiB" }
        }
    }

    public static func parse(_ text: String) throws -> UInt64 {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        let split = s.firstIndex { !"0123456789.".contains($0) } ?? s.endIndex
        guard let number = Double(s[..<split]), number >= 0, number.isFinite else { throw ParseError.invalid(text) }
        let unit = s[split...].trimmingCharacters(in: .whitespaces)
        let shift: Double
        switch unit {
        case "", "b": shift = 0
        case "k", "kb", "kib": shift = 10
        case "m", "mb", "mib": shift = 20
        case "g", "gb", "gib": shift = 30
        case "t", "tb", "tib": shift = 40
        default: throw ParseError.invalid(text)
        }
        let bytes = number * pow(2, shift)
        guard bytes < Double(UInt64.max) else { throw ParseError.invalid(text) }
        return UInt64(bytes.rounded())
    }

    /// `812 MB`, `6.4 GB`, `1.02 TB` — two to three significant figures, binary units.
    public static func format(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = abs(bytes), i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        let sign = bytes < 0 ? "-" : ""
        if i == 0 { return "\(sign)\(Int(v)) B" }
        let digits = v >= 100 ? 0 : v >= 10 ? 1 : 2
        return sign + String(format: "%.\(digits)f", v) + " " + units[i]
    }

    public static func format(_ bytes: UInt64) -> String { format(Double(bytes)) }
}

/// Durations as people type them: `90s`, `15m`, `1h`, `24h`, `7d`, `1y`.
public enum TimeSpan {
    public static func parse(_ text: String) -> TimeInterval? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let last = s.last else { return nil }
        let unit: TimeInterval
        var digits = Substring(s)
        switch last {
        case "s": unit = 1; digits = digits.dropLast()
        case "m": unit = 60; digits = digits.dropLast()
        case "h": unit = 3600; digits = digits.dropLast()
        case "d": unit = 86_400; digits = digits.dropLast()
        case "w": unit = 7 * 86_400; digits = digits.dropLast()
        case "y": unit = 365 * 86_400; digits = digits.dropLast()
        default: unit = 1
        }
        guard let n = Double(digits), n > 0, n.isFinite else { return nil }
        return n * unit
    }

    public static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" + (s % 60 > 0 ? " \(s % 60)s" : "") }
        if s < 86_400 { return "\(s / 3600)h" + (s % 3600 >= 60 ? " \(s % 3600 / 60)m" : "") }
        return "\(s / 86_400)d" + (s % 86_400 >= 3600 ? " \(s % 86_400 / 3600)h" : "")
    }
}
