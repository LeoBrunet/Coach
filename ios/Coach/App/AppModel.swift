import SwiftUI
import os

let log = Logger(subsystem: "com.leobrunet.coach", category: "app")

@MainActor @Observable
final class AppModel {
    // MARK: Configuration

    static let defaultServerURL: URL = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CoachServerURL") as? String
        return URL(string: value ?? "") ?? URL(string: "http://localhost:8787")!
    }()

    var serverURL: URL {
        didSet { UserDefaults.standard.set(serverURL.absoluteString, forKey: "serverURL") }
    }

    var onboarded: Bool {
        didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") }
    }

    private(set) var token: String? = Keychain.get("appToken")

    // MARK: Data

    var state: ServerState? {
        // Popote reads the plan to set daily calorie and carb targets.
        didSet { if let state { PlanShare.write(sessions: state.sessions, goal: state.profile.goal) } }
    }
    var workouts: [WorkoutSummary] = []
    var metrics: [DailyMetrics] = []
    var connectorURL: String?
    var healthAsked = false
    var isRefreshing = false
    var lastError: String?
    var lastSync: Date?
    var isSeeding = false
    var selectedTab = Tab.today

    enum Tab: Hashable { case today, program, progress, profile }

    let health = HealthService()

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL").flatMap(URL.init(string:)) ?? Self.defaultServerURL
        onboarded = UserDefaults.standard.bool(forKey: "onboarded")
    }

    private var api: APIClient { APIClient(baseURL: serverURL, token: token) }

    // MARK: Lifecycle

    func bootstrap() async {
        log.info("bootstrap: start (server \(self.serverURL.absoluteString, privacy: .public))")
        // Never let a slow HealthKit status call block registration.
        healthAsked = await withTimeout(seconds: 3, fallback: false) { [health] in await health.hasBeenAsked() }
        log.info("bootstrap: healthAsked=\(self.healthAsked)")
        do {
            try await ensureRegistered()
            // The coach writes in the language the app is shown in.
            let language = Bundle.main.preferredLocalizations.first ?? "fr"
            if state?.profile.timezone != TimeZone.current.identifier || state?.profile.language != language {
                var patch = Profile()
                patch.timezone = TimeZone.current.identifier
                patch.language = language
                try await api.patchProfile(patch)
            }
        } catch {
            log.error("bootstrap: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        log.info("bootstrap: registered, refreshing")
        await refresh()
    }

    func ensureRegistered() async throws {
        if token == nil {
            let registration = try await api.register()
            token = registration.appToken
            Keychain.set("appToken", registration.appToken)
            connectorURL = registration.connectorUrl
        }
        if connectorURL == nil {
            connectorURL = try await api.me().connectorUrl
        }
    }

    /// Reads Apple Health, uploads it, then fetches what the coach wrote.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await ensureRegistered()
            state = try await api.state()
            if healthAsked, HealthService.isAvailable {
                async let workouts = health.workouts(since: Day.add(-180, to: Date()), maxHr: maxHr)
                async let metrics = health.dailyMetrics(days: 60)
                (self.workouts, self.metrics) = try await (workouts, metrics)
                try await api.sync(workouts: self.workouts, metrics: self.metrics)
                lastSync = Date()
            }
            state = try await api.state()
            log.notice("refresh: sessions=\(self.state?.sessions.count ?? -1) analyses=\(self.state?.analyses.count ?? -1)")
            connectorURL = state?.connectorUrl
            lastError = nil
        } catch {
            log.error("refresh: \(String(describing: error), privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func refreshState() async {
        do {
            state = try await api.state()
            log.notice("refreshState: sessions=\(self.state?.sessions.count ?? -1) analyses=\(self.state?.analyses.count ?? -1)")
            lastError = nil
        } catch {
            log.error("refreshState: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func requestHealthAccess() async {
        do {
            try await health.requestAuthorization()
            healthAsked = true
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Used by the onboarding screen to detect Claude's first call to the connector.
    func checkClaudeConnection() async -> Bool {
        guard let me = try? await api.me() else { return false }
        connectorURL = me.connectorUrl
        if me.claude.isConnected { await refreshState() }
        return me.claude.isConnected
    }

    func resetAccount() {
        Keychain.set("appToken", nil)
        token = nil
        connectorURL = nil
        state = nil
        onboarded = false
    }

    // MARK: Actions

    func saveProfile(_ profile: Profile) async -> Bool {
        do {
            try await api.patchProfile(profile)
            await refreshState()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func sendCheckin(feeling: Int, note: String?, session: Session?) async -> Bool {
        do {
            try await api.checkin(date: Day.today, feeling: feeling, note: note, sessionId: session?.id)
            await refreshState()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func setRPE(_ rpe: Int, for workoutId: String) async {
        do {
            try await api.setRPE(workoutId: workoutId, rpe: rpe)
            state?.rpe[workoutId] = rpe
        } catch {
            lastError = error.localizedDescription
        }
    }

    #if DEBUG
    func seedDemoData() async {
        isSeeding = true
        defer { isSeeding = false }
        do {
            try await health.requestAuthorization()
            healthAsked = true
            try await DemoData.seed(into: health.store, maxHr: maxHr)
            await refresh()
        } catch {
            lastError = String(localized: "Données de démo : \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: Derived data

    var profile: Profile { state?.profile ?? Profile() }
    var claude: ClaudeStatus { state?.claude ?? ClaudeStatus() }
    var sessions: [Session] { state?.sessions ?? [] }

    /// Profile value, else the highest HR seen recently (never below 185: easy sessions underestimate it).
    var maxHr: Int {
        if let max = profile.maxHr { return max }
        let observed = workouts.compactMap(\.maxHr).max().map { Int($0.rounded()) } ?? 0
        return max(observed, 185)
    }

    func sessions(on date: Date) -> [Session] {
        let day = Day.string(date)
        return sessions.filter { $0.date == day }
    }

    func workouts(on date: Date) -> [WorkoutSummary] {
        let day = Day.string(date)
        return workouts.filter { $0.localDate == day }
    }

    func workout(id: String?) -> WorkoutSummary? {
        guard let id else { return nil }
        return workouts.first { $0.id == id }
    }

    func session(forWorkout id: String) -> Session? {
        sessions.first { $0.workoutId == id }
    }

    func analysis(for workoutId: String) -> Analysis? {
        state?.analyses.first { $0.workoutId == workoutId }
    }

    var note: CoachNote? { state?.note }

    var programUpdatedAt: Date? {
        sessions.compactMap { ISO8601DateFormatter.flexible.date(from: $0.updatedAt) }.max()
    }
}

/// Runs `operation`, giving up after `seconds` with `fallback`.
/// (Unstructured on purpose: a task group would still wait for a call that never returns.)
func withTimeout<T: Sendable>(seconds: Double, fallback: T, _ operation: @escaping @Sendable () async -> T) async -> T {
    let once = OnceFlag()
    return await withCheckedContinuation { continuation in
        Task {
            let value = await operation()
            if once.claim() { continuation.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if once.claim() { continuation.resume(returning: fallback) }
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
