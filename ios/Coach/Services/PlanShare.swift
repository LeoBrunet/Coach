import Foundation

/// Shares the training plan with Popote (the food app) through an App Group file, so it can set
/// each day's calorie and carb targets from the sessions. Read by Popote's `CoachPlan`; keep both in sync.
enum PlanShare {
    static let group = "group.com.leobrunet.shared"
    static let fileName = "coach-plan.json"

    struct File: Codable {
        var version = 1
        var updatedAt: Date
        var goal: Goal?
        var sessions: [Item]
    }

    struct Item: Codable {
        var date: String
        var sport: String
        var title: String
        var durationMin: Int
        var load: String?
        /// Minutes spent in zones 1–5, from the steps (nil when the steps give no durations).
        var zoneMinutes: [Double]?
        var done: Bool
    }

    /// Writes sessions from a week ago to three weeks ahead. Silently does nothing without the App Group.
    static func write(sessions: [Session], goal: Goal?) {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            log.error("planShare: no App Group container")
            return
        }
        let from = Day.string(Day.add(-7, to: Date()))
        let to = Day.string(Day.add(21, to: Date()))
        let items = sessions
            .filter { $0.date >= from && $0.date <= to }
            .sorted { $0.date < $1.date }
            .map { Item(date: $0.date, sport: $0.sport.rawValue, title: $0.title, durationMin: $0.durationMin,
                        load: $0.load, zoneMinutes: zoneMinutes($0), done: $0.isDone) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(File(updatedAt: Date(), goal: goal, sessions: items))
            try data.write(to: folder.appending(path: fileName), options: .atomic)
        } catch {
            log.error("planShare: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func zoneMinutes(_ session: Session) -> [Double]? {
        var minutes = [Double](repeating: 0, count: 5)
        for step in session.steps ?? [] {
            let count = Double(step.repeatCount)
            if let seconds = step.seconds { minutes[zoneIndex(step.zone)] += Double(seconds) * count / 60 }
            if let recovery = step.recovery, let seconds = recovery.seconds {
                minutes[zoneIndex(recovery.zone)] += Double(seconds) * max(count - 1, 0) / 60
            }
        }
        return minutes.reduce(0, +) > 0 ? minutes : nil
    }

    private static func zoneIndex(_ zone: Int) -> Int { min(max(zone, 1), 5) - 1 }
}
