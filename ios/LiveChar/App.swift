import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = WebViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    // keep the screen awake while the app is open (a live session should not be cut by auto-lock)
    func sceneDidBecomeActive(_ scene: UIScene) { UIApplication.shared.isIdleTimerDisabled = true }
    func sceneWillResignActive(_ scene: UIScene) { UIApplication.shared.isIdleTimerDisabled = false }
}

/// Which LiveChar server the app opens. Built-in address (Info.plist, set by CI) unless the user picked one.
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

    static var saved: String { UserDefaults.standard.string(forKey: key) ?? "" }

    /// Empty string = go back to the built-in address.
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
