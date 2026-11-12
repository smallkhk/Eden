import Foundation

/// Which LiveChar server the app talks to. Built-in address (Info.plist, set by CI) unless the user picked one.
enum Server {
    private static let key = "livechar.url"

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), let host = u.host, !host.isEmpty else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        guard u.scheme == "https" || (u.scheme == "http" && local) else { return nil }
        var c = URLComponents()
        c.scheme = u.scheme; c.host = host; c.port = u.port; c.path = "/"
        return c.url
    }

    static var builtIn: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "LiveCharURL") as? String).flatMap(normalize)
    }

    static var current: URL? {
        if let s = UserDefaults.standard.string(forKey: key), let u = normalize(s) { return u }
        return builtIn
    }

    /// Empty = back to the built-in address.
    @discardableResult
    static func save(_ raw: String) -> URL? {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return builtIn
        }
        guard let u = normalize(raw) else { return nil }
        UserDefaults.standard.set(u.absoluteString, forKey: key)
        return u
    }
}

struct APIError: LocalizedError {
    let message: String
    let status: Int
    var errorDescription: String? { message }
}

extension Notification.Name {
    static let lcLoggedOut = Notification.Name("lcLoggedOut")
}

/// JSON API of the LiveChar server. Login is the server's session cookie, kept in the shared cookie store.
final class API {
    static let shared = API()
    let session: URLSession

    private init() {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = .shared
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .always
        c.timeoutIntervalForRequest = 45
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    func url(_ path: String) throws -> URL {
        guard let base = Server.current, let u = URL(string: path, relativeTo: base) else {
            throw APIError(message: "Set your LiveChar server first", status: 0)
        }
        return u.absoluteURL
    }

    func request(_ path: String, method: String = "GET", json: [String: Any]? = nil) throws -> URLRequest {
        var r = URLRequest(url: try url(path))
        r.httpMethod = method
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    @discardableResult
    func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            let path = req.url?.path ?? ""
            if code == 401, path != "/api/login", path != "/api/register" {
                await MainActor.run { NotificationCenter.default.post(name: .lcLoggedOut, object: nil) }
            }
            throw APIError(message: msg ?? "Server error (HTTP \(code))", status: code)
        }
        return data
    }

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(try request(path)))
    }

    func post<T: Decodable>(_ path: String, _ body: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(try request(path, method: "POST", json: body)))
    }

    func post(_ path: String, _ body: [String: Any] = [:]) async throws {
        try await send(try request(path, method: "POST", json: body))
    }

    func delete(_ path: String) async throws {
        try await send(try request(path, method: "DELETE"))
    }

    func data(_ path: String) async throws -> Data {
        try await send(try request(path))
    }

    func logout() async {
        _ = try? await send(try request("/api/logout", method: "POST", json: [:]))
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }
}

// MARK: - models (match server.js)

struct User: Codable, Equatable {
    let id: Int
    let username: String
    let email: String?
    let isAdmin: Bool
    var balance: Double
}

struct AppConfig: Codable {
    struct Engines: Codable { let lucy: Bool; let eden: Bool }
    let user: User?
    let hasUsers: Bool
    let allowSignup: Bool
    let maxSessionSeconds: Double
    let lucyModel: String
    let lucyFast: Bool
    let engines: Engines
    let canReset: Bool?
    let rates: [String: Double]
}

struct UserResponse: Codable { let user: User }
struct SessionStart: Codable { let id: String; let rate: Double; let maxSeconds: Double; let balance: Double }
struct BeatResponse: Codable { let balance: Double?; let ended: Bool? }
struct DecartToken: Codable { let apiKey: String }
struct FirstFrame: Codable { let url: String; let balance: Double? }

struct Character: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let prompt: String
    let preset: Int
    var isPreset: Bool { preset != 0 }
}
struct CharactersResponse: Codable { let characters: [Character] }

struct LedgerEntry: Codable, Identifiable {
    let delta: Double
    let reason: String
    let created_at: Double
    var id: String { "\(created_at)-\(reason)-\(delta)" }
}
struct SessionRow: Codable, Identifiable {
    let engine: String
    let started_at: Double
    let ended_at: Double?
    let last_beat: Double
    let charged: Double
    var id: Double { started_at }
}
struct AccountResponse: Codable {
    let user: User
    let sessions: [SessionRow]
    let ledger: [LedgerEntry]
}

struct Package: Codable, Identifiable { let id: Int; let name: String; let seconds: Double; let price: Double }
struct Network: Codable, Identifiable { let id: String; let label: String }
struct PackagesResponse: Codable { let packages: [Package]; let networks: [Network] }

struct Order: Codable, Identifiable, Equatable {
    let id: String
    let package: String
    let seconds: Double
    let network: String
    let networkLabel: String
    let amount: String
    let address: String
    let status: String
    let txid: String
    let note: String
    let expiresAt: Double
    let qr: String
}
struct OrderResponse: Codable { let order: Order? }
struct ConfirmResponse: Codable { let status: String; let balance: Double?; let error: String? }
struct RedeemResponse: Codable { let seconds: Double; let balance: Double }

struct ShareInfo: Codable { let id: String; let url: String; let live: Bool?; let viewers: Int? }

func formatSeconds(_ v: Double) -> String {
    let s = max(0, Int(v))
    let h = s / 3600, m = (s % 3600) / 60
    var out = ""
    if h > 0 { out += "\(h)h " }
    if h > 0 || m > 0 { out += "\(m)m " }
    return out + "\(s % 60)s"
}
