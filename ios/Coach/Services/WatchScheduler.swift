import Foundation
import HealthKit
import WorkoutKit

/// Sends a planned session to the Apple Watch Workout app as a structured custom workout.
enum WatchScheduler {
    enum Failure: LocalizedError {
        case unsupportedSport(String)
        case notAuthorized
        case noSteps

        var errorDescription: String? {
            switch self {
            case .unsupportedSport(let sport): String(localized: "L'app Exercice de l'Apple Watch ne gère pas encore les séances structurées de \(sport.lowercased()).")
            case .notAuthorized: String(localized: "Coach n'a pas encore le droit d'envoyer des séances sur ta montre. Sur ton iPhone, ouvre l'app Watch › Exercice et autorise Coach, puis réessaie.")
            case .noSteps: String(localized: "Cette séance n'a pas encore d'étapes détaillées. Demande au coach de la préciser.")
            }
        }
    }

    static var isSupported: Bool { WorkoutScheduler.isSupported }

    static func authorizationState() async -> WorkoutScheduler.AuthorizationState {
        await WorkoutScheduler.shared.authorizationState
    }

    /// Schedules the session on its day (7:00, or right away if it's today).
    @discardableResult
    static func send(_ session: Session) async throws -> DateComponents {
        let workout = try makeWorkout(session)
        var state = await WorkoutScheduler.shared.authorizationState
        if state != .authorized {
            state = await WorkoutScheduler.shared.requestAuthorization()
        }
        guard state == .authorized else { throw Failure.notAuthorized }

        let calendar = Calendar.current
        let day = session.day ?? Date()
        var when = calendar.dateComponents([.year, .month, .day], from: day)
        if calendar.isDateInToday(day) {
            let soon = Date().addingTimeInterval(60)
            when.hour = calendar.component(.hour, from: soon)
            when.minute = calendar.component(.minute, from: soon)
        } else {
            when.hour = 7
            when.minute = 0
        }
        // Re-sending replaces the previous version of the same session on that day.
        for scheduled in await WorkoutScheduler.shared.scheduledWorkouts {
            guard case .custom(let existing) = scheduled.plan.workout, existing.displayName == session.title,
                  scheduled.date.year == when.year, scheduled.date.month == when.month, scheduled.date.day == when.day else { continue }
            await WorkoutScheduler.shared.remove(scheduled.plan, at: scheduled.date)
        }
        await WorkoutScheduler.shared.schedule(WorkoutPlan(.custom(workout)), at: when)
        return when
    }

    static func makeWorkout(_ session: Session) throws -> CustomWorkout {
        let (activity, location): (HKWorkoutActivityType, HKWorkoutSessionLocationType) = switch session.sport {
        case .course: (.running, .outdoor)
        case .velo: (.cycling, .outdoor)
        case .natation: (.swimming, .indoor)
        case .muscu: (.traditionalStrengthTraining, .indoor)
        case .repos: (.other, .unknown)
        }
        guard session.sport != .repos, CustomWorkout.supportsActivity(activity) else {
            throw Failure.unsupportedSport(session.sport.label)
        }
        let steps = session.steps ?? []
        guard !steps.isEmpty else { throw Failure.noSteps }

        var warmup: WorkoutStep?
        var cooldown: WorkoutStep?
        var blocks: [IntervalBlock] = []
        for (index, step) in steps.enumerated() {
            let goal = goal(seconds: step.seconds, distanceM: step.distanceM)
            // No alerts (they buzz in the AirPods all session long): the step's own target goes in its name instead.
            let name = displayName(step.name, target: step.target, sport: session.sport)
            if step.kind == "warmup", index == 0 {
                warmup = workoutStep(goal: goal, name: name)
            } else if step.kind == "cooldown", index == steps.count - 1 {
                cooldown = workoutStep(goal: goal, name: name)
            } else {
                var intervalSteps = [IntervalStep(.work, step: workoutStep(goal: goal, name: name))]
                if let recovery = step.recovery {
                    let recoveryGoal = self.goal(seconds: recovery.seconds, distanceM: recovery.distanceM)
                    intervalSteps.append(IntervalStep(.recovery, step: workoutStep(goal: recoveryGoal, name: String(localized: "Récup"))))
                }
                blocks.append(IntervalBlock(steps: intervalSteps, iterations: step.repeatCount))
            }
        }
        return CustomWorkout(
            activity: activity,
            location: location,
            displayName: session.title,
            warmup: warmup,
            blocks: blocks,
            cooldown: cooldown
        )
    }

    /// "Échauffement · 6:40 /km" — or just the name when the step has no target of its own.
    static func displayName(_ name: String, target: Target?, sport: Sport) -> String {
        if sport == .course, let pace = target?.paceSecPerKm { return "\(name) · \(Fmt.pace(pace)) /km" }
        if sport == .natation, let pace = target?.swimPaceSecPer100m { return "\(name) · \(Fmt.pace(pace)) /100 m" }
        if sport == .velo, let speed = target?.speedKmh { return "\(name) · \(Fmt.number(speed)) km/h" }
        return name
    }

    private static func workoutStep(goal: WorkoutGoal, name: String) -> WorkoutStep {
        if #available(iOS 18.0, *) {
            return WorkoutStep(goal: goal, displayName: name)
        }
        return WorkoutStep(goal: goal)
    }

    /// Exact seconds (a 20 s stride stays 20 s, not 19).
    private static func goal(seconds: Int?, distanceM: Double?) -> WorkoutGoal {
        if let distanceM { return .distance(distanceM, .meters) }
        if let seconds { return .time(Double(seconds), .seconds) }
        return .open
    }
}
