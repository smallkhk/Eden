import AVFoundation
import CoreImage
import QuartzCore

/// Plays an uploaded video on a loop and emits frames (portrait, aspect-fill to the target size) — fed
/// straight to the output pipeline as the "camera", no AI engine and no billing.
final class VideoFilePlayer {
    private let player = AVPlayer()
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    private var link: CADisplayLink?
    private let pool = PixelPool()
    private let width: Int, height: Int
    private var observer: NSObjectProtocol?

    var onFrame: ((CVPixelBuffer) -> Void)?
    var onError: ((String) -> Void)?

    init(width: Int, height: Int) { self.width = width; self.height = height }

    func start(url: URL) {
        let item = AVPlayerItem(url: url)
        item.add(output)
        player.replaceCurrentItem(with: item)
        player.isMuted = true                         // a camera has no sound
        player.actionAtItemEnd = .none
        observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.player.seek(to: .zero); self?.player.play()
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] n in
            let e = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self?.onError?(e?.localizedDescription ?? "Could not play that video")
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        self.link = link
        player.play()
    }

    @objc private func tick() {
        let host = CACurrentMediaTime()
        let t = output.itemTime(forHostTime: host)
        guard t.isValid, output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        let img = FrameOps.cover(CIImage(cvPixelBuffer: pb), width, height)
        if let out = FrameOps.render(img, into: pool, width, height) { onFrame?(out) }
    }

    func stop() {
        link?.invalidate(); link = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
