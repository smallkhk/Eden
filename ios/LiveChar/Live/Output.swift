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

    /// how much later the AI video shows a movement than the mic hears it (lip sync), seconds
    var avOffset: CFTimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _avOffset }
        set { lock.lock(); _avOffset = newValue; lock.unlock() }
    }
    private var _avOffset: CFTimeInterval = 0.3
    private var recordedVoice: [(Data, CFTimeInterval)] = []

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

    /// A phrase in the new voice, with the time it was spoken (host clock). Goes into the recording
    /// and the live link, placed so it lines up with the lips.
    func addVoice(_ pcm: Data, spokenAt: CFTimeInterval) {
        let at = spokenAt + avOffset
        queue.async {
            if self.recorder != nil { self.recordedVoice.append((pcm, at)) }
            self.streamer?.sendAudio(pcm, at: at)
        }
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
            do { recorder = try Recorder(size: FrameOps.size(pb)); recordedVoice = [] } catch { err = error }
        }
        if let err { throw err }
    }

    var isRecording: Bool { queue.sync { recorder != nil } }

    func stopRecording() async throws {
        let (r, voice): (Recorder?, [(Data, CFTimeInterval)]) = queue.sync {
            let r = recorder; recorder = nil
            let v = recordedVoice; recordedVoice = []
            return (r, v)
        }
        guard let r, let url = await r.finish() else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        if !voice.isEmpty, let merged = try? await AVMerge.withVoice(video: url, videoStart: r.startTime, phrases: voice) {
            defer { try? FileManager.default.removeItem(at: merged) }
            try await PhotoLibrary.saveVideo(merged)
        } else {
            try await PhotoLibrary.saveVideo(url)
        }
    }
}

/// H.264 .mp4 of the output, real time.
final class Recorder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let size: CGSize
    private var started = false
    private(set) var startTime: CFTimeInterval = 0
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
            startTime = t.seconds
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

/// Puts the new-voice phrases on the recorded video at the moments they were spoken.
enum AVMerge {
    static func withVoice(video: URL, videoStart: CFTimeInterval, phrases: [(Data, CFTimeInterval)]) async throws -> URL {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        let total = max(1, Int(duration.seconds * 16000))
        var mix = [Float](repeating: 0, count: total)
        for (pcm, at) in phrases {
            let pos = Int(((at - videoStart) * 16000).rounded())
            pcm.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                for i in 0..<s.count {
                    let j = pos + i
                    if j >= 0 && j < total { mix[j] = max(-1, min(1, mix[j] + Float(Int16(littleEndian: s[i])) / 32768)) }
                }
            }
        }

        let tmp = FileManager.default.temporaryDirectory
        let audioURL = tmp.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1],
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            var o = 0
            while o < total {
                let n = min(16000, total - o)
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)), let dst = buf.floatChannelData?[0] else { break }
                buf.frameLength = AVAudioFrameCount(n)
                mix.withUnsafeBufferPointer { src in dst.update(from: src.baseAddress! + o, count: n) }
                try file.write(from: buf)
                o += n
            }
        }   // file closes here
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let comp = AVMutableComposition()
        guard let vSrc = try await asset.loadTracks(withMediaType: .video).first,
              let vDst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw APIError(message: "No video in the recording", status: 0)
        }
        try vDst.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: vSrc, at: .zero)
        vDst.preferredTransform = try await vSrc.load(.preferredTransform)
        let audioAsset = AVURLAsset(url: audioURL)
        if let aSrc = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let aDst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let aDur = try await audioAsset.load(.duration)
            try aDst.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(aDur, duration)), of: aSrc, at: .zero)
        }
        let out = tmp.appendingPathComponent("livechar-\(Int(Date().timeIntervalSince1970)).mp4")
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw APIError(message: "Could not save the video", status: 0)
        }
        export.outputURL = out
        export.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { throw export.error ?? APIError(message: "Could not save the video", status: 0) }
        return out
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
