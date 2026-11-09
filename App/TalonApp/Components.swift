import AppKit
import Charts
import SwiftUI
import TalonModel

// MARK: - Palette

enum Tint {
    static func series(_ s: SystemSeries) -> Color {
        switch s {
        case .cpu: .blue
        case .memUsed, .memCompressed, .memPressure: .purple
        case .swapUsed: .indigo
        case .cpuTemp, .thermalPressure, .ssdTemp, .batteryTemp: .orange
        case .systemPower, .batteryCharge: .green
        case .diskWriteRate, .diskFree: .teal
        case .processCount: .gray
        }
    }

    static func memory(_ p: MemoryPressure?) -> Color {
        switch p { case .warning: .orange; case .critical: .red; default: .green }
    }

    static func thermal(_ p: ThermalPressure?) -> Color {
        switch p { case .moderate: .yellow; case .heavy: .orange; case .trapping, .sleeping: .red; default: .green }
    }
}

extension SystemSample {
    var memoryPressure: MemoryPressure? { self[.memPressure].isFinite ? MemoryPressure(rawValue: Int(self[.memPressure])) : nil }
    var thermalPressure: ThermalPressure? { self[.thermalPressure].isFinite ? ThermalPressure(rawValue: Int(self[.thermalPressure])) : nil }
}

// MARK: - Sparkline

/// A chart with no axes: the shape of the last few minutes behind a number.
struct Sparkline: View {
    var points: [(Date, Double)]
    var tint: Color
    var floor: Double? = 0

    var body: some View {
        Chart {
            ForEach(points.indices, id: \.self) { i in
                AreaMark(x: .value("t", points[i].0), yStart: .value("lo", lowerBound), yEnd: .value("v", points[i].1))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", points[i].0), y: .value("v", points[i].1))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: lowerBound...upperBound)
        .chartLegend(.hidden)
    }

    private var lowerBound: Double {
        if let floor { return floor }
        return (points.map(\.1).min() ?? 0) * 0.98
    }

    private var upperBound: Double {
        let hi = points.map(\.1).max() ?? 1
        return max(hi * 1.1, lowerBound + 1e-9)
    }
}

// MARK: - Tile

/// One reading: a label, a big number, a qualifier, and the last five minutes behind it.
struct Tile: View {
    var title: String
    var value: String
    var detail: String
    var series: SystemSeries
    var points: [(Date, Double)]
    var accent: Color? = nil
    var floor: Double? = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let accent { Circle().fill(accent).frame(width: 6, height: 6) }
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Sparkline(points: points, tint: Tint.series(series), floor: floor)
                .frame(height: 26)
                .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - App icons

/// Bundle icons for `.app` keys, an SF Symbol for bare binaries. Cached: NSWorkspace icon lookups
/// are not free, and the process table refreshes every second.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for key: String) -> NSImage {
        if let hit = cache[key] { return hit }
        let image: NSImage
        if key.hasSuffix(".app"), FileManager.default.fileExists(atPath: key) {
            image = NSWorkspace.shared.icon(forFile: key)
        } else {
            image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        }
        image.size = NSSize(width: 32, height: 32)
        cache[key] = image
        return image
    }
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ v: Double) -> String { v.isFinite ? ByteSize.format(v) : "—" }
    static func bytes(_ v: UInt64) -> String { ByteSize.format(v) }
    static func rate(_ v: Double) -> String { v.isFinite ? (v < 1 ? "0 B/s" : ByteSize.format(v) + "/s") : "—" }
    static func pct(_ v: Double, digits: Int = 0) -> String { v.isFinite ? String(format: "%.\(digits)f%%", v) : "—" }
    static func temp(_ v: Double) -> String { v.isFinite ? String(format: "%.0f°", v) : "—" }
    static func watts(_ v: Double) -> String { v.isFinite ? String(format: "%.1f W", v) : "—" }
}

/// Small label + value pair used in health cards.
struct Fact: View {
    var label: String
    var value: String
    var tint: Color? = nil

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(tint ?? .primary)
        }
        .font(.callout)
    }
}

struct Card<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
