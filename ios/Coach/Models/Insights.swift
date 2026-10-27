import Foundation

/// Pure computations behind the Today / Progress / Profile screens.
enum Insights {
    // MARK: Recovery

    struct Recovery {
        let score: Int
        let label: String
        let summary: String
        let sleepMin: Double?
        let hrvMs: Double?
        let restingHr: Double?
    }

    /// 0–100 from last night's sleep, HRV and resting HR compared with the 30-day average.
    static func recovery(_ metrics: [DailyMetrics], today: String = Day.today) -> Recovery? {
        let recent = metrics.filter { $0.date <= today }.sorted { $0.date > $1.date }
        guard let latest = recent.first(where: { $0.hrvMs != nil || $0.sleepMin != nil || $0.restingHr != nil }) else { return nil }
        let month = recent.prefix(30)
        func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        let hrvAvg = average(month.compactMap(\.hrvMs))
        let rhrAvg = average(month.compactMap(\.restingHr))

        var score = 0.0, weight = 0.0
        var parts: [String] = []
        if let sleep = latest.sleepMin {
            score += min(sleep / 450, 1.1) / 1.1 * 40; weight += 40
            parts.append(String(localized: "sommeil \(Int(sleep) / 60) h \(String(format: "%02d", Int(sleep) % 60))"))
        }
        if let hrv = latest.hrvMs, let hrvAvg, hrvAvg > 0 {
            let ratio = hrv / hrvAvg
            score += (min(max(ratio, 0.7), 1.2) - 0.7) / 0.5 * 35; weight += 35
            let delta = Int(((ratio - 1) * 100).rounded())
            parts.insert(String(localized: "VFC \(delta >= 0 ? "+" : "")\(delta) % vs ta moyenne"), at: 0)
        }
        if let rhr = latest.restingHr, let rhrAvg, rhr > 0 {
            score += (min(max(rhrAvg / rhr, 0.9), 1.1) - 0.9) / 0.2 * 25; weight += 25
        }
        guard weight > 0 else { return nil }
        let value = Int((score / weight * 100).rounded())
        let label = value >= 75 ? String(localized: "bonne") : value >= 55 ? String(localized: "correcte") : String(localized: "faible")
        let advice = value >= 75 ? String(localized: "Tu peux pousser aujourd'hui.") : value >= 55 ? String(localized: "Séance possible, écoute tes sensations.") : String(localized: "Privilégie une séance facile ou le repos.")
        return Recovery(
            score: value,
            label: label,
            summary: (parts.joined(separator: ", ") + ". " + advice).capitalizedFirst,
            sleepMin: latest.sleepMin,
            hrvMs: latest.hrvMs,
            restingHr: latest.restingHr
        )
    }

    // MARK: Volume

    struct WeekVolume: Identifiable {
        let weekStart: Date
        let sport: Sport
        let hours: Double
        var id: String { "\(weekStart.timeIntervalSince1970)-\(sport.rawValue)" }
    }

    static let trainingSports: [Sport] = [.course, .velo, .natation, .muscu]

    static func weeklyVolumes(_ workouts: [WorkoutSummary], weeks: Int) -> [WeekVolume] {
        let thisWeek = Day.weekStart(Date())
        return (0..<weeks).reversed().flatMap { offset -> [WeekVolume] in
            let start = Day.add(-7 * offset, to: thisWeek)
            let end = Day.add(7, to: start)
            return trainingSports.map { sport in
                let hours = workouts.filter { $0.sport == sport && $0.start >= start && $0.start < end }.reduce(0) { $0 + $1.durationS } / 3600
                return WeekVolume(weekStart: start, sport: sport, hours: (hours * 10).rounded() / 10)
            }
        }
    }

    static func averageWeeklyHours(_ volumes: [WeekVolume]) -> Double {
        let weeks = Set(volumes.map(\.weekStart)).count
        guard weeks > 0 else { return 0 }
        return volumes.reduce(0) { $0 + $1.hours } / Double(weeks)
    }

    // MARK: Records

    struct Record: Identifiable {
        let sport: Sport
        let title: String
        let value: String
        let date: Date
        var id: String { sport.rawValue + title }
        var isNew: Bool { date > Day.add(-14, to: Date()) }
    }

    static func records(_ workouts: [WorkoutSummary]) -> [Record] {
        var result: [Record] = []
        let runs = workouts.filter { $0.sport == .course }
        if let longest = runs.max(by: { ($0.distanceM ?? 0) < ($1.distanceM ?? 0) }), let d = longest.distanceM {
            result.append(Record(sport: .course, title: String(localized: "Plus longue sortie"), value: "\(Fmt.km(d)) km", date: longest.start))
        }
        let tenK = runs.filter { ($0.distanceM ?? 0) >= 9800 }.min { ($0.paceSecPerKm ?? .max) < ($1.paceSecPerKm ?? .max) }
        if let tenK, let pace = tenK.paceSecPerKm {
            result.append(Record(sport: .course, title: String(localized: "10 km (meilleure allure)"), value: Fmt.clock(Double(pace * 10)), date: tenK.start))
        }
        let fiveK = runs.filter { ($0.distanceM ?? 0) >= 4900 }.min { ($0.paceSecPerKm ?? .max) < ($1.paceSecPerKm ?? .max) }
        if let fiveK, let pace = fiveK.paceSecPerKm {
            result.append(Record(sport: .course, title: String(localized: "Allure la plus rapide (5 km+)"), value: "\(Fmt.pace(pace)) /km", date: fiveK.start))
        }
        if let ride = workouts.filter({ $0.sport == .velo }).max(by: { ($0.distanceM ?? 0) < ($1.distanceM ?? 0) }), let d = ride.distanceM {
            result.append(Record(sport: .velo, title: String(localized: "Plus longue sortie"), value: "\(Fmt.km(d, decimals: 0)) km", date: ride.start))
        }
        if let swim = workouts.filter({ $0.sport == .natation }).max(by: { ($0.distanceM ?? 0) < ($1.distanceM ?? 0) }), let d = swim.distanceM {
            result.append(Record(sport: .natation, title: String(localized: "Plus longue nage"), value: "\(Int(d)) m", date: swim.start))
        }
        return result
    }

    // MARK: Goal projection

    /// Race distance guessed from the goal title.
    static func goalDistanceKm(_ goal: Goal?) -> Double? {
        guard let title = goal?.title.lowercased() else { return nil }
        if title.contains("semi") || title.contains("half") { return 21.0975 }
        if title.contains("marathon") { return 42.195 }
        if let match = title.firstMatch(of: #/(\d+([.,]\d+)?)\s*km/#), let km = Double(match.1.replacingOccurrences(of: ",", with: ".")) { return km }
        return nil
    }

    /// Riegel projection from the best recent run of 5 km or more.
    static func projectedTime(_ workouts: [WorkoutSummary], goal: Goal?) -> TimeInterval? {
        guard let distance = goalDistanceKm(goal) else { return nil }
        let recent = workouts.filter { $0.sport == .course && ($0.distanceM ?? 0) >= 5000 && $0.start > Day.add(-42, to: Date()) }
        let estimates = recent.map { w in w.durationS * pow(distance * 1000 / (w.distanceM ?? 1), 1.06) }
        return estimates.min()
    }

    /// "1 h 45" / "1:45:00" / "45:00" → seconds.
    static func parseTime(_ text: String?) -> TimeInterval? {
        guard let text = text?.lowercased().replacingOccurrences(of: " ", with: "") else { return nil }
        if let m = text.firstMatch(of: #/^(\d+)h(\d{1,2})?$/#) {
            return Double(Int(m.1)! * 3600 + Int(m.2 ?? "0")! * 60)
        }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        if parts.count == 3 { return Double(parts[0] * 3600 + parts[1] * 60 + parts[2]) }
        if parts.count == 2 { return Double(parts[0] * 60 + parts[1]) }
        return nil
    }

    static func formatRaceTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? "\(total / 3600) h \(String(format: "%02d", (total % 3600) / 60))" : Fmt.clock(seconds)
    }

    // MARK: Misc

    static func kmThisMonth(_ workouts: [WorkoutSummary]) -> Double {
        let start = Day.calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        return workouts.filter { $0.start >= start && $0.sport.hasDistance && $0.sport != .natation }.reduce(0) { $0 + ($1.distanceM ?? 0) } / 1000
    }

    /// Consecutive weeks (up to this one) with at least one workout.
    static func weekStreak(_ workouts: [WorkoutSummary]) -> Int {
        var streak = 0
        var start = Day.weekStart(Date())
        while workouts.contains(where: { $0.start >= start && $0.start < Day.add(7, to: start) }) {
            streak += 1
            start = Day.add(-7, to: start)
        }
        return streak
    }

    static func latestVO2(_ metrics: [DailyMetrics]) -> (value: Double, delta: Double?)? {
        let series = metrics.filter { $0.vo2max != nil }.sorted { $0.date < $1.date }
        guard let last = series.last?.vo2max else { return nil }
        let first = series.first?.vo2max
        return (last, first.map { last - $0 })
    }

    /// Planned minutes per sport for a set of sessions.
    static func plannedMinutes(_ sessions: [Session]) -> [(sport: Sport, minutes: Int)] {
        trainingSports.compactMap { sport in
            let minutes = sessions.filter { $0.sport == sport }.reduce(0) { $0 + $1.durationMin }
            return minutes > 0 ? (sport, minutes) : nil
        }
    }

    /// Segments for IntensityBar: repeats expanded into work + recovery.
    static func segments(_ steps: [Step], sport: Sport) -> [(minutes: Double, zone: Int)] {
        steps.flatMap { step -> [(minutes: Double, zone: Int)] in
            let work = minutes(durationMin: step.seconds.map { Double($0) / 60 }, distanceM: step.distanceM, zone: step.zone, sport: sport)
            var result: [(minutes: Double, zone: Int)] = []
            for index in 0..<step.repeatCount {
                result.append((work, step.zone))
                if let recovery = step.recovery, index < step.repeatCount - 1 {
                    result.append((minutes(durationMin: recovery.seconds.map { Double($0) / 60 }, distanceM: recovery.distanceM, zone: recovery.zone, sport: sport), recovery.zone))
                }
            }
            return result
        }
    }

    /// Rough duration of a distance-based step, for drawing.
    static func minutes(durationMin: Double?, distanceM: Double?, zone: Int, sport: Sport) -> Double {
        if let durationMin { return durationMin }
        guard let distanceM else { return 5 }
        switch sport {
        case .natation: return distanceM / 100 * 2
        case .velo: return distanceM / 1000 * 2.2
        default: return distanceM / 1000 * (zone >= 4 ? 4.2 : 5.5)
        }
    }
}
