import AVFoundation
import SwiftUI
import UIKit

/// Shows pixel buffers through AVSampleBufferDisplayLayer: hardware composited, no copies, no main-thread work.
/// With `zoomable`, pinch to zoom (1x–4x), drag to move, double-tap to reset.
final class VideoSurface: UIView {
    private let videoLayer = AVSampleBufferDisplayLayer()
    private let enqueueQueue = DispatchQueue(label: "livechar.surface", qos: .userInteractive)
    var framing = Framing.full { didSet { if framing != oldValue { setNeedsLayout(); onFraming?(framing) } } }
    var onFraming: ((Framing) -> Void)?
    var mirrored = false { didSet { setNeedsLayout() } }
    var zoomable = false { didSet { gestureRecognizers?.forEach { $0.isEnabled = zoomable } } }

    private var pinchStart: (framing: Framing, contentPoint: CGPoint)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(videoLayer)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 2
        let dbl = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
        dbl.numberOfTapsRequired = 2
        [pinch, pan, dbl].forEach { $0.isEnabled = false; addGestureRecognizer($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let z = framing.zoom, W = bounds.width, H = bounds.height
        videoLayer.transform = CATransform3DIdentity
        videoLayer.frame = CGRect(x: -framing.rect.minX * W * z, y: -framing.rect.minY * H * z, width: W * z, height: H * z)
        layer.sublayerTransform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    /// any thread
    func show(_ pb: CVPixelBuffer) {
        guard let sb = FrameOps.sampleBuffer(pb) else { return }
        enqueueQueue.async { [videoLayer] in
            if videoLayer.status == .failed { videoLayer.flush() }
            videoLayer.enqueue(sb)
        }
    }

    func flush() {
        enqueueQueue.async { [videoLayer] in videoLayer.flushAndRemoveImage() }
    }

    // point in the view (0...1), corrected for the mirror
    private func viewPoint(_ p: CGPoint) -> CGPoint {
        let x = p.x / max(bounds.width, 1), y = p.y / max(bounds.height, 1)
        return CGPoint(x: mirrored ? 1 - x : x, y: y)
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        let u = viewPoint(g.location(in: self))
        switch g.state {
        case .began:
            let r = framing.rect
            pinchStart = (framing, CGPoint(x: r.minX + u.x * r.width, y: r.minY + u.y * r.height))
        case .changed:
            guard let s = pinchStart else { return }
            let z = min(4, max(1, s.framing.zoom * g.scale)), side = 1 / z
            // keep the spot under the fingers where it is
            let origin = CGPoint(x: s.contentPoint.x - u.x * side, y: s.contentPoint.y - u.y * side)
            framing = Framing.make(zoom: z, center: CGPoint(x: origin.x + side / 2, y: origin.y + side / 2))
        default: pinchStart = nil
        }
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        guard framing.zoom > 1.001, g.numberOfTouches == 1 || g.state == .ended else { g.setTranslation(.zero, in: self); return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let side = framing.rect.width
        let dx = (mirrored ? -t.x : t.x) / max(bounds.width, 1) * side, dy = t.y / max(bounds.height, 1) * side
        framing = Framing.make(zoom: framing.zoom, center: CGPoint(x: framing.center.x - dx, y: framing.center.y - dy))
    }

    @objc private func onDoubleTap() {
        UIView.animate(withDuration: 0.2) { self.framing = .full; self.layoutIfNeeded() }
    }

    func setZoom(_ z: CGFloat) { framing = Framing.make(zoom: z, center: framing.center) }
}

/// SwiftUI wrapper. `onMake` hands out the UIView so a controller can feed it.
struct VideoSurfaceView: UIViewRepresentable {
    var mirrored: Bool
    var zoomable: Bool
    var onMake: (VideoSurface) -> Void

    func makeUIView(context: Context) -> VideoSurface {
        let v = VideoSurface()
        v.mirrored = mirrored; v.zoomable = zoomable
        onMake(v)
        return v
    }
    func updateUIView(_ v: VideoSurface, context: Context) {
        if v.mirrored != mirrored { v.mirrored = mirrored }
        if v.zoomable != zoomable { v.zoomable = zoomable }
    }
}
