import Foundation

/// One piece of specific, honest advice. `id` is stable for the same situation, so the app can
/// notify once rather than every time it asks.
public struct Insight: Codable, Sendable, Identifiable, Equatable {
    public enum Severity: Int, Codable, Sendable, Comparable {
        case good = 0     // reassurance: nothing to do
        case info
        case watch        // worth knowing; no action needed yet
        case act          // do something
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Area: String, Codable, Sendable, CaseIterable {
        case ssd, battery, memory, thermal, storage, stability
        public var label: String {
            switch self {
            case .ssd: "SSD"; case .battery: "Battery"; case .memory: "Memory"; case .thermal: "Heat"
            case .storage: "Storage"; case .stability: "Stability"
            }
        }
    }

    public var id: String
    public var area: Area
    public var severity: Severity
    public var title: String
    public var detail: String
    public var suggestion: String?

    public init(id: String, area: Area, severity: Severity, title: String, detail: String, suggestion: String? = nil) {
        self.id = id; self.area = area; self.severity = severity; self.title = title; self.detail = detail
        self.suggestion = suggestion
    }
}

/// Everything Care looks at, gathered by talond from its history.
public struct CareInputs: Sendable {
    public var now: TimeInterval
    public var days: [HealthDay]                 // oldest first
    public var writers: [AppTotal]               // last 7 days, by bytes written
    public var memoryHogs: [AppTotal]            // last 7 days, by peak memory
    public var physicalMemory: UInt64
    public var latest: SystemSample?
    public var hourly: [SystemSeries: [HistoryPoint]]   // last 30 days, 1 h buckets (min/avg/max)
    public var events: [TalonEvent]              // last 7 days

    public init(now: TimeInterval, days: [HealthDay], writers: [AppTotal], memoryHogs: [AppTotal], physicalMemory: UInt64,
                latest: SystemSample?, hourly: [SystemSeries: [HistoryPoint]], events: [TalonEvent]) {
        self.now = now; self.days = days; self.writers = writers; self.memoryHogs = memoryHogs
        self.physicalMemory = physicalMemory; self.latest = latest; self.hourly = hourly; self.events = events
    }
}
