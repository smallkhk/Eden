import AVFoundation
import AVKit
import UIKit

/// Video-call style picture-in-picture: the AI output floats over other apps (Safari, Discord…) and,
/// because the app declares the voip background mode, the camera and the stream keep running behind it.
/// Starts by itself when you leave the app while live, or with the PiP button.
final class PiPController: NSObject, AVPictureInPictureControllerDelegate {
    private var controller: AVPictureInPictureController?
    private let callVC = AVPictureInPictureVideoCallViewController()
    let surface = VideoSurface()
    private weak var source: UIView?

    var onActive: ((Bool) -> Void)?
    private(set) var isActive = false

    static var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    override init() {
        super.init()
        surface.frame = callVC.view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        callVC.view.backgroundColor = .black
        callVC.view.addSubview(surface)
        callVC.preferredContentSize = CGSize(width: 720, height: 1280)
    }

    /// The on-screen output view the PiP window animates from.
    func attach(source view: UIView) {
        guard Self.supported, source !== view else { return }
        source = view
        let content = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: view, contentViewController: callVC)
        let c = AVPictureInPictureController(contentSource: content)
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.delegate = self
        controller = c
    }

    func setAspect(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        callVC.preferredContentSize = size
    }

    /// Only offer automatic PiP while a session is live.
    func setEnabled(_ on: Bool) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = on
        if !on, isActive { controller?.stopPictureInPicture() }
    }

    func start() { controller?.startPictureInPicture() }
    func stop() { controller?.stopPictureInPicture() }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        isActive = true; onActive?(true)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        isActive = false; onActive?(false)
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        isActive = false; onActive?(false)
    }
}

enum AudioSessionSetup {
    /// PiP needs an active audio session. Plays nothing; doesn't use the microphone.
    static func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [])
        try? s.setActive(true)
    }
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
