#if DEBUG
import Foundation
import HealthKit
import CoreLocation

/// Writes 12 weeks of realistic workouts and recovery metrics into HealthKit (simulator / debug only),
/// so every screen can be exercised without an Apple Watch.
enum DemoData {
    static let marker = "CoachDemo"

    private struct Generator {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31)
        }
        mutating func around(_ value: Double, _ spread: Double) -> Double { value + (next() - 0.5) * 2 * spread }
    }

    static func seed(into store: HKHealthStore, maxHr: Int) async throws {
        // Already seeded?
        let existing = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForObjects(withMetadataKey: marker))],
            sortDescriptors: [], limit: 1
        )
        if try await !existing.result(for: store).isEmpty { return }

        var random = Generator(state: 42)
        let calendar = Day.calendar
        let today = calendar.startOfDay(for: Date())
        let firstMonday = Day.add(-7 * 11, to: Day.weekStart(today))

        for week in 0..<12 {
            let monday = Day.add(7 * week, to: firstMonday)
            let fitness = Double(week) / 11 // 0 → 1 over the block
            let plan: [(day: Int, hour: Int, kind: Kind)] = [
                (0, 18, .bike(minutes: 90)),
                (1, 18, .intervals(reps: 6, paceSec: Int(255 - 10 * fitness))),
                (2, 12, .strength(minutes: 45)),
                (3, 7, .easyRun(minutes: 40, paceSec: Int(345 - 22 * fitness))),
                (5, 10, .swim(meters: 1800)),
                (6, 9, .longRun(km: 14 + Double(week) * 0.6, paceSec: Int(355 - 20 * fitness))),
            ]
            for item in plan {
                let day = Day.add(item.day, to: monday)
                guard let start = calendar.date(bySettingHour: item.hour, minute: Int(random.next() * 40), second: 0, of: day),
                      start < Date().addingTimeInterval(-3 * 3600) else { continue }
                try await write(item.kind, start: start, maxHr: maxHr, random: &random, store: store)
            }
        }
        try await writeDailyMetrics(from: firstMonday, to: today, random: &random, store: store)
    }

    private enum Kind {
        case bike(minutes: Int)
        case intervals(reps: Int, paceSec: Int)
        case strength(minutes: Int)
        case easyRun(minutes: Int, paceSec: Int)
        case swim(meters: Int)
        case longRun(km: Double, paceSec: Int)
    }

    private static func write(_ kind: Kind, start: Date, maxHr: Int, random: inout Generator, store: HKHealthStore) async throws {
        let config = HKWorkoutConfiguration()
        var phases: [(seconds: Double, metersPerSecond: Double, hrRatio: Double)] = []
        var segments: [DateInterval] = []
        var distanceType = HKQuantityType(.distanceWalkingRunning)
        var withRoute = false
        var elevation: Double?

        switch kind {
        case .bike(let minutes):
            config.activityType = .cycling
            config.locationType = .outdoor
            distanceType = HKQuantityType(.distanceCycling)
            phases = [(Double(minutes) * 60, random.around(7.8, 0.4), 0.72)]
            withRoute = true
            elevation = random.around(380, 80)
        case .intervals(let reps, let paceSec):
            config.activityType = .running
            config.locationType = .outdoor
            phases.append((15 * 60, 1000 / 340, 0.72))
            var cursor = start.addingTimeInterval(15 * 60)
            for rep in 0..<reps {
                let fade = rep == reps - 1 ? 8.0 : random.around(1, 3)
                let seconds = 0.8 * Double(paceSec) + fade
                phases.append((seconds, 800 / seconds, 0.89))
                segments.append(DateInterval(start: cursor, duration: seconds))
                cursor = cursor.addingTimeInterval(seconds)
                if rep < reps - 1 {
                    phases.append((120, 1000 / 420, 0.7))
                    cursor = cursor.addingTimeInterval(120)
                }
            }
            phases.append((10 * 60, 1000 / 360, 0.68))
            withRoute = true
        case .strength(let minutes):
            config.activityType = .traditionalStrengthTraining
            config.locationType = .indoor
            phases = [(Double(minutes) * 60, 0, 0.62)]
        case .easyRun(let minutes, let paceSec):
            config.activityType = .running
            config.locationType = .outdoor
            phases = [(Double(minutes) * 60, 1000 / Double(paceSec), 0.74)]
            withRoute = true
        case .swim(let meters):
            config.activityType = .swimming
            config.swimmingLocationType = .pool
            config.lapLength = HKQuantity(unit: .meter(), doubleValue: 25)
            distanceType = HKQuantityType(.distanceSwimming)
            let seconds = Double(meters) / 100 * random.around(125, 5)
            phases = [(seconds, Double(meters) / seconds, 0.7)]
        case .longRun(let km, let paceSec):
            config.activityType = .running
            config.locationType = .outdoor
            let seconds = km * Double(paceSec)
            phases = [(seconds, km * 1000 / seconds, 0.76)]
            withRoute = true
            elevation = random.around(120, 40)
        }

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: start)

        var samples: [HKSample] = []
        var cursor = start
        let hrUnit = HKUnit.count().unitDivided(by: .minute())
        var totalMeters = 0.0
        for phase in phases {
            let end = cursor.addingTimeInterval(phase.seconds)
            // Distance: one sample per 30 s chunk (keeps segment distances accurate).
            if phase.metersPerSecond > 0 {
                var t = cursor
                while t < end {
                    let chunkEnd = min(t.addingTimeInterval(30), end)
                    let meters = phase.metersPerSecond * chunkEnd.timeIntervalSince(t)
                    totalMeters += meters
                    samples.append(HKQuantitySample(type: distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: meters), start: t, end: chunkEnd))
                    t = chunkEnd
                }
            }
            // Heart rate every 20 s, drifting slightly.
            var t = cursor
            while t < end {
                let bpm = Double(maxHr) * phase.hrRatio * random.around(1, 0.025)
                samples.append(HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: hrUnit, doubleValue: bpm), start: t, end: t))
                t = t.addingTimeInterval(20)
            }
            cursor = end
        }
        let end = cursor
        let kcal = end.timeIntervalSince(start) / 60 * random.around(11, 1.5)
        samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned), quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal), start: start, end: end))

        try await builder.addSamples(samples)
        if !segments.isEmpty {
            try await builder.addWorkoutEvents(segments.map { HKWorkoutEvent(type: .segment, dateInterval: $0, metadata: nil) })
        }
        var metadata: [String: Any] = [marker: true]
        if let elevation { metadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: elevation) }
        try await builder.addMetadata(metadata)
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else { return }

        if withRoute {
            let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
            try await routeBuilder.insertRouteData(loop(start: start, end: end, meters: totalMeters))
            try await routeBuilder.finishRoute(with: workout, metadata: nil)
        }
    }

    /// A loop around the Bois de Vincennes, scaled to the distance.
    private static func loop(start: Date, end: Date, meters: Double) -> [CLLocation] {
        let center = CLLocationCoordinate2D(latitude: 48.8305, longitude: 2.4330)
        let radius = max(meters / (2 * .pi), 400) / 111_000 // degrees
        let count = 120
        return (0...count).map { index in
            let angle = Double(index) / Double(count) * 2 * .pi
            let wobble = 1 + 0.12 * sin(angle * 5)
            let coordinate = CLLocationCoordinate2D(
                latitude: center.latitude + radius * wobble * sin(angle),
                longitude: center.longitude + radius * wobble * cos(angle) * 1.5
            )
            let time = start.addingTimeInterval(end.timeIntervalSince(start) * Double(index) / Double(count))
            return CLLocation(coordinate: coordinate, altitude: 50 + 25 * sin(angle * 3), horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: time)
        }
    }

    private static func writeDailyMetrics(from start: Date, to today: Date, random: inout Generator, store: HKHealthStore) async throws {
        var samples: [HKSample] = []
        var day = start
        var index = 0
        while day <= today {
            let progress = Double(index) / 84
            // Sleep: bedtime ~23:00 the evening before, split in stages.
            let bed = Day.add(-1, to: day).addingTimeInterval(23 * 3600 + random.around(0, 1800))
            let total = random.around(440, 45) * 60
            let stages: [(HKCategoryValueSleepAnalysis, Double)] = [(.asleepCore, 0.55), (.asleepDeep, 0.2), (.asleepREM, 0.25)]
            var t = bed
            for stage in stages {
                let duration = total * stage.1
                samples.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: stage.0.rawValue, start: t, end: t.addingTimeInterval(duration)))
                t = t.addingTimeInterval(duration)
            }
            let morning = day.addingTimeInterval(7 * 3600)
            samples.append(HKQuantitySample(type: HKQuantityType(.heartRateVariabilitySDNN), quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: random.around(58 + 10 * progress, 6)), start: morning, end: morning))
            samples.append(HKQuantitySample(type: HKQuantityType(.restingHeartRate), quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: random.around(52 - 4 * progress, 1.5)), start: morning, end: morning))
            if index % 4 == 0 {
                samples.append(HKQuantitySample(type: HKQuantityType(.vo2Max), quantity: HKQuantity(unit: HKUnit(from: "ml/kg*min"), doubleValue: 46 + 2.6 * progress + random.around(0, 0.15)), start: morning, end: morning))
            }
            day = Day.add(1, to: day)
            index += 1
        }
        try await store.save(samples)
    }
}
#endif
