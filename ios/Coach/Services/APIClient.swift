import Foundation
import Security

enum APIError: LocalizedError {
    case http(Int, String)
    case notRegistered

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): String(localized: "Erreur serveur (\(code)) : \(String(body.prefix(200)))")
        case .notRegistered: String(localized: "Appareil non enregistré auprès du serveur.")
        }
    }
}

/// Talks to the Coach server (server/src/api.ts).
struct APIClient {
    var baseURL: URL
    var token: String?

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    struct Registration: Decodable {
        let appToken: String
        let connectorUrl: String
    }

    struct Me: Decodable {
        let connectorUrl: String
        let claude: ClaudeStatus
        let profile: Profile
    }

    func register() async throws -> Registration {
        try await send("POST", "/api/register", body: Optional<String>.none, authenticated: false)
    }

    func me() async throws -> Me { try await send("GET", "/api/me") }

    func state() async throws -> ServerState { try await send("GET", "/api/state") }

    @discardableResult
    func patchProfile(_ profile: Profile) async throws -> Profile { try await send("PATCH", "/api/profile", body: profile) }

    func sync(workouts: [WorkoutSummary], metrics: [DailyMetrics]) async throws {
        struct Body: Encodable { let workouts: [WorkoutSummary]; let dailyMetrics: [DailyMetrics] }
        struct Result: Decodable { let workouts: Int }
        let _: Result = try await send("POST", "/api/sync", body: Body(workouts: workouts, dailyMetrics: metrics))
    }

    func checkin(date: String, feeling: Int, note: String?, sessionId: String?) async throws {
        struct Body: Encodable { let date: String; let feeling: Int; let note: String?; let sessionId: String? }
        let _: Checkin = try await send("POST", "/api/checkins", body: Body(date: date, feeling: feeling, note: note, sessionId: sessionId))
    }

    func setRPE(workoutId: String, rpe: Int) async throws {
        struct Body: Encodable { let rpe: Int }
        struct Result: Decodable { let ok: Bool }
        let id = workoutId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workoutId
        let _: Result = try await send("PUT", "/api/workouts/\(id)/rpe", body: Body(rpe: rpe))
    }

    private func send<Response: Decodable>(_ method: String, _ path: String, authenticated: Bool = true) async throws -> Response {
        try await send(method, path, body: Optional<String>.none, authenticated: authenticated)
    }

    private func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, body: Body?, authenticated: Bool = true) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let token else { throw APIError.notRegistered }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { request.httpBody = try Self.encoder.encode(body) }
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status, String(decoding: data, as: UTF8.self))
        }
        return try Self.decoder.decode(Response.self, from: data)
    }
}

enum Keychain {
    private static let service = "com.leobrunet.coach"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
