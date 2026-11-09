import Darwin
import Foundation
import TalonModel

/// Terminal styling that switches itself off for pipes and NO_COLOR.
enum Style {
    static let enabled = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func wrap(_ s: String, _ code: String) -> String { enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func green(_ s: String) -> String { wrap(s, "32") }
    static func yellow(_ s: String) -> String { wrap(s, "33") }
    static func red(_ s: String) -> String { wrap(s, "31") }
    static func blue(_ s: String) -> String { wrap(s, "34") }

    enum Verdict { case good, watch, bad }
    static func verdict(_ v: Verdict, _ s: String) -> String {
        switch v { case .good: green(s); case .watch: yellow(s); case .bad: red(s) }
    }
}

/// Visible width, ignoring ANSI escapes.
func visibleWidth(_ s: String) -> Int {
    var n = 0, inEscape = false
    for c in s.unicodeScalars {
        if inEscape { if c == "m" { inEscape = false }; continue }
        if c == "\u{1B}" { inEscape = true; continue }
        n += 1
    }
    return n
}

func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    let gap = String(repeating: " ", count: max(0, width - visibleWidth(s)))
    return right ? gap + s : s + gap
}

func truncate(_ s: String, _ width: Int) -> String {
    s.count <= width ? s : String(s.prefix(max(1, width - 1))) + "…"
}

/// A plain aligned table. Columns flagged `right` are right-aligned (numbers).
struct Table {
    var headers: [String]
    var right: Set<Int> = []
    var rows: [[String]] = []

    func render() -> String {
        var widths = headers.map(visibleWidth)
        for r in rows { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], visibleWidth(c)) } }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { pad($1, widths[$0], right: right.contains($0)) }.joined(separator: "  ")
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        return ([Style.dim(line(headers))] + rows.map(line)).joined(separator: "\n")
    }
}

/// ▁▂▃▄▅▆▇█ — one character per point, NaN as a gap.
func sparkline(_ values: [Double], lo: Double? = nil, hi: Double? = nil) -> String {
    let bars = Array("▁▂▃▄▅▆▇█")
    let finite = values.filter(\.isFinite)
    guard let mn = lo ?? finite.min(), let mx = hi ?? finite.max() else { return String(repeating: " ", count: values.count) }
    return String(values.map { v -> Character in
        guard v.isFinite else { return " " }
        guard mx > mn else { return bars[0] }
        return bars[min(bars.count - 1, max(0, Int(((v - mn) / (mx - mn) * Double(bars.count - 1)).rounded())))]
    })
}

/// A horizontal meter: `███████░░░ 70%`.
func meter(_ fraction: Double, width: Int = 20) -> String {
    let f = max(0, min(1, fraction.isFinite ? fraction : 0))
    let filled = Int((f * Double(width)).rounded())
    return String(repeating: "█", count: filled) + Style.dim(String(repeating: "░", count: width - filled))
}

enum JSON {
    static func print<T: Encodable>(_ value: T) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        Swift.print(String(decoding: try e.encode(value), as: UTF8.self))
    }
}

func percent(_ v: Double, digits: Int = 0) -> String {
    v.isFinite ? String(format: "%.\(digits)f%%", v) : "—"
}

func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
