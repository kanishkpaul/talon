import Foundation
import Testing
@testable import TalonModel

@Suite struct ByteSizeTests {
    @Test(arguments: [
        ("300M", UInt64(300) << 20), ("6G", UInt64(6) << 30), ("1.5GiB", UInt64(1536) << 20), ("512mb", UInt64(512) << 20),
        ("2048", 2048), ("1t", UInt64(1) << 40), (" 64 K ", 64 << 10), ("0", 0),
    ])
    func parses(_ text: String, _ bytes: UInt64) throws {
        #expect(try ByteSize.parse(text) == bytes)
    }

    @Test(arguments: ["", "G", "six gigs", "-1G", "1.2.3M", "5X", "1e400"])
    func rejects(_ text: String) {
        #expect(throws: ByteSize.ParseError.self) { try ByteSize.parse(text) }
    }

    @Test func formats() {
        #expect(ByteSize.format(UInt64(0)) == "0 B")
        #expect(ByteSize.format(UInt64(1023)) == "1023 B")
        #expect(ByteSize.format(UInt64(300) << 20) == "300 MB")
        #expect(ByteSize.format(UInt64(6) << 30) == "6.00 GB")
        #expect(ByteSize.format(Double(12.08e12)) == "11.0 TB")
        #expect(ByteSize.format(-2048.0) == "-2.00 KB")
    }
}

@Suite struct TimeSpanTests {
    @Test func parses() {
        #expect(TimeSpan.parse("90s") == 90)
        #expect(TimeSpan.parse("15m") == 900)
        #expect(TimeSpan.parse("24h") == 86_400)
        #expect(TimeSpan.parse("7d") == 604_800.0)
        #expect(TimeSpan.parse("1y") == 31_536_000.0)
        #expect(TimeSpan.parse("45") == 45)
        #expect(TimeSpan.parse("h") == nil)
        #expect(TimeSpan.parse("-1h") == nil)
    }

    @Test func formats() {
        #expect(TimeSpan.format(42) == "42s")
        #expect(TimeSpan.format(125) == "2m 5s")
        #expect(TimeSpan.format(3 * 3600 + 120) == "3h 2m")
        #expect(TimeSpan.format(2 * 86_400 + 3600) == "2d 1h")
    }
}

@Suite struct SeriesTests {
    @Test func sampleSubscriptRoundTrips() {
        var s = SystemSample(time: 1)
        #expect(s[.cpu].isNaN)
        s[.cpuTemp] = 51.5
        #expect(s[.cpuTemp] == 51.5)
        #expect(s.values.count == SystemSeries.allCases.count)
    }

    @Test func samplesWithNaNCompareEqual() {
        #expect(SystemSample(time: 5) == SystemSample(time: 5))
    }

    @Test func pressureFromKernelLevels() {
        #expect(MemoryPressure(kernelLevel: 1) == .normal)
        #expect(MemoryPressure(kernelLevel: 2) == .warning)
        #expect(MemoryPressure(kernelLevel: 4) == .critical)
    }

    @Test func formatsByUnit() {
        #expect(SystemSeries.cpu.format(42.4) == "42%")
        #expect(SystemSeries.cpuTemp.format(50.04) == "50.0 °C")
        #expect(SystemSeries.thermalPressure.format(2) == "heavy")
        #expect(SystemSeries.memPressure.format(.nan) == "—")
    }
}

@Suite struct DownsampleTests {
    @Test func keepsSpikesThroughMinMax() {
        var pts = (0..<1000).map { HistoryPoint(time: Double($0), min: 1, avg: 1, max: 1) }
        pts[501] = HistoryPoint(time: 501, min: 99, avg: 99, max: 99)
        let out = downsample(pts, maxPoints: 10)
        #expect(out.count == 10)
        #expect(out.map(\.max).max() == 99)
        #expect(out.map(\.min).min() == 1)
        #expect(out.first?.time == 0)
    }

    @Test func passesShortSeriesThrough() {
        let pts = (0..<5).map { HistoryPoint(time: Double($0), min: 0, avg: 0, max: 0) }
        #expect(downsample(pts, maxPoints: 10) == pts)
    }

    @Test func allNaNBucketStaysNaN() {
        let pts = (0..<4).map { HistoryPoint(time: Double($0), min: .nan, avg: .nan, max: .nan) }
        #expect(downsample(pts, maxPoints: 2).allSatisfy { $0.avg.isNaN })
    }
}
