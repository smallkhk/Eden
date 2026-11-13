import AVFoundation
import LiveKit
import SwiftUI
import UIKit

struct EngineDef: Identifiable, Hashable {
    enum Kind { case lucy, eden }
    let id: String
    let label: String
    let detail: String
    let kind: Kind
    let endpoint: String
    let width: Int
    let height: Int
    let fps: Double
    let price: Double

    static let all: [EngineDef] = [
        EngineDef(id: "lucy", label: "Lucy", detail: "Decart · 720p · fastest", kind: .lucy, endpoint: "", width: 1280, height: 720, fps: 30, price: 0),
        EngineDef(id: "eden-5b", label: "Eden 5B", detail: "720p · 24 fps", kind: .eden, endpoint: "vast/eden-live-5b-video", width: 1280, height: 704, fps: 24, price: 0.0035),
        EngineDef(id: "eden-14b", label: "Eden 14B", detail: "480p · 16 fps", kind: .eden, endpoint: "vast/eden-live-14b-video", width: 832, height: 480, fps: 16, price: 0.01),
    ]
    static func byID(_ id: String) -> EngineDef { all.first { $0.id == id } ?? all[0] }
}

/// Camera frames → (engine, input preview), from the camera queue. Lock-protected so it can be swapped while live.
final class FrameRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var _engine: LiveEngine?
    private weak var _input: VideoSurface?
    private var _latest: CVPixelBuffer?

    var engine: LiveEngine? {
        get { lock.lock(); defer { lock.unlock() }; return _engine }
        set { lock.lock(); _engine = newValue; lock.unlock() }
    }
    var input: VideoSurface? {
        get { lock.lock(); defer { lock.unlock() }; return _input }
        set { lock.lock(); _input = newValue; lock.unlock() }
    }
    var latest: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return _latest }

    func frame(_ pb: CVPixelBuffer) {
        lock.lock(); _latest = pb; let e = _engine; let i = _input; lock.unlock()
        e?.pushCamera(pb)
        i?.show(pb)
    }
    func clear() { lock.lock(); _latest = nil; lock.unlock() }
}

@MainActor
final class LiveController: ObservableObject {
    // choices (kept between launches)
    @AppStorage("lc.engine") var engineID = "lucy" { willSet { objectWillChange.send() } }
    @AppStorage("lc.portrait") var portrait = true { willSet { objectWillChange.send() } }
    @AppStorage("lc.enhance") var enhance = true { willSet { objectWillChange.send() } }
    @AppStorage("lc.mirror") var mirror = true { willSet { objectWillChange.send() } }
    @AppStorage("lc.share") var shareOn = false { willSet { objectWillChange.send() } }
    @AppStorage("lc.backCamera") var backCamera = false { willSet { objectWillChange.send() } }
    // voice changer
    @AppStorage("lc.voiceOn") var voiceOn = false { willSet { objectWillChange.send() } }
    @AppStorage("lc.voiceID") var voiceID = "" { willSet { objectWillChange.send() } }
    @AppStorage("lc.voiceName") var voiceName = "" { willSet { objectWillChange.send() } }
    @AppStorage("lc.voiceMonitor") var voiceMonitor = false { willSet { objectWillChange.send() } }
    @AppStorage("lc.avOffset") var avOffset = 0.3 { willSet { objectWillChange.send() } }
    @Published var voiceState = ""
    private var voice: VoiceEngine?

    @Published var rotation = 0
    @Published var prompt = ""
    @Published var refImage: UIImage?
    private(set) var refData: Data?
    private var refDirty = false

    // live state
    @Published var running = false
    @Published var starting = false
    @Published var applying = false
    @Published var status = "idle"
    @Published var statusLive = false
    @Published var note = ""
    @Published var stats = ""
    @Published var fps = 0
    @Published var outputSize = CGSize(width: 9, height: 16)
    @Published var zoom: CGFloat = 1
    @Published var recording = false
    @Published var recordStart = Date()
    @Published var viewers = 0
    @Published var shareProblem: String?
    @Published var pipActive = false

    var config: AppConfig?
    var onBalance: (Double) -> Void = { _ in }

    let camera = Camera()
    let hub = OutputHub()
    let router = FrameRouter()
    let pip = PiPController()
    private weak var outputSurface: VideoSurface?
    private var engine: LiveEngine?
    private var bill: (id: String, live: Bool)?
    private var beatTask: Task<Void, Never>?
    private var capTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var stopping = false

    var engineDef: EngineDef { EngineDef.byID(engineID) }
    /// camera + stream keep going when you switch to another app (PiP)
    var keepsRunningInBackground: Bool { camera.worksInBackground && PiPController.supported }
    var isPortraitOutput: Bool { engineDef.kind == .lucy && portrait }

    init() {
        // LiveChar sets the audio session itself (mic for the voice changer, PiP)
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        let router = self.router
        camera.onFrame = { pb, _ in router.frame(pb) }
        hub.onFirstFrame = { [weak self] in Task { @MainActor in self?.goLive() } }
        hub.onSize = { [weak self] s in Task { @MainActor in self?.outputSize = s; self?.pip.setAspect(s) } }
        hub.pipDisplay = pip.surface
        pip.onActive = { [weak self] on in Task { @MainActor in self?.pipActive = on } }
        hub.onFPS = { [weak self] f in Task { @MainActor in self?.fps = f } }
    }

    func attachOutput(_ v: VideoSurface) {
        outputSurface = v
        v.framing = hub.framing
        hub.display = v
        pip.attach(source: v)
        v.onFraming = { [weak self] f in
            self?.hub.framing = f
            Task { @MainActor in self?.zoom = f.zoom }
        }
    }
    func attachInput(_ v: VideoSurface) { router.input = v }

    func setZoom(_ z: CGFloat) { outputSurface?.setZoom(z) }
    func resetZoom() { outputSurface?.framing = .full }

    // MARK: character

    func setReference(_ image: UIImage?) {
        refImage = image
        refData = image?.referenceJPEG()
        refDirty = true
        if running { note = "Press Apply to use it while live" }
    }

    func setReference(data: Data, prompt: String?) {
        setReference(UIImage(data: data))
        if let prompt { self.prompt = prompt }
    }

    var hasPendingChanges: Bool { refDirty }

    // MARK: start / stop

    func start() async {
        guard !running, !starting, let config else { return }
        let def = engineDef
        starting = true; note = ""; stats = ""; status = "starting…"; statusLive = false
        UIApplication.shared.isIdleTimerDisabled = true
        guard await Camera.authorize() else {
            starting = false; status = "idle"
            note = "Allow camera access for LiveChar in Settings"
            return
        }
        do {
            // the paid session first: the server decides how long it may run
            let s: SessionStart = try await API.shared.post("/api/session/start", ["engine": def.id])
            bill = (s.id, false)
            onBalance(s.balance)
            fallbackTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.goLive()
            }

            let (w, h) = isPortraitOutput ? (def.height, def.width) : (def.width, def.height)
            camera.configure(width: w, height: h, fps: def.fps)
            camera.setRotation(rotation)
            hub.reset()
            hub.avOffset = avOffset
            if voiceOn && !voiceID.isEmpty { await startVoice() } else { AudioSessionSetup.activate() }
            try await camera.start(position: backCamera ? .back : .front)
            pip.setEnabled(true)
            if shareOn { startShare() }

            let events = makeEvents()
            switch def.kind {
            case .lucy:
                let token: DecartToken = try await API.shared.post("/api/decart-token", ["id": s.id])
                let eng = LucyEngine(events: events)
                engine = eng; router.engine = eng
                try await eng.start(token: token.apiKey, model: config.lucyModel, fast: config.lucyFast, width: w, height: h,
                                    prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), image: refData, enhance: enhance)
            case .eden:
                let eng = EdenEngine(endpoint: def.endpoint, events: events)
                eng.price = def.price
                eng.buildAnchor = { [weak self] img in
                    guard let self else { throw APIError(message: "Stopped", status: 0) }
                    return try await self.anchor(img, width: w, height: h)
                }
                engine = eng; router.engine = eng
                var imageURL: String?
                if let refData { imageURL = try await anchor(refData, width: w, height: h) }
                try await eng.start(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), imageURL: imageURL, enhance: enhance)
            }
            refDirty = false
            running = true
            starting = false
            let cap = s.maxSeconds
            capTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(cap * 1e9))
                if !Task.isCancelled { await self?.stop(reason: "Session time limit reached") }
            }
        } catch {
            await stop(reason: error.localizedDescription)
        }
    }

    private func makeEvents() -> EngineEvents {
        let hub = self.hub
        var e = EngineEvents()
        e.output = { pb in hub.push(pb) }
        e.state = { [weak self] text, live in Task { @MainActor in self?.status = text; self?.statusLive = live } }
        e.note = { [weak self] text in Task { @MainActor in self?.note = text } }
        e.stats = { [weak self] text in Task { @MainActor in self?.stats = text } }
        e.ended = { [weak self] why in Task { @MainActor in await self?.stop(reason: why) } }
        return e
    }

    /// Eden's "target look" frame: the current camera frame + the character image (server builds it on fal).
    private func anchor(_ image: Data, width: Int, height: Int) async throws -> String {
        var frame = router.latest
        for _ in 0..<30 where frame == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            frame = router.latest
        }
        guard let frame, let jpeg = FrameOps.jpeg(frame) else { throw APIError(message: "The camera did not start", status: 0) }
        status = "building look…"; note = "Hold still for a second…"
        let r: FirstFrame = try await API.shared.post("/api/first-frame", [
            "frame": "data:image/jpeg;base64," + jpeg.base64EncodedString(),
            "character": "data:image/jpeg;base64," + image.base64EncodedString(),
            "prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "width": width, "height": height,
        ])
        if let b = r.balance { onBalance(b) }
        note = ""
        return r.url
    }

    /// Billing starts with the first output frame (or 20 s after start).
    private func goLive() {
        guard var b = bill, !b.live else { return }
        b.live = true; bill = b
        fallbackTask?.cancel()
        let id = b.id
        Task { try? await API.shared.post("/api/session/live", ["id": id]) }
        beatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                guard let r: BeatResponse = try? await API.shared.post("/api/session/beat", ["id": id]) else { continue }
                await MainActor.run {
                    if let bal = r.balance { self?.onBalance(bal) }
                    if r.ended == true, self?.bill?.id == id {
                        Task { await self?.stop(reason: (r.balance ?? 0) <= 0 ? "Balance finished — top up to continue" : "Session time limit reached") }
                    }
                }
            }
        }
    }

    func stop(reason: String = "") async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        capTask?.cancel(); beatTask?.cancel(); fallbackTask?.cancel()
        let e = engine
        engine = nil; router.engine = nil
        if let b = bill {
            bill = nil
            Task { [weak self] in
                if let r: BeatResponse = try? await API.shared.post("/api/session/stop", ["id": b.id]), let bal = r.balance {
                    await MainActor.run { self?.onBalance(bal) }
                }
            }
        }
        if recording { await toggleRecording() }
        stopVoice()
        stopShare()
        await e?.stop()
        camera.stop()
        pip.setEnabled(false)
        AudioSessionSetup.deactivate()
        router.clear()
        router.input?.flush()
        hub.reset()
        running = false; starting = false
        status = "idle"; statusLive = false; fps = 0; stats = ""
        if !reason.isEmpty { note = reason }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func apply() async {
        guard let engine, running else { return }
        applying = true
        do {
            try await engine.apply(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), image: refData, imageChanged: refDirty, enhance: enhance)
            refDirty = false
            note = "Applied"
        } catch { note = error.localizedDescription }
        applying = false
    }

    // MARK: camera

    func flipCamera() async {
        backCamera.toggle()
        guard running || starting else { return }
        do { try await camera.start(position: backCamera ? .back : .front) } catch { note = error.localizedDescription }
    }

    func rotateCamera() {
        rotation = (rotation + 90) % 360
        camera.setRotation(rotation)
    }

    // MARK: photo / record

    func takePhoto() async {
        do { try await hub.photo(); note = "Photo saved to Photos"; UINotificationFeedbackGenerator().notificationOccurred(.success) }
        catch { note = error.localizedDescription }
    }

    func toggleRecording() async {
        if recording {
            recording = false
            do { try await hub.stopRecording(); note = "Video saved to Photos" } catch { note = error.localizedDescription }
        } else {
            do { try hub.startRecording(); recordStart = Date(); recording = true } catch { note = error.localizedDescription }
        }
    }

    // MARK: voice

    private func startVoice() async {
        guard voice == nil, !voiceID.isEmpty else { return }
        guard await VoiceEngine.authorize() else { note = "Allow the microphone for LiveChar in Settings to change your voice"; return }
        do { try VoiceAudioSession.activate() } catch { note = "Microphone: \(error.localizedDescription)"; return }
        var ev = VoiceEngine.Events()
        let hub = self.hub
        ev.converted = { pcm, at in hub.addVoice(pcm, spokenAt: at) }
        ev.state = { [weak self] s in Task { @MainActor in self?.voiceState = s } }
        ev.balance = { [weak self] b in Task { @MainActor in self?.onBalance(b) } }
        ev.failed = { [weak self] msg in Task { @MainActor in
            self?.voiceState = msg
            self?.note = "Voice: \(msg)"
            if msg.lowercased().contains("balance") || msg.lowercased().contains("not set up") { self?.stopVoice() }
        } }
        let v = VoiceEngine(voiceID: voiceID, events: ev)
        v.monitor = voiceMonitor
        do { try v.start(); voice = v } catch { note = "Voice: \(error.localizedDescription)"; voiceState = "" }
    }

    private func stopVoice() {
        voice?.stop()
        voice = nil
        voiceState = ""
    }

    /// Turn the voice changer on/off, or switch voices, while live.
    func setVoice(on: Bool) async {
        voiceOn = on
        guard running || starting else { return }
        stopVoice()
        if on { await startVoice() } else { AudioSessionSetup.activate() }
    }

    func chooseVoice(id: String, name: String) async {
        voiceID = id; voiceName = name
        if voiceOn && (running || starting) { stopVoice(); await startVoice() }
    }

    func setMonitor(_ on: Bool) { voiceMonitor = on; voice?.monitor = on }
    func setAVOffset(_ v: Double) { avOffset = v; hub.avOffset = v }

    // MARK: share live

    func setShare(_ on: Bool) {
        shareOn = on
        if running || starting { on ? startShare() : stopShare() }
    }

    private func startShare() {
        guard hub.streamer == nil else { return }
        let s = ShareStreamer()
        s.onViewers = { [weak self] n in Task { @MainActor in self?.viewers = n } }
        s.onProblem = { [weak self] p in Task { @MainActor in self?.shareProblem = p } }
        hub.streamer = s
    }

    private func stopShare() {
        hub.streamer?.stop()
        hub.streamer = nil
        viewers = 0
        shareProblem = nil
    }
}
