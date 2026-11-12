import AVFoundation
import CoreImage
import QuartzCore

/// Camera → exactly the size and fps the engine wants, upright, as NV12 pixel buffers (GPU crop/scale).
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "livechar.camera", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private let pool = PixelPool()
    private var coordinator: AnyObject?
    private var rotationObservation: NSKeyValueObservation?

    // read and written on `queue`
    private var width = 1280, height = 720
    private var fps: Double = 30
    private var extraRotation = 0
    private var lastSent: CFTimeInterval = 0

    /// true when iOS lets the camera keep running while LiveChar is in the background (in PiP)
    var worksInBackground: Bool {
        if #available(iOS 16.0, *) { return session.isMultitaskingCameraAccessSupported }
        return false
    }

    /// Called on the camera queue with each processed frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    private(set) var position: AVCaptureDevice.Position = .front

    static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func configure(width: Int, height: Int, fps: Double) {
        queue.async { self.width = width; self.height = height; self.fps = fps }
    }

    /// Extra clockwise rotation in degrees (0, 90, 180, 270), for unusual mounts.
    func setRotation(_ degrees: Int) {
        queue.async { self.extraRotation = ((degrees % 360) + 360) % 360 }
    }

    func start(position: AVCaptureDevice.Position) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.setup(position: position); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }

    func switchCamera() async throws {
        try await start(position: position == .front ? .back : .front)
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.rotationObservation = nil
            self.coordinator = nil
        }
    }

    private func setup(position: AVCaptureDevice.Position) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video) else {
            throw APIError(message: "No camera found", status: 0)
        }
        let newInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        // keep the camera running behind picture-in-picture (needs the voip background mode, iOS 18+)
        if #available(iOS 16.0, *), session.isMultitaskingCameraAccessSupported, !session.isMultitaskingCameraAccessEnabled {
            session.isMultitaskingCameraAccessEnabled = true
        }
        if let input { session.removeInput(input) }
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        guard session.canAddInput(newInput) else { session.commitConfiguration(); throw APIError(message: "Can't open that camera", status: 0) }
        session.addInput(newInput)
        input = newInput
        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        if let conn = output.connection(with: .video) {
            if conn.isVideoMirroringSupported { conn.automaticallyAdjustsVideoMirroring = false; conn.isVideoMirrored = false }
        }
        session.commitConfiguration()
        self.position = device.position

        // keep the picture upright whichever way the phone is held
        rotationObservation = nil
        if #available(iOS 17.0, *) {
            let rc = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            coordinator = rc
            applyAngle(rc.videoRotationAngleForHorizonLevelCapture)
            rotationObservation = rc.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] rc, _ in
                let angle = rc.videoRotationAngleForHorizonLevelCapture
                self?.queue.async { self?.applyAngle(angle) }
            }
        } else if let conn = output.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
        if !session.isRunning { session.startRunning() }
    }

    @available(iOS 17.0, *)
    private func applyAngle(_ angle: CGFloat) {
        guard let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(angle) else { return }
        conn.videoRotationAngle = angle
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer), let onFrame else { return }
        let now = CACurrentMediaTime()
        if now - lastSent < (1 / fps) - 0.004 { return }      // hold the engine's frame rate
        lastSent = now
        var image = CIImage(cvPixelBuffer: pb)
        switch extraRotation {
        case 90: image = image.oriented(.right)
        case 180: image = image.oriented(.down)
        case 270: image = image.oriented(.left)
        default: break
        }
        guard let out = FrameOps.render(FrameOps.cover(image, width, height), into: pool, width, height) else { return }
        onFrame(out, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
