import Foundation

/// What the widget shows. The app writes it once a minute; the widget only reads it. A plain file
/// in /Users/Shared rather than an App Group, because App Groups need a provisioned Team ID and
/// talon is ad-hoc signed — the widget's sandbox gets a read-only exception for that one folder.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public static let directory = "/Users/Shared/Talon"
    public static let path = directory + "/widget.json"

    public var time: Date
    public var connected: Bool
    public var cpu: Double
    public var memUsed: Double
    public var memTotal: Double
    public var memPressure: Int
    public var cpuTemp: Double
    public var thermalPressure: Int
    public var power: Double
    public var battery: Double
    public var swap: Double
    public var diskFree: Double
    public var careTitle: String?
    public var careSeverity: Int?      // Insight.Severity raw value
    public var asking: Int             // ceilings waiting for an answer

    public init(time: Date, connected: Bool, cpu: Double, memUsed: Double, memTotal: Double, memPressure: Int, cpuTemp: Double,
                thermalPressure: Int, power: Double, battery: Double, swap: Double, diskFree: Double, careTitle: String?,
                careSeverity: Int?, asking: Int) {
        self.time = time; self.connected = connected; self.cpu = cpu; self.memUsed = memUsed; self.memTotal = memTotal
        self.memPressure = memPressure; self.cpuTemp = cpuTemp; self.thermalPressure = thermalPressure; self.power = power
        self.battery = battery; self.swap = swap; self.diskFree = diskFree; self.careTitle = careTitle
        self.careSeverity = careSeverity; self.asking = asking
    }

    public static func read() -> WidgetSnapshot? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try? d.decode(WidgetSnapshot.self, from: data)
    }

    public func write() throws {
        try FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try e.encode(self).write(to: URL(fileURLWithPath: Self.path), options: .atomic)
    }

    public static let placeholder = WidgetSnapshot(
        time: Date(), connected: true, cpu: 18, memUsed: 9.4e9, memTotal: 17_179_869_184, memPressure: 0, cpuTemp: 47,
        thermalPressure: 0, power: 6.5, battery: 80, swap: 0.9e9, diskFree: 231e9,
        careTitle: "The battery sat at 95–100 % on the charger for 61 hours this week", careSeverity: 2, asking: 0)
}
