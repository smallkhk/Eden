import AVFoundation
import CoreImage
import Photos
import UIKit

/// Everything that happens to the AI output frames: on screen (smooth, GPU), photo, recording, share-live stream.
final class OutputHub {
    private let queue = DispatchQueue(label: "livechar.output", qos: .userInteractive)
    private let framedPool = PixelPool()
    private let lock = NSLock()

    private var _framing = Framing.full
    var framing: Framing {
        get { lock.lock(); defer { lock.unlock() }; return _framing }
        set { lock.lock(); _framing = newValue; lock.unlock() }
    }

    weak var display: VideoSurface?
    weak var pipDisplay: VideoSurface?
    private(set) var lastFrame: CVPixelBuffer?
    private var recorder: Recorder?
    private var _streamer: ShareStreamer?
    var streamer: ShareStreamer? {
        get { lock.lock(); defer { lock.unlock() }; return _streamer }
        set { lock.lock(); _streamer = newValue; lock.unlock() }
    }

    /// main thread: first frame of a session, size changes, fps
    var onFirstFrame: (() -> Void)?
    var onSize: ((CGSize) -> Void)?
    var onFPS: ((Int) -> Void)?
    private var gotFirst = false
    private var size = CGSize.zero
    private var fpsCount = 0
    private var fpsStart = CACurrentMediaTime()

    func reset() {
        queue.async {
            self.gotFirst = false
            self.lastFrame = nil
            self.display?.flush()
            self.pipDisplay?.flush()
        }
    }

    func push(_ pb: CVPixelBuffer) {
        queue.async { self.handle(pb) }
    }

    private func handle(_ pb: CVPixelBuffer) {
        lastFrame = pb
        let s = FrameOps.size(pb)
        if s != size { size = s; DispatchQueue.main.async { self.onSize?(s) } }
        if !gotFirst { gotFirst = true; DispatchQueue.main.async { self.onFirstFrame?() } }
        display?.show(pb)
        pipDisplay?.show(pb)

        fpsCount += 1
        let now = CACurrentMediaTime()
        if now - fpsStart >= 1 {
            let f = Int((Double(fpsCount) / (now - fpsStart)).rounded())
            fpsCount = 0; fpsStart = now
            DispatchQueue.main.async { self.onFPS?(f) }
        }

        let streamer = self.streamer
        guard recorder != nil || streamer != nil else { return }
        let out = framed(pb) ?? pb
        recorder?.append(out)
        streamer?.encode(out)
    }

    /// the frame with the current zoom applied (nil = no zoom)
    private func framed(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        let f = framing
        guard !f.isFull else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        return FrameOps.render(FrameOps.framed(CIImage(cvPixelBuffer: pb), f), into: framedPool, w, h)
    }

    // MARK: photo

    func photo() async throws {
        let data: Data? = await withCheckedContinuation { c in
            queue.async {
                guard let pb = self.lastFrame else { c.resume(returning: nil); return }
                let img = FrameOps.framed(CIImage(cvPixelBuffer: pb), self.framing)
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                c.resume(returning: GPU.ci.jpegRepresentation(of: img, colorSpace: cs, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]))
            }
        }
        guard let data else { throw APIError(message: "Go live first, then take a photo", status: 0) }
        try await PhotoLibrary.saveImage(data)
    }

    // MARK: recording

    func startRecording() throws {
        var err: Error?
        queue.sync {
            guard let pb = lastFrame else { err = APIError(message: "Go live first, then record", status: 0); return }
            do { recorder = try Recorder(size: FrameOps.size(pb)) } catch { err = error }
        }
        if let err { throw err }
    }

    var isRecording: Bool { queue.sync { recorder != nil } }

    func stopRecording() async throws {
        let r: Recorder? = queue.sync { let r = recorder; recorder = nil; return r }
        guard let r, let url = await r.finish() else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        try await PhotoLibrary.saveVideo(url)
    }
}

/// H.264 .mp4 of the output, real time.
final class Recorder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let size: CGSize
    private var started = false
    let url: URL

    init(size: CGSize) throws {
        self.size = size
        url = FileManager.default.temporaryDirectory.appendingPathComponent("livechar-\(Int(Date().timeIntervalSince1970)).mp4")
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoExpectedSourceFrameRateKey: 30],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw APIError(message: "Recording is not available", status: 0) }
        writer.add(input)
    }

    func append(_ pb: CVPixelBuffer) {
        guard FrameOps.size(pb) == size else { return }
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: t); started = true
        }
        if input.isReadyForMoreMediaData { adaptor.append(pb, withPresentationTime: t) }
    }

    func finish() async -> URL? {
        guard started else { return nil }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        return writer.status == .completed ? url : nil
    }
}

enum PhotoLibrary {
    private static func allowed() async -> Bool {
        let s = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return s == .authorized || s == .limited
    }
    static func saveImage(_ data: Data) async throws {
        guard await allowed() else { throw APIError(message: "Allow LiveChar to add to Photos in Settings", status: 0) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
    static func saveVideo(_ url: URL) async throws {
        guard await allowed() else { throw APIError(message: "Allow LiveChar to add to Photos in Settings", status: 0) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
