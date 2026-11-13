import UIKit
import AVFoundation

// Minimal camera test target. Opens the camera the normal way (AVCaptureSession +
// AVCaptureVideoDataOutput) and draws every frame full-screen, with a live readout of
// resolution and fps. Purpose: a clean app to inject a dylib into and confirm the frames
// get swapped — if the preview changes and the readout still ticks, the hook works.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = CameraViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

final class CameraViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camtest.camera")
    private let imageView = UIImageView()
    private let label = UILabel()
    private let ciContext = CIContext()
    private var position: AVCaptureDevice.Position = .back

    private var frames = 0
    private var lastTick = CACurrentMediaTime()
    private var fps = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        view.addSubview(imageView)

        label.frame = CGRect(x: 16, y: 56, width: view.bounds.width - 32, height: 44)
        label.autoresizingMask = [.flexibleWidth]
        label.textColor = .green
        label.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        label.numberOfLines = 2
        label.text = "starting camera…"
        view.addSubview(label)

        let flip = UIButton(type: .system)
        flip.setTitle("Flip", for: .normal)
        flip.setTitleColor(.white, for: .normal)
        flip.titleLabel?.font = .boldSystemFont(ofSize: 17)
        flip.frame = CGRect(x: view.bounds.width - 90, y: view.bounds.height - 90, width: 74, height: 44)
        flip.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
        flip.backgroundColor = UIColor(white: 0, alpha: 0.4)
        flip.layer.cornerRadius = 10
        flip.addTarget(self, action: #selector(flipCamera), for: .touchUpInside)
        view.addSubview(flip)

        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                if ok { self.configure() } else { self.label.text = "Camera permission denied" }
            }
        }
    }

    private func configure() {
        queue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            self.session.inputs.forEach { self.session.removeInput($0) }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.position),
                  let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                DispatchQueue.main.async { self.label.text = "No camera available" }
                self.session.commitConfiguration()
                return
            }
            self.session.addInput(input)
            if !self.session.outputs.contains(self.output) {
                self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            }
            if let c = self.output.connection(with: .video) {
                if #available(iOS 17.0, *) { if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 } }
                else if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
            }
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    @objc private func flipCamera() {
        position = position == .back ? .front : .back
        configure()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let image = UIImage(cgImage: cg)

        frames += 1
        let now = CACurrentMediaTime()
        if now - lastTick >= 1 { fps = Int(Double(frames) / (now - lastTick)); frames = 0; lastTick = now }

        DispatchQueue.main.async {
            self.imageView.image = image
            self.label.text = "\(w)×\(h)  ·  \(self.fps) fps  ·  \(self.position == .back ? "back" : "front")"
        }
    }
}
