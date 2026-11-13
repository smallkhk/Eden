import AVFoundation
import AVKit
import Photos
import SwiftUI

// Cam Test: live camera preview, front/back, zoom, focus, torch, photo + video (with sound) to Photos,
// camera info, and a picture-in-picture test that shows whether the camera keeps running in the background.

@main
struct CamTestApp: App {
    @StateObject private var cam = CameraModel()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(cam).preferredColorScheme(.dark) }
    }
}

final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate, AVPictureInPictureControllerDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camtest.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var rotation: AnyObject?
    private var rotationObs: [NSKeyValueObservation] = []
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    // picture-in-picture
    private var pip: AVPictureInPictureController?
    private let pipVC = AVPictureInPictureVideoCallViewController()
    private let pipLayer = AVCaptureVideoPreviewLayer()

    @Published var running = false
    @Published var front = false
    @Published var torch = false
    @Published var recording = false
    @Published var recordStart = Date()
    @Published var zoom: CGFloat = 1
    @Published var info: [(String, String)] = []
    @Published var message = ""
    @Published var pipActive = false
    @Published var denied = false
    private var pinchStart: CGFloat = 1

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] n in
            let r = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            let why: String
            switch r {
            case .videoDeviceNotAvailableInBackground: why = "camera paused: app is in the background"
            case .videoDeviceInUseByAnotherClient: why = "camera in use by another app"
            case .videoDeviceNotAvailableWithMultipleForegroundApps: why = "camera paused: split view / slide over"
            case .videoDeviceNotAvailableDueToSystemPressure: why = "camera paused: device too hot"
            case .audioDeviceInUseByAnotherClient: why = "microphone in use by another app"
            default: why = "camera interrupted"
            }
            self?.message = "⚠️ " + why
        }
        NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            self?.message = "✅ camera back"
        }
        pipLayer.session = session
        pipLayer.videoGravity = .resizeAspectFill
        pipVC.preferredContentSize = CGSize(width: 1080, height: 1920)
        pipVC.view.layer.addSublayer(pipLayer)
    }

    // MARK: setup

    func start() async {
        var ok = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if !ok { ok = await AVCaptureDevice.requestAccess(for: .video) }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        guard ok else { await MainActor.run { denied = true }; return }
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        queue.async { self.configure(front: false) }
    }

    private func configure(front: Bool) {
        session.beginConfiguration()
        if #available(iOS 16.0, *), session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
        session.sessionPreset = .high
        if let videoInput { session.removeInput(videoInput) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.message = "Can't open the \(front ? "front" : "back") camera" }
            return
        }
        session.addInput(input)
        videoInput = input
        if session.inputs.first(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }) == nil,
           let mic = AVCaptureDevice.default(for: .audio), let micIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micIn) {
            session.addInput(micIn)
        }
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        setupRotation(device)
        DispatchQueue.main.async {
            self.front = front; self.torch = false; self.zoom = 1
            self.running = self.session.isRunning
            self.refreshInfo()
            self.setupPiP()
        }
    }

    private func setupRotation(_ device: AVCaptureDevice) {
        guard #available(iOS 17.0, *) else { return }
        let rc = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotation = rc
        let apply = { [weak self] in
            guard let self else { return }
            let capture = rc.videoRotationAngleForHorizonLevelCapture
            for out in [self.photoOutput, self.movieOutput] as [AVCaptureOutput] {
                if let c = out.connection(with: .video), c.isVideoRotationAngleSupported(capture) { c.videoRotationAngle = capture }
            }
            DispatchQueue.main.async {
                let p = rc.videoRotationAngleForHorizonLevelPreview
                for l in [self.previewLayer, self.pipLayer] { if let c = l?.connection, c.isVideoRotationAngleSupported(p) { c.videoRotationAngle = p } }
            }
        }
        apply()
        rotationObs = [
            rc.observe(\.videoRotationAngleForHorizonLevelCapture) { _, _ in apply() },
            rc.observe(\.videoRotationAngleForHorizonLevelPreview) { _, _ in apply() },
        ]
    }

    func refreshInfo() {
        guard let d = videoInput?.device else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
        let fps = d.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        var bg = "no"
        if #available(iOS 16.0, *) { bg = session.isMultitaskingCameraAccessSupported ? (session.isMultitaskingCameraAccessEnabled ? "yes" : "supported, off") : "no" }
        info = [
            ("Camera", d.localizedName),
            ("Format", "\(dims.width)×\(dims.height) · up to \(Int(fps)) fps"),
            ("Zoom", String(format: "%.1f× (max %.0f×)", d.videoZoomFactor, min(d.maxAvailableVideoZoomFactor, 10))),
            ("Background camera", bg),
            ("Picture-in-picture", AVPictureInPictureController.isPictureInPictureSupported() ? "supported" : "not supported"),
        ]
    }

    // MARK: controls

    func flip() { let f = !front; queue.async { self.configure(front: f) } }

    func toggleTorch() {
        guard let d = videoInput?.device, d.hasTorch else { message = "No light on this camera"; return }
        do {
            try d.lockForConfiguration()
            d.torchMode = d.torchMode == .on ? .off : .on
            d.unlockForConfiguration()
            torch = d.torchMode == .on
        } catch { message = error.localizedDescription }
    }

    func pinch(_ scale: CGFloat, began: Bool) {
        guard let d = videoInput?.device else { return }
        if began { pinchStart = d.videoZoomFactor }
        let z = min(max(1, pinchStart * scale), min(d.maxAvailableVideoZoomFactor, 10))
        if (try? d.lockForConfiguration()) != nil { d.videoZoomFactor = z; d.unlockForConfiguration() }
        zoom = z
        refreshInfo()
    }

    func focus(at layerPoint: CGPoint) {
        guard let d = videoInput?.device, let p = previewLayer?.captureDevicePointConverted(fromLayerPoint: layerPoint) else { return }
        if (try? d.lockForConfiguration()) != nil {
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = p; d.focusMode = .autoFocus }
            if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = p; d.exposureMode = .autoExpose }
            d.unlockForConfiguration()
        }
    }

    func photo() {
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation() else { DispatchQueue.main.async { self.message = "Photo failed" }; return }
        save { PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil) } done: { self.message = "📸 Photo saved to Photos" }
    }

    func toggleRecord() {
        if movieOutput.isRecording { movieOutput.stopRecording(); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camtest-\(Int(Date().timeIntervalSince1970)).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        recording = true; recordStart = Date()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.recording = false }
        save { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) } done: {
            self.message = "🎬 Video saved to Photos"
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func save(_ change: @escaping () -> Void, done: @escaping () -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
            guard s == .authorized || s == .limited else { DispatchQueue.main.async { self.message = "Allow Photos access in Settings" }; return }
            PHPhotoLibrary.shared().performChanges(change) { ok, err in
                DispatchQueue.main.async { if ok { done() } else { self.message = "Save failed: \(err?.localizedDescription ?? "")" } }
            }
        }
    }

    // MARK: picture-in-picture

    weak var pipSource: UIView? { didSet { setupPiP() } }

    private func setupPiP() {
        guard pip == nil, let pipSource, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let c = AVPictureInPictureController(contentSource: .init(activeVideoCallSourceView: pipSource, contentViewController: pipVC))
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.delegate = self
        pip = c
    }

    func togglePiP() {
        guard let pip else { message = "Picture-in-picture isn't available"; return }
        pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        pipLayer.frame = pipVC.view.bounds
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { pipActive = true; pipLayer.frame = pipVC.view.bounds }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { pipActive = false }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        message = "PiP failed: \(error.localizedDescription)"
    }
}

// MARK: - UI

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    @EnvironmentObject var cam: CameraModel
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.preview.session = cam.session
        v.preview.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        cam.previewLayer = v.preview
        cam.pipSource = v
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        v.addGestureRecognizer(pinch); v.addGestureRecognizer(tap)
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(cam) }

    final class Coordinator: NSObject {
        let cam: CameraModel
        init(_ cam: CameraModel) { self.cam = cam }
        @objc func pinch(_ g: UIPinchGestureRecognizer) { cam.pinch(g.scale, began: g.state == .began) }
        @objc func tap(_ g: UITapGestureRecognizer) { cam.focus(at: g.location(in: g.view)) }
    }
}

struct ContentView: View {
    @EnvironmentObject var cam: CameraModel
    @State private var showInfo = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview().ignoresSafeArea()
            if cam.denied {
                VStack(spacing: 10) {
                    Text("Camera access is off").font(.headline)
                    Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                }
                .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            VStack {
                HStack(alignment: .top) {
                    if showInfo && !cam.info.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(cam.info, id: \.0) { k, v in
                                Text("\(k): ").foregroundStyle(.secondary) + Text(v)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Spacer()
                    Button { showInfo.toggle() } label: { Image(systemName: "info.circle").font(.title2) }.tint(.white)
                }
                .padding(.horizontal).padding(.top, 8)
                if !cam.message.isEmpty {
                    Text(cam.message).font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 6)
                }
                Spacer()
                if cam.recording {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let s = Int(ctx.date.timeIntervalSince(cam.recordStart))
                        Label(String(format: "%d:%02d", s / 60, s % 60), systemImage: "record.circle.fill")
                            .font(.headline.monospacedDigit()).foregroundStyle(.red)
                            .padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
                    }
                }
                HStack(spacing: 18) {
                    round("arrow.triangle.2.circlepath.camera") { cam.flip() }
                    round(cam.torch ? "flashlight.on.fill" : "flashlight.off.fill", active: cam.torch) { cam.toggleTorch() }
                    Button { cam.toggleRecord() } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                            if cam.recording { RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30) }
                            else { Circle().fill(.red).frame(width: 60, height: 60) }
                        }
                    }
                    round("camera.fill") { cam.photo() }
                    round(cam.pipActive ? "pip.exit" : "pip.enter", active: cam.pipActive) { cam.togglePiP() }
                }
                .padding(.bottom, 24)
                Text("Tap to focus · pinch to zoom · leave the app to test the camera in PiP")
                    .font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8)
            }
        }
        .task { await cam.start() }
    }

    private func round(_ icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                .foregroundStyle(active ? .yellow : .white)
                .frame(width: 50, height: 50).background(.ultraThinMaterial, in: Circle())
        }
    }
}
