import AVFoundation
import CoreImage
import MediaToolbox
import QuartzCore

/// Captures an uploaded video's own audio track (in sync with playback) as 16 kHz mono s16le PCM,
/// via an MTAudioProcessingTap on the player item's audio mix. Keeps the clip's sound for the
/// virtual cam's stream without un-muting the phone speaker.
final class FileAudioTap {
    var onPCM: ((Data, CFTimeInterval) -> Void)?
    private let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var src: AVAudioFormat?
    private var converter: AVAudioConverter?

    func makeMix(for item: AVPlayerItem) {
        guard let track = item.asset.tracks(withMediaType: .audio).first else { return }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, client, storageOut in storageOut.pointee = client },
            finalize: { tap in Unmanaged<FileAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, fmt in
                let me = Unmanaged<FileAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                me.prepare(fmt.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                let me = Unmanaged<FileAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                me.process(bufferList, frames: Int(framesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else { return }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    private func prepare(_ asbd: AudioStreamBasicDescription) {
        var fmt = asbd
        src = AVAudioFormat(streamDescription: &fmt)
        converter = src.flatMap { AVAudioConverter(from: $0, to: dst) }
    }

    private func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0, let src, let converter,
              let input = AVAudioPCMBuffer(pcmFormat: src, bufferListNoCopy: bufferList, deallocator: nil) else { return }
        input.frameLength = AVAudioFrameCount(frames)
        let cap = AVAudioFrameCount(Double(frames) * 16000.0 / src.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        onPCM?(data, CACurrentMediaTime())
    }
}

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

    /// Degrees to rotate each frame before fitting (0/90/180/270). Changeable while playing.
    var rotation = 0
    /// Send the clip's own audio to the stream (the phone speaker stays muted either way).
    var audioOn = true

    private let audioTap = FileAudioTap()

    var onFrame: ((CVPixelBuffer) -> Void)?
    var onAudio: ((Data, CFTimeInterval) -> Void)?
    var onError: ((String) -> Void)?

    init(width: Int, height: Int, rotation: Int = 0) { self.width = width; self.height = height; self.rotation = rotation }

    func start(url: URL) {
        let item = AVPlayerItem(url: url)
        item.add(output)
        if audioOn {
            audioTap.onPCM = { [weak self] pcm, at in self?.onAudio?(pcm, at) }
            audioTap.makeMix(for: item)               // capture the clip's audio for the stream
        }
        player.replaceCurrentItem(with: item)
        player.isMuted = true                         // no local speaker; the tap still captures
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
        var src = CIImage(cvPixelBuffer: pb)
        let deg = ((rotation % 360) + 360) % 360
        if deg != 0 {
            let r = src.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(deg) * .pi / 180))
            src = r.transformed(by: CGAffineTransform(translationX: -r.extent.minX, y: -r.extent.minY))
        }
        let img = FrameOps.cover(src, width, height)
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
