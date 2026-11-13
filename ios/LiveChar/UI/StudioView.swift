import PhotosUI
import SwiftUI

struct StudioView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var live: LiveController
    @Environment(\.verticalSizeClass) private var vClass
    @Environment(\.scenePhase) private var phase
    @State private var showAccount = false
    @State private var showInput = true

    var body: some View {
        Group {
            if vClass == .compact {
                HStack(spacing: 0) {
                    stage.padding(10)
                    ScrollView { controls.padding(14) }.frame(width: 380).background(Theme.ink)
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    stage.padding(.horizontal, 12).padding(.top, 4)
                    ScrollView { controls.padding(14) }
                    goBar
                }
            }
        }
        .screenBackground()
        .sheet(isPresented: $showAccount) { AccountView().environmentObject(app).environmentObject(live) }
        .onChange(of: phase) { p in
            // with PiP the camera keeps running behind other apps; without it iOS pauses the camera, so stop billing
            if p == .background, live.running || live.starting, !live.keepsRunningInBackground {
                Task { await live.stop(reason: "Stopped: this iPhone doesn't let the camera run in the background") }
            }
        }
    }

    // MARK: top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Logo()
            Spacer()
            Button { showAccount = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill").font(.system(size: 12))
                    Text(formatSeconds(app.user?.balance ?? 0)).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .foregroundStyle(Theme.gold)
                .padding(.horizontal, 12).frame(height: 34)
                .background(Theme.gold.opacity(0.12), in: Capsule())
            }
            Button { showAccount = true } label: {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: output + input preview

    private var stage: some View {
        let size = live.outputSize
        return ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.well)
            VideoSurfaceView(mirrored: live.previewMirrored, zoomable: true) { live.attachOutput($0) }
                .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(live.statusLive ? Theme.char : Theme.line, lineWidth: live.statusLive ? 1.5 : 1))
                .shadow(color: live.statusLive ? Theme.char.opacity(0.35) : .clear, radius: 24)
            if !live.running && !live.starting { idleCard }
            if live.starting && !live.statusLive { ProgressView().tint(Theme.char).scaleEffect(1.3) }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Pill(text: live.status, color: live.statusLive ? Theme.char : (live.running || live.starting ? Theme.gold : Theme.dim), pulsing: live.statusLive)
                if live.fps > 0 { Pill(text: "\(live.fps) fps", color: Theme.you) }
            }
            .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            if live.hub.streamer != nil || (live.shareOn && live.running) {
                Pill(text: live.shareProblem == nil ? "Link · \(live.viewers) watching" : "Link: slow", color: live.shareProblem == nil ? Theme.ok : Theme.bad)
                    .padding(12)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showInput && (live.running || live.starting) {
                VideoSurfaceView(mirrored: live.previewMirrored, zoomable: false) { live.attachInput($0) }
                    .aspectRatio(live.isPortraitOutput ? 9.0 / 16 : CGFloat(live.engineDef.width) / CGFloat(live.engineDef.height), contentMode: .fit)
                    .frame(width: live.isPortraitOutput ? 64 : 112)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.you.opacity(0.8), lineWidth: 1.5))
                    .padding(12)
                    .onTapGesture { withAnimation { showInput = false } }
            }
        }
        .overlay(alignment: .bottomTrailing) { tools.padding(10) }
    }

    private var idleCard: some View {
        VStack(spacing: 12) {
            if let img = live.refImage {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 92, height: 92).clipShape(Circle())
                    .overlay(Circle().stroke(Theme.char, lineWidth: 2))
            } else {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 46)).foregroundStyle(Theme.char)
            }
            Text(live.refImage == nil && live.prompt.isEmpty ? "Pick a character, then Go live" : "Ready — press Go live")
                .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.dim)
            if !live.note.isEmpty {
                Text(live.note).font(.footnote).foregroundStyle(Theme.text.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal, 20)
            }
        }
    }

    private var tools: some View {
        HStack(spacing: 8) {
            if live.zoom > 1.01 {
                Button { live.resetZoom() } label: { Text(String(format: "%.1f×", live.zoom)).font(.system(size: 13, weight: .bold, design: .rounded)) }
                    .buttonStyle(RoundTool())
            }
            if live.running {
                if !showInput { Button { withAnimation { showInput = true } } label: { Image(systemName: "rectangle.inset.bottomleft.filled") }.buttonStyle(RoundTool()) }
                if PiPController.supported {
                    Button { live.pipActive ? live.pip.stop() : live.pip.start() } label: { Image(systemName: live.pipActive ? "pip.exit" : "pip.enter") }
                        .buttonStyle(RoundTool(active: live.pipActive))
                }
                Button { Task { await live.takePhoto() } } label: { Image(systemName: "camera.fill") }.buttonStyle(RoundTool())
                Button { Task { await live.toggleRecording() } } label: {
                    if live.recording {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let s = Int(ctx.date.timeIntervalSince(live.recordStart))
                            Label(String(format: "%d:%02d", s / 60, s % 60), systemImage: "stop.fill").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        }
                    } else { Image(systemName: "record.circle") }
                }
                .buttonStyle(RoundTool(active: live.recording))
            }
        }
    }

    // MARK: controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if vClass == .compact { HStack { Logo(); Spacer(); Button { showAccount = true } label: { Image(systemName: "person.crop.circle.fill").font(.system(size: 26)) } } }
            VideoSourceCard()
            if !live.note.isEmpty && (live.running || live.starting) {
                Text(live.note).font(.footnote).foregroundStyle(Theme.text.opacity(0.85))
            }
            if !live.stats.isEmpty { Text(live.stats).font(.caption.monospacedDigit()).foregroundStyle(Theme.dim) }

            Card {
                Text("ENGINE").font(.caption.weight(.bold)).foregroundStyle(Theme.dim)
                Picker("Engine", selection: Binding(get: { live.engineID }, set: { live.engineID = $0 })) {
                    ForEach(EngineDef.all) { e in Text(e.label).tag(e.id) }
                }
                .pickerStyle(.segmented)
                .disabled(live.running || live.starting || live.source == .videoFile)
                HStack {
                    Text(live.source == .videoFile ? "Off while playing a video file" : engineLine).font(.footnote).foregroundStyle(Theme.dim)
                    Spacer()
                    if live.engineDef.kind == .lucy {
                        Picker("", selection: Binding(get: { live.portrait }, set: { live.portrait = $0 })) {
                            Image(systemName: "rectangle.portrait").tag(true)
                            Image(systemName: "rectangle").tag(false)
                        }
                        .pickerStyle(.segmented).frame(width: 110)
                        .disabled(live.running || live.starting)
                    }
                }
            }

            CharacterStrip()

            Card {
                Text("PROMPT").font(.caption.weight(.bold)).foregroundStyle(Theme.dim)
                TextField("Describe the character or the change (optional with an image)", text: $live.prompt, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(12)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
                Toggle("Improve my prompt automatically", isOn: Binding(get: { live.enhance }, set: { live.enhance = $0 }))
                    .font(.subheadline).tint(Theme.char)
            }

            VoiceCard()

            Card {
                Text("CAMERA & OUTPUT").font(.caption.weight(.bold)).foregroundStyle(Theme.dim)
                HStack(spacing: 8) {
                    Button { Task { await live.flipCamera() } } label: { Label(live.backCamera ? "Back" : "Front", systemImage: "arrow.triangle.2.circlepath.camera") }
                        .buttonStyle(SoftButtonStyle())
                    Button { live.rotateCamera() } label: { Label("\(live.rotation)°", systemImage: "rotate.right") }
                        .buttonStyle(SoftButtonStyle())
                    Button { live.mirror.toggle() } label: { Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        .buttonStyle(SoftButtonStyle(tint: live.mirror ? Theme.you : Theme.dim))
                }
                HStack {
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.dim)
                    Slider(value: Binding(get: { Double(live.zoom) }, set: { live.setZoom(CGFloat($0)) }), in: 1...4).tint(Theme.you)
                    Text(String(format: "%.1f×", live.zoom)).font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim).frame(width: 40)
                }
                Text("Pinch the output to zoom, drag to move, double-tap to reset.").font(.caption).foregroundStyle(Theme.dim)
            }

            Card {
                Toggle(isOn: Binding(get: { live.shareOn }, set: { live.setShare($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share live to my link").font(.subheadline.weight(.semibold))
                        Text("Watch the output in any browser, or use it as a camera in Chrome/Safari with the LiveChar Camera extension. Leave the app while live and it keeps going in a floating window. Link is in Account.")
                            .font(.caption).foregroundStyle(Theme.dim)
                    }
                }
                .tint(Theme.ok)
            }

            if vClass == .compact { goButtons.padding(.top, 4) }
        }
    }

    private var engineLine: String {
        let e = live.engineDef
        let rate = app.config?.rates[e.id] ?? 1
        let enabled = e.kind == .lucy ? (app.config?.engines.lucy ?? false) : (app.config?.engines.eden ?? false)
        if !enabled { return "\(e.detail) · not set up" }
        return rate != 1 ? "\(e.detail) · \(String(format: "%g", rate))× rate" : e.detail
    }

    private var goBar: some View {
        goButtons
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            .background(Theme.ink.shadow(.drop(color: .black.opacity(0.4), radius: 12, y: -4)))
    }

    private var goButtons: some View {
        HStack(spacing: 10) {
            if live.running || live.starting {
                Button { Task { await live.stop() } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(GoButtonStyle(danger: true))
                if live.running && live.source == .camera {
                    Button { Task { await live.apply() } } label: {
                        if live.applying { ProgressView().tint(Theme.ink) } else { Label("Apply", systemImage: "wand.and.stars") }
                    }
                    .buttonStyle(GoButtonStyle())
                    .disabled(live.applying)
                }
            } else {
                Button { Task { await live.start() } } label: { Label("Go live", systemImage: "dot.radiowaves.left.and.right") }
                    .buttonStyle(GoButtonStyle())
            }
        }
    }
}

struct RoundTool: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(active ? Theme.char : Theme.text)
            .padding(.horizontal, 12).frame(minWidth: 42, minHeight: 42)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - characters

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    func image(for id: Int) async -> UIImage? {
        if let i = cache.object(forKey: "\(id)" as NSString) { return i }
        guard let d = try? await API.shared.data("/api/characters/\(id)/image"), let i = UIImage(data: d) else { return nil }
        cache.setObject(i, forKey: "\(id)" as NSString)
        return i
    }
}

struct CharacterStrip: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var live: LiveController
    @State private var characters: [Character] = []
    @State private var pick: PhotosPickerItem?
    @State private var saving = false
    @State private var saveName = ""
    @State private var asPreset = false
    @State private var error = ""

    var body: some View {
        let ref = live.refImage
        return Card {
            HStack {
                Text("CHARACTER").font(.caption.weight(.bold)).foregroundStyle(Theme.dim)
                Spacer()
                if live.refImage != nil {
                    Button("Save") { saveName = ""; saving = true }.font(.footnote.weight(.semibold))
                    Button { live.setReference(nil) } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(Theme.dim)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    PhotosPicker(selection: $pick, matching: .images) {
                        ZStack {
                            if let img = ref {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.char)
                            }
                        }
                        .frame(width: 66, height: 66)
                        .background(Theme.well)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ref != nil ? Theme.char : Theme.line, lineWidth: ref != nil ? 2 : 1))
                    }
                    ForEach(characters) { c in
                        CharacterThumb(character: c)
                            .onTapGesture { Task { await choose(c) } }
                            .contextMenu {
                                if !c.isPreset || app.user?.isAdmin == true {
                                    Button(role: .destructive) { Task { await delete(c) } } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                    }
                }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(Theme.bad) }
        }
        .task { await load() }
        .onChange(of: pick) { item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                    live.setReference(img)
                    if min(img.size.width, img.size.height) < 512 { live.note = "Small image — 512px or more on the short side works best" }
                }
                pick = nil
            }
        }
        .alert("Save character", isPresented: $saving) {
            TextField("Name", text: $saveName)
            if app.user?.isAdmin == true { Button("Save for everyone (preset)") { asPreset = true; Task { await save() } } }
            Button("Save") { asPreset = false; Task { await save() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saves the image and the prompt.") }
    }

    private func load() async {
        if let r: CharactersResponse = try? await API.shared.get("/api/characters") { characters = r.characters }
    }

    private func choose(_ c: Character) async {
        error = ""
        guard let d = try? await API.shared.data("/api/characters/\(c.id)/image") else { error = "Could not load that character"; return }
        live.setReference(data: d, prompt: c.prompt)
        live.note = live.running ? "“\(c.name)” loaded — press Apply" : "“\(c.name)” loaded"
    }

    private func delete(_ c: Character) async {
        do { try await API.shared.delete("/api/characters/\(c.id)"); await load() } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard let data = live.refData else { return }
        do {
            let body: [String: Any] = ["name": saveName.isEmpty ? "Character" : saveName, "prompt": live.prompt,
                                       "image": "data:image/jpeg;base64," + data.base64EncodedString()]
            try await API.shared.post(asPreset ? "/api/admin/presets" : "/api/characters", body)
            live.note = "Character saved"
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

struct CharacterThumb: View {
    let character: Character
    @State private var image: UIImage?
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let image { Image(uiImage: image).resizable().scaledToFill() } else { Theme.well }
            }
            .frame(width: 66, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
            .overlay(alignment: .topTrailing) {
                if character.isPreset { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.gold).padding(5) }
            }
            Text(character.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim).lineLimit(1).frame(width: 66)
        }
        .task { image = await ImageCache.shared.image(for: character.id) }
    }
}
