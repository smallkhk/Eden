import SwiftUI
import WebKit

struct AccountView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var live: LiveController
    @Environment(\.dismiss) private var dismiss
    @State private var account: AccountResponse?
    @State private var share: ShareInfo?
    @State private var voucher = ""
    @State private var voucherMsg = ""
    @State private var email = ""
    @State private var emailMsg = ""
    @State private var curPw = ""
    @State private var newPw = ""
    @State private var pwMsg = ""
    @State private var showAdmin = false
    @State private var confirmReset = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.user?.username ?? "").font(.headline).foregroundStyle(Theme.dim)
                        Text(formatSeconds(app.user?.balance ?? 0))
                            .font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundStyle(Theme.gold).monospacedDigit()
                        Text("Balance · a live session uses about one second per second").font(.caption).foregroundStyle(Theme.dim)
                    }
                    .padding(.vertical, 6)
                }

                Section("Top up") {
                    NavigationLink { TopUpView() } label: { Label("Buy seconds with USDT", systemImage: "bitcoinsign.circle") }
                    HStack {
                        TextField("Voucher code", text: $voucher).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button("Redeem") { Task { await redeem() } }.disabled(voucher.isEmpty)
                    }
                    if !voucherMsg.isEmpty { Text(voucherMsg).font(.footnote).foregroundStyle(Theme.dim) }
                }

                Section {
                    if let share {
                        Text(share.url).font(.footnote.monospaced()).foregroundStyle(Theme.you).textSelection(.enabled)
                        HStack {
                            Button(copied ? "Copied" : "Copy link") { UIPasteboard.general.string = share.url; copied = true }
                            Spacer()
                            ShareLink(item: URL(string: share.url)!) { Label("Send", systemImage: "square.and.arrow.up") }
                        }
                        Button("Make a new link", role: .destructive) { confirmReset = true }
                    } else { ProgressView() }
                } header: { Text("Live link") } footer: {
                    Text("Turn on “Share live to my link” in the studio. Open the link in any browser to watch, or paste it into the LiveChar Chrome extension to use your output as a camera in Chrome. A new link stops the old one working.")
                }

                Section("History") {
                    if let ledger = account?.ledger, !ledger.isEmpty {
                        ForEach(ledger.prefix(25)) { l in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(l.reason).font(.subheadline)
                                    Text(Date(timeIntervalSince1970: l.created_at / 1000).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.dim)
                                }
                                Spacer()
                                Text((l.delta >= 0 ? "+" : "−") + formatSeconds(abs(l.delta))).font(.subheadline.monospacedDigit())
                                    .foregroundStyle(l.delta >= 0 ? Theme.ok : Theme.dim)
                            }
                        }
                    } else { Text("Nothing yet").foregroundStyle(Theme.dim) }
                }

                Section("Email") {
                    TextField("you@example.com", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save email") { Task { await saveEmail() } }
                    if !emailMsg.isEmpty { Text(emailMsg).font(.footnote).foregroundStyle(Theme.dim) }
                }

                Section("Password") {
                    SecureField("Current password", text: $curPw).textContentType(.password)
                    SecureField("New password (6+ characters)", text: $newPw).textContentType(.newPassword)
                    Button("Change password") { Task { await changePw() } }.disabled(curPw.isEmpty || newPw.count < 6)
                    if !pwMsg.isEmpty { Text(pwMsg).font(.footnote).foregroundStyle(Theme.dim) }
                }

                Section("App") {
                    if app.user?.isAdmin == true {
                        Button { showAdmin = true } label: { Label("Admin panel", systemImage: "slider.horizontal.3") }
                    }
                    Button {
                        Task { await live.stop(); dismiss(); app.needsServer = true }
                    } label: { Label("Server: \(Server.current?.host ?? "-")", systemImage: "server.rack") }
                    Button(role: .destructive) {
                        Task { await live.stop(); dismiss(); await app.logout() }
                    } label: { Label("Log out", systemImage: "rectangle.portrait.and.arrow.right") }
                    Text("LiveChar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.caption).foregroundStyle(Theme.dim)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showAdmin) { AdminWebView(path: "/admin.html") }
            .confirmationDialog("Make a new live link?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("New link", role: .destructive) { Task { share = try? await API.shared.post("/api/share/reset") } }
            } message: { Text("Anyone using the old link (browsers, the Chrome extension) will need the new one.") }
        }
    }

    private func load() async {
        await app.refreshUser()
        if let a: AccountResponse = try? await API.shared.get("/api/account") { account = a; email = a.user.email ?? ""; app.setBalance(a.user.balance) }
        share = try? await API.shared.get("/api/share")
    }

    private func redeem() async {
        do {
            let r: RedeemResponse = try await API.shared.post("/api/vouchers/redeem", ["code": voucher.trimmingCharacters(in: .whitespaces)])
            voucher = ""; voucherMsg = "Added \(formatSeconds(r.seconds)) to your balance"
            app.setBalance(r.balance); await load()
        } catch { voucherMsg = error.localizedDescription }
    }

    private func saveEmail() async {
        do { try await API.shared.post("/api/account/email", ["email": email]); emailMsg = "Email saved" } catch { emailMsg = error.localizedDescription }
    }

    private func changePw() async {
        do { try await API.shared.post("/api/account/password", ["current": curPw, "next": newPw]); curPw = ""; newPw = ""; pwMsg = "Password changed" }
        catch { pwMsg = error.localizedDescription }
    }
}

struct TopUpView: View {
    @EnvironmentObject var app: AppModel
    @State private var packages: [Package] = []
    @State private var networks: [Network] = []
    @State private var order: Order?
    @State private var pickedPackage: Int?
    @State private var txid = ""
    @State private var msg = ""
    @State private var busy = false
    @State private var loaded = false

    var body: some View {
        List {
            if let order {
                Section("Send exactly") {
                    HStack {
                        Text("\(order.amount) USDT").font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(Theme.gold)
                        Spacer()
                        Button("Copy") { UIPasteboard.general.string = order.amount }
                    }
                    Text("on \(order.networkLabel) — the last digits identify your order").font(.caption).foregroundStyle(Theme.dim)
                }
                Section("To this address") {
                    if let img = qrImage(order.qr) {
                        Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(width: 200, height: 200)
                            .frame(maxWidth: .infinity).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Text(order.address).font(.footnote.monospaced()).textSelection(.enabled)
                    Button("Copy address") { UIPasteboard.general.string = order.address }
                }
                Section {
                    TextField("Transaction ID (hash)", text: $txid).textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                    Button { Task { await confirm() } } label: { if busy { ProgressView() } else { Text("I've paid — check it") } }
                        .disabled(txid.isEmpty || busy)
                    if !msg.isEmpty { Text(msg).font(.footnote).foregroundStyle(Theme.dim) }
                    if !order.note.isEmpty { Text(order.note).font(.footnote).foregroundStyle(Theme.bad) }
                } header: { Text("After paying") } footer: {
                    Text("\(order.package) · \(formatSeconds(order.seconds)). The server keeps checking in the background, you can leave this screen.")
                }
                Section { Button("Cancel order", role: .destructive) { Task { try? await API.shared.post("/api/orders/\(order.id)/cancel"); self.order = nil } } }
            } else if loaded && (packages.isEmpty || networks.isEmpty) {
                Section { Text("Top-ups are not set up yet. Ask the admin, or use a voucher code.").foregroundStyle(Theme.dim) }
            } else {
                Section("Package") {
                    ForEach(packages) { p in
                        Button { pickedPackage = p.id } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(p.name).font(.headline)
                                    Text(formatSeconds(p.seconds)).font(.caption).foregroundStyle(Theme.dim)
                                }
                                Spacer()
                                Text(String(format: "%g USDT", p.price)).font(.headline).foregroundStyle(Theme.gold)
                                if pickedPackage == p.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                            }
                        }
                        .foregroundStyle(Theme.text)
                    }
                }
                if let pickedPackage {
                    Section("Pay with") {
                        ForEach(networks) { n in
                            Button { Task { await create(pickedPackage, n.id) } } label: { Label(n.label, systemImage: "arrow.right.circle.fill") }
                        }
                    }
                }
                if !msg.isEmpty { Section { Text(msg).foregroundStyle(Theme.bad) } }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .navigationTitle("Top up")
        .task { await load() }
    }

    private func qrImage(_ dataURL: String) -> UIImage? {
        guard let comma = dataURL.firstIndex(of: ","), let d = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return UIImage(data: d)
    }

    private func load() async {
        if let r: PackagesResponse = try? await API.shared.get("/api/packages") { packages = r.packages; networks = r.networks }
        if let r: OrderResponse = try? await API.shared.get("/api/orders/current") { order = r.order; txid = r.order?.txid ?? "" }
        loaded = true
    }

    private func create(_ pkg: Int, _ net: String) async {
        msg = ""
        do { let r: OrderResponse = try await API.shared.post("/api/orders", ["packageId": pkg, "network": net]); order = r.order }
        catch { msg = error.localizedDescription }
    }

    private func confirm() async {
        guard let order else { return }
        busy = true; msg = ""
        do {
            let r: ConfirmResponse = try await API.shared.post("/api/orders/\(order.id)/confirm", ["txid": txid.trimmingCharacters(in: .whitespaces)])
            switch r.status {
            case "paid":
                msg = "Paid! Seconds added."
                if let b = r.balance { app.setBalance(b) }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self.order = nil
            case "pending": msg = "Seen — waiting for confirmations. It will be added automatically."
            default: msg = r.error ?? "That transaction doesn't match this order"
            }
        } catch { msg = error.localizedDescription }
        busy = false
    }
}

/// The web admin panel, logged in with the app's session.
struct AdminWebView: UIViewRepresentable {
    let path: String
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = UIColor(Theme.ink)
        guard let url = try? API.shared.url(path) else { return web }
        let store = cfg.websiteDataStore.httpCookieStore
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let group = DispatchGroup()
        for c in cookies { group.enter(); store.setCookie(c) { group.leave() } }
        group.notify(queue: .main) { web.load(URLRequest(url: url)) }
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
