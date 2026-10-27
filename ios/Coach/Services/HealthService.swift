import Foundation
import HealthKit
import CoreLocation

/// Reads the athlete's data from Apple Health (written by the Apple Watch).
final class HealthService {
    let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let heartRate = HKQuantityType(.heartRate)
    private let hrv = HKQuantityType(.heartRateVariabilitySDNN)
    private let restingHR = HKQuantityType(.restingHeartRate)
    private let vo2max = HKQuantityType(.vo2Max)
    private let energy = HKQuantityType(.activeEnergyBurned)
    private let runDistance = HKQuantityType(.distanceWalkingRunning)
    private let bikeDistance = HKQuantityType(.distanceCycling)
    private let swimDistance = HKQuantityType(.distanceSwimming)
    private let sleep = HKCategoryType(.sleepAnalysis)

    private var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute(), heartRate, hrv, restingHR, vo2max, energy, runDistance, bikeDistance, swimDistance, sleep]
    }

    /// Write access is only requested in debug builds (to generate demo data in the simulator).
    private var shareTypes: Set<HKSampleType> {
        #if DEBUG
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute(), heartRate, hrv, restingHR, vo2max, energy, runDistance, bikeDistance, swimDistance, sleep]
        #else
        []
        #endif
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    /// HealthKit never says whether *read* access was granted; we only know if the user was asked.
    func hasBeenAsked() async -> Bool {
        let status = try? await store.statusForAuthorizationRequest(toShare: shareTypes, read: readTypes)
        return status == .unnecessary
    }

    // MARK: Workouts

    static func sport(for type: HKWorkoutActivityType) -> Sport? {
        switch type {
        case .running: .course
        case .cycling: .velo
        case .swimming: .natation
        case .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining, .highIntensityIntervalTraining: .muscu
        default: nil
        }
    }

    private func distanceType(for sport: Sport) -> HKQuantityType? {
        switch sport {
        case .course: runDistance
        case .velo: bikeDistance
        case .natation: swimDistance
        default: nil
        }
    }

    func workouts(since start: Date, maxHr: Int) async throws -> [WorkoutSummary] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 400
        )
        let workouts = try await descriptor.result(for: store)
        var result: [WorkoutSummary] = []
        let detailsCutoff = Day.add(-60, to: Date())
        for workout in workouts {
            guard let sport = Self.sport(for: workout.workoutActivityType) else { continue }
            let distance = distanceType(for: sport).flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
            let hrUnit = HKUnit.count().unitDivided(by: .minute())
            let hrStats = workout.statistics(for: heartRate)
            var summary = WorkoutSummary(
                id: workout.uuid.uuidString,
                sport: sport,
                start: workout.startDate,
                end: workout.endDate,
                localDate: Day.string(workout.startDate),
                durationS: workout.duration,
                distanceM: distance,
                energyKcal: workout.statistics(for: energy)?.sumQuantity()?.doubleValue(for: .kilocalorie()),
                avgHr: hrStats?.averageQuantity()?.doubleValue(for: hrUnit),
                maxHr: hrStats?.maximumQuantity()?.doubleValue(for: hrUnit),
                elevationM: (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()),
                details: WorkoutDetails()
            )
            // Detailed data (laps, zones) for recent workouts only: it costs extra queries.
            if workout.startDate > detailsCutoff {
                summary.details.zonesMin = try? await zones(for: workout, maxHr: maxHr)
                summary.details.laps = try? await laps(for: workout, sport: sport)
            }
            result.append(summary)
        }
        return result
    }

    /// Intervals of a structured workout (segments), or manual laps.
    private func laps(for workout: HKWorkout, sport: Sport) async throws -> [Lap]? {
        let events = workout.workoutEvents ?? []
        var intervals = events.filter { $0.type == .segment }.map(\.dateInterval)
        if intervals.isEmpty { intervals = events.filter { $0.type == .lap }.map(\.dateInterval) }
        guard !intervals.isEmpty, intervals.count <= 60 else { return nil }
        var laps: [Lap] = []
        for (index, interval) in intervals.enumerated() {
            var distance: Double?
            if let type = distanceType(for: sport) {
                let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
                let query = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate), options: .cumulativeSum)
                distance = try await query.result(for: store)?.sumQuantity()?.doubleValue(for: .meter())
            }
            laps.append(Lap(index: index + 1, durationS: interval.duration, distanceM: distance))
        }
        return laps
    }

    /// Minutes spent in each heart-rate zone (Z1…Z5, as % of max HR).
    private func zones(for workout: HKWorkout, maxHr: Int) async throws -> [Double]? {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: heartRate, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        guard samples.count > 2 else { return nil }
        var minutes = [Double](repeating: 0, count: 5)
        let unit = HKUnit.count().unitDivided(by: .minute())
        for (index, sample) in samples.enumerated() {
            let next = index + 1 < samples.count ? samples[index + 1].startDate : workout.endDate
            let seconds = min(max(next.timeIntervalSince(sample.startDate), 0), 30)
            let bpm = sample.quantity.doubleValue(for: unit)
            minutes[HRZones.zone(for: bpm, maxHr: maxHr) - 1] += seconds / 60
        }
        return minutes.map { ($0 * 10).rounded() / 10 }
    }

    func route(forWorkoutID id: String) async throws -> [CLLocation] {
        guard let uuid = UUID(uuidString: id) else { return [] }
        let workoutQuery = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForObject(with: uuid))], sortDescriptors: [], limit: 1)
        guard let workout = try await workoutQuery.result(for: store).first else { return [] }
        let routeQuery = HKSampleQueryDescriptor(predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))], sortDescriptors: [], limit: 1)
        guard let route = try await routeQuery.result(for: store).first else { return [] }
        var locations: [CLLocation] = []
        for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
            locations.append(location)
        }
        return locations
    }

    // MARK: Daily metrics

    func dailyMetrics(days: Int) async throws -> [DailyMetrics] {
        let end = Day.calendar.startOfDay(for: Day.add(1, to: Date()))
        let start = Day.add(-days, to: end)
        async let hrvByDay = dailyAverage(hrv, unit: .secondUnit(with: .milli), from: start, to: end)
        async let restingByDay = dailyAverage(restingHR, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end)
        async let vo2ByDay = dailyAverage(vo2max, unit: HKUnit(from: "ml/kg*min"), from: start, to: end)
        async let sleepByDay = sleepMinutes(from: start, to: end)
        let (h, r, v, s) = try await (hrvByDay, restingByDay, vo2ByDay, sleepByDay)
        let dates = Set(h.keys).union(r.keys).union(v.keys).union(s.keys)
        return dates.sorted().map { DailyMetrics(date: $0, sleepMin: s[$0], hrvMs: h[$0], restingHr: r[$0], vo2max: v[$0]) }
    }

    private func dailyAverage(_ type: HKQuantityType, unit: HKUnit, from start: Date, to end: Date) async throws -> [String: Double] {
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: .discreteAverage,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: store)
        var result: [String: Double] = [:]
        collection.enumerateStatistics(from: start, to: end) { statistics, _ in
            if let value = statistics.averageQuantity()?.doubleValue(for: unit) {
                result[Day.string(statistics.startDate)] = (value * 10).rounded() / 10
            }
        }
        return result
    }

    /// Sleep is attributed to the day you wake up.
    private func sleepMinutes(from start: Date, to end: Date) async throws -> [String: Double] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleep, predicate: HKQuery.predicateForSamples(withStart: Day.add(-1, to: start), end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        var result: [String: Double] = [:]
        for sample in try await descriptor.result(for: store) where asleep.contains(sample.value) {
            // A night going past midnight counts for the morning you wake up.
            let day = Day.string(sample.endDate)
            result[day, default: 0] += sample.endDate.timeIntervalSince(sample.startDate) / 60
        }
        return result.mapValues { $0.rounded() }
    }
}

/// Heart-rate zones as a share of max HR.
enum HRZones {
    static let bounds: [Double] = [0.68, 0.78, 0.85, 0.92]

    static func zone(for bpm: Double, maxHr: Int) -> Int {
        let ratio = bpm / Double(maxHr)
        return (bounds.firstIndex { ratio < $0 } ?? 4) + 1
    }

    /// Lower bpm bound of each zone 2…5.
    static func limits(maxHr: Int) -> [Int] { bounds.map { Int((Double(maxHr) * $0).rounded()) } }

    static func ranges(maxHr: Int) -> [String] {
        let l = limits(maxHr: maxHr)
        return ["< \(l[0]) bpm", "\(l[0])–\(l[1] - 1)", "\(l[1])–\(l[2] - 1)", "\(l[2])–\(l[3] - 1)", "> \(l[3])"]
    }

    static let names = [String(localized: "Récupération"), String(localized: "Endurance"), String(localized: "Tempo"), String(localized: "Seuil"), String(localized: "VMA")]
}
