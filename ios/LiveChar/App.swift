import SwiftUI

@main
struct LiveCharApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var live = LiveController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(live)
                .preferredColorScheme(.dark)
                .tint(Theme.you)
                .onAppear {
                    live.onBalance = { [weak app] b in app?.setBalance(b) }
                }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var config: AppConfig?
    @Published var user: User?
    @Published var loading = false
    @Published var error: String?
    @Published var needsServer = Server.current == nil

    init() {
        NotificationCenter.default.addObserver(forName: .lcLoggedOut, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.user = nil }
        }
    }

    func boot() async {
        guard Server.current != nil else { needsServer = true; return }
        loading = true; error = nil
        do {
            let c: AppConfig = try await API.shared.get("/api/config")
            config = c; user = c.user
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func setBalance(_ b: Double) { user?.balance = b }

    func refreshUser() async {
        if let c: AppConfig = try? await API.shared.get("/api/config") { config = c; user = c.user }
    }

    func logout() async {
        await API.shared.logout()
        user = nil
        await boot()
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var live: LiveController

    var body: some View {
        Group {
            if app.needsServer {
                ServerSetupView()
            } else if app.config == nil {
                SplashView()
            } else if app.user == nil {
                AuthView()
            } else {
                StudioView()
            }
        }
        .screenBackground()
        .task { await app.boot() }
        .onChange(of: app.config?.lucyModel) { _ in live.config = app.config }
        .onChange(of: app.user?.id) { _ in live.config = app.config }
    }
}

struct SplashView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Logo(size: 34)
            if app.loading { ProgressView().tint(Theme.you) }
            if let e = app.error {
                Text("Can't reach your LiveChar server").font(.headline).foregroundStyle(Theme.text)
                Text(e).font(.footnote).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                HStack {
                    Button("Retry") { Task { await app.boot() } }.buttonStyle(SoftButtonStyle())
                    Button("Change server") { app.needsServer = true }.buttonStyle(SoftButtonStyle(tint: Theme.dim))
                }
            }
            Spacer()
        }
        .padding(24)
    }
}

struct Logo: View {
    var size: CGFloat = 22
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Theme.you).frame(width: size * 0.62, height: size * 0.62).offset(x: -size * 0.18)
                Circle().fill(Theme.char).frame(width: size * 0.62, height: size * 0.62).offset(x: size * 0.18).blendMode(.screen)
            }
            .frame(width: size, height: size)
            Text("LiveChar").font(.system(size: size * 0.82, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
        }
    }
}

struct ServerSetupView: View {
    @EnvironmentObject var app: AppModel
    @State private var text = UserDefaults.standard.string(forKey: "livechar.url") ?? ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Logo(size: 34)
            Text("Your LiveChar server").font(.title3.bold()).foregroundStyle(Theme.text)
            Field(label: "Address", text: $text, keyboard: .URL, content: .URL)
            if let b = Server.builtIn { Text("Leave empty to use \(b.host ?? b.absoluteString)").font(.footnote).foregroundStyle(Theme.dim) }
            if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(Theme.bad) }
            Button("Continue") {
                guard Server.save(text) != nil else { error = "Enter a valid https:// address"; return }
                app.needsServer = false; app.config = nil
                Task { await app.boot() }
            }
            .buttonStyle(GoButtonStyle())
            Spacer(); Spacer()
        }
        .padding(24)
    }
}

struct AuthView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openURL) private var openURL
    @State private var register = false
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false

    private var firstAccount: Bool { app.config?.hasUsers == false }
    private var isRegister: Bool { register || firstAccount }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Logo(size: 34).padding(.top, 40)
                Text(firstAccount ? "Create the admin account" : isRegister ? "Create account" : "Log in")
                    .font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                Text("Webcam in, character out — live.").foregroundStyle(Theme.dim)
                Field(label: isRegister ? "Username" : "Username or email", text: $username, content: .username)
                if isRegister { Field(label: "Email (optional, for password reset)", text: $email, keyboard: .emailAddress, content: .emailAddress) }
                Field(label: "Password", text: $password, secure: true, content: isRegister ? .newPassword : .password)
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(Theme.bad) }
                Button {
                    Task { await submit() }
                } label: {
                    if busy { ProgressView().tint(Theme.ink) } else { Text(isRegister ? "Create account" : "Log in") }
                }
                .buttonStyle(GoButtonStyle())
                .disabled(busy || username.isEmpty || password.isEmpty)

                HStack {
                    if !firstAccount && (register || app.config?.allowSignup == true) {
                        Button(register ? "Have an account? Log in" : "New here? Create an account") { register.toggle(); error = "" }
                    }
                    Spacer()
                    if !isRegister, let base = Server.current { Button("Forgot password?") { openURL(base) } }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.you)
                Button("Server: \(Server.current?.host ?? "-")") { app.needsServer = true }
                    .font(.footnote).foregroundStyle(Theme.dim).padding(.top, 20)
            }
            .padding(24)
        }
    }

    private func submit() async {
        busy = true; error = ""
        do {
            var body: [String: Any] = ["username": username.trimmingCharacters(in: .whitespaces), "password": password]
            if isRegister { body["email"] = email.trimmingCharacters(in: .whitespaces) }
            let r: UserResponse = try await API.shared.post(isRegister ? "/api/register" : "/api/login", body)
            password = ""
            app.user = r.user
            await app.refreshUser()
        } catch { self.error = error.localizedDescription }
        busy = false
    }
}
