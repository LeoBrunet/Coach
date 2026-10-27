import SwiftUI

// Mirrors server/src/schemas.ts — keep both in sync.

enum Sport: String, Codable, CaseIterable, Identifiable, Hashable {
    case course, velo, natation, muscu, repos

    var id: String { rawValue }

    var label: String {
        switch self {
        case .course: String(localized: "Course")
        case .velo: String(localized: "Vélo")
        case .natation: String(localized: "Natation")
        case .muscu: String(localized: "Renfo")
        case .repos: String(localized: "Repos")
        }
    }

    var icon: String {
        switch self {
        case .course: "figure.run"
        case .velo: "figure.outdoor.cycle"
        case .natation: "figure.pool.swim"
        case .muscu: "figure.strengthtraining.traditional"
        case .repos: "bed.double.fill"
        }
    }

    var color: Color {
        switch self {
        case .course: Color(red: 1.0, green: 0.36, blue: 0.16)
        case .velo: Color(red: 0.16, green: 0.52, blue: 1.0)
        case .natation: Color(red: 0.0, green: 0.72, blue: 0.80)
        case .muscu: Color(red: 0.55, green: 0.36, blue: 0.96)
        case .repos: Color(red: 0.55, green: 0.60, blue: 0.66)
        }
    }

    /// Sports where distance makes sense.
    var hasDistance: Bool { self == .course || self == .velo || self == .natation }
}

struct Target: Codable, Hashable {
    var paceSecPerKm: Int?
    var swimPaceSecPer100m: Int?
    var speedKmh: Double?
    var hrMin: Int?
    var hrMax: Int?
    var distanceKm: Double?
}

struct Step: Codable, Hashable, Identifiable {
    struct Recovery: Codable, Hashable {
        var durationMin: Double?
        var durationSec: Int?
        var distanceM: Double?
        var zone: Int

        var seconds: Int? { durationSec ?? durationMin.map { Int(($0 * 60).rounded()) } }
    }

    var name: String
    var detail: String?
    var kind: String?
    var zone: Int
    var durationMin: Double?
    var durationSec: Int?
    var distanceM: Double?
    var repeat_: Int?
    var recovery: Recovery?
    var target: Target?

    var id: String { "\(name)-\(zone)-\(durationMin ?? 0)-\(distanceM ?? 0)" }
    var repeatCount: Int { max(repeat_ ?? 1, 1) }
    /// Exact duration in seconds (`durationSec`, else minutes rounded to the second: 0.33 min → 20 s).
    var seconds: Int? { durationSec ?? durationMin.map { Int(($0 * 60).rounded()) } }

    enum CodingKeys: String, CodingKey {
        case name, detail, kind, zone, durationMin, durationSec, distanceM, recovery, target
        case repeat_ = "repeat"
    }
}

struct Cue: Codable, Hashable {
    var title: String
    var detail: String?
}

struct Session: Codable, Identifiable, Hashable {
    var id: String
    var date: String
    var sport: Sport
    var title: String
    var subtitle: String?
    var durationMin: Int
    var load: String?
    var why: String?
    var target: Target?
    var cues: [Cue]?
    var steps: [Step]?
    var status: String
    var workoutId: String?
    var updatedAt: String

    var isDone: Bool { status == "done" }

    /// The coach writes the load in French ("Faible", "Modérée", "Élevée"): show it in the app's language.
    var loadLabel: String? {
        switch load?.lowercased() {
        case "faible": String(localized: "Faible")
        case "modérée", "moderee", "modérée ": String(localized: "Modérée")
        case "élevée", "elevee": String(localized: "Élevée")
        default: load
        }
    }
    var day: Date? { Day.date(date) }
}

struct Goal: Codable, Hashable {
    var title: String
    var date: String?
    var targetTime: String?
}

struct Profile: Codable, Hashable {
    var name: String?
    var tagline: String?
    var goal: Goal?
    var availability: String?
    var injuries: String?
    var sports: [Sport]?
    var maxHr: Int?
    var restingHr: Int?
    var timezone: String?
    var language: String?
    var notes: String?
}

struct ClaudeStatus: Codable, Hashable {
    var connectedAt: String?
    var lastSeenAt: String?
    var isConnected: Bool { connectedAt != nil }
}

struct CoachNote: Codable, Hashable {
    var date: String
    var text: String
    var createdAt: String
}

struct KeyPoint: Codable, Hashable {
    var kind: String
    var text: String
}

struct Analysis: Codable, Hashable {
    var workoutId: String
    var text: String
    var keyPoints: [KeyPoint]
    var createdAt: String
}

struct Checkin: Codable, Hashable {
    var id: String
    var date: String
    var feeling: Int
    var note: String?
    var sessionId: String?
    var createdAt: String
}

/// GET /api/state
struct ServerState: Codable {
    var today: String
    var connectorUrl: String
    var claude: ClaudeStatus
    var profile: Profile
    var sessions: [Session]
    var note: CoachNote?
    var analyses: [Analysis]
    var rpe: [String: Int]
    var checkins: [Checkin]
}

// MARK: - Health data (read locally from HealthKit, uploaded to the server)

struct Lap: Codable, Hashable {
    var index: Int
    var durationS: Double
    var distanceM: Double?

    var paceSecPerKm: Int? {
        guard let distanceM, distanceM > 50 else { return nil }
        return Int((durationS / distanceM * 1000).rounded())
    }
}

struct WorkoutDetails: Codable, Hashable {
    var laps: [Lap]?
    /// Minutes in zones 1…5.
    var zonesMin: [Double]?
}

struct WorkoutSummary: Codable, Identifiable, Hashable {
    var id: String
    var sport: Sport
    var start: Date
    var end: Date
    var localDate: String
    var durationS: Double
    var distanceM: Double?
    var energyKcal: Double?
    var avgHr: Double?
    var maxHr: Double?
    var elevationM: Double?
    var details: WorkoutDetails

    var paceSecPerKm: Int? {
        guard let distanceM, distanceM > 100 else { return nil }
        return Int((durationS / distanceM * 1000).rounded())
    }

    var speedKmh: Double? {
        guard let distanceM, durationS > 0 else { return nil }
        return distanceM / durationS * 3.6
    }
}

struct DailyMetrics: Codable, Hashable {
    var date: String
    var sleepMin: Double?
    var hrvMs: Double?
    var restingHr: Double?
    var vo2max: Double?
}

// MARK: - Dates

enum Day {
    static var calendar: Calendar = {
        // ISO 8601: weeks start on Monday whatever the language (training weeks).
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        calendar.locale = .current
        return calendar
    }()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ string: String) -> Date? { formatter.date(from: string) }
    static var today: String { string(Date()) }

    /// Monday of the week containing `date`.
    static func weekStart(_ date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func week(containing date: Date) -> [Date] {
        let start = weekStart(date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    static func add(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)).capitalizedFirst
    }

    static func short(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func weekdayLetter(_ date: Date) -> String {
        String(date.formatted(.dateTime.weekday(.narrow))).uppercased()
    }

    static func weekdayShort(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated)).replacingOccurrences(of: ".", with: "").capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Formatting

enum Fmt {
    static func pace(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "20 s", "1 min 30", "15 min", "1 h 05".
    static func duration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds % 60 != 0, seconds < 600 { return "\(seconds / 60) min \(String(format: "%02d", seconds % 60))" }
        return duration(minutes: Int((Double(seconds) / 60).rounded()))
    }

    static func duration(minutes: Int) -> String {
        minutes >= 60 ? String(format: "%d h %02d", minutes / 60, minutes % 60) : "\(minutes) min"
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func km(_ meters: Double?, decimals: Int = 1) -> String {
        guard let meters else { return "–" }
        return (meters / 1000).formatted(.number.precision(.fractionLength(decimals)))
    }

    static func number(_ value: Double?, decimals: Int = 0) -> String {
        guard let value else { return "–" }
        return value.formatted(.number.precision(.fractionLength(decimals)))
    }

    static func time(isoString: String) -> String {
        guard let date = ISO8601DateFormatter.flexible.date(from: isoString) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
