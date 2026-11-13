import AVFoundation
import QuartzCore
import UIKit
import VideoToolbox

/// Plays a LiveChar live link (https://server/watch/<id>) natively: H.264 decoded on the hardware decoder,
/// the new voice played in sync (video waits for it, like the watch page). Gives out decoded frames so the
/// app can show, photograph and record them like a camera.
/// Wire format: [u32 length][u8 flags][u64 timestamp µs][data]; flags 1 key, 2 ended, 4 audio (16 kHz s16le mono).
final class LiveCharFeed: NSObject, URLSessionDataDelegate {
    static func streamURL(from link: String) -> URL? {
        guard let u = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), let host = u.host,
              let scheme = u.scheme, ["http", "https"].contains(scheme) else { return nil }
        let parts = u.path.split(separator: "/")
        guard let i = parts.firstIndex(of: "watch"), i + 1 < parts.count else { return nil }
        var c = URLComponents(); c.scheme = scheme; c.host = host; c.port = u.port
        c.path = "/api/share/\(parts[i + 1])/stream"
        return c.url
    }

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?      // decoded, at the moment it should show (host clock)
    var onAudio: ((Data, CMTime) -> Void)?               // voice PCM, at the moment it plays (host clock)
    var onState: ((String) -> Void)?

    private let q = DispatchQueue(label: "camtest.feed", qos: .userInteractive)
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var url: URL?
    private var buffer = Data()
    private var stopped = true

    // timing (seconds, host clock): due = ts + offset + delay
    private var offset: Double?
    private var delay: Double = 0
    private var lastAudio: Double = 0
    private var held: [(key: Bool, ts: Double, nals: [Data])] = []
    private var pump: DispatchSourceTimer?

    // decoder
    private var sps: Data?, pps: Data?
    private var format: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?
    private var needKey = true

    // voice
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
    }

    func start(_ url: URL) {
        q.async {
            self.url = url; self.stopped = false
            self.reset()
            if !self.engine.isRunning { try? self.engine.start(); self.player.play() }
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now(), repeating: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.release() }
            t.resume()
            self.pump = t
            self.connect()
        }
    }

    func stop() {
        q.async {
            self.stopped = true
            self.task?.cancel(); self.task = nil
            self.pump?.cancel(); self.pump = nil
            self.reset()
            self.player.stop(); self.engine.stop()
        }
    }

    private func reset() {
        buffer.removeAll(); held.removeAll(); offset = nil; delay = 0; needKey = true
        if let d = decoder { VTDecompressionSessionInvalidate(d) }
        decoder = nil; format = nil; sps = nil; pps = nil
    }

    private func connect() {
        guard !stopped, let url else { return }
        buffer.removeAll()
        onState?("connecting…")
        let t = session.dataTask(with: url)
        task = t
        t.resume()
    }

    // MARK: network

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        onState?(code == 200 ? "connected — waiting for LiveChar" : code == 404 ? "unknown link (was it reset?)" : "server error \(code)")
        completionHandler(code == 200 ? .allow : .cancel)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        q.async {
            guard !self.stopped else { return }
            self.buffer.append(data)
            var o = 0
            let b = self.buffer
            while b.count - o >= 4 {
                let len = Int(b[b.startIndex + o]) << 24 | Int(b[b.startIndex + o + 1]) << 16 | Int(b[b.startIndex + o + 2]) << 8 | Int(b[b.startIndex + o + 3])
                if b.count - o - 4 < len { break }
                if len >= 9 { self.packet(b.subdata(in: (b.startIndex + o + 4)..<(b.startIndex + o + 4 + len))) }
                o += 4 + len
            }
            self.buffer = b.subdata(in: (b.startIndex + o)..<b.endIndex)
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        q.asyncAfter(deadline: .now() + 1.5) { if !self.stopped && task === self.task { self.onState?("reconnecting…"); self.connect() } }
    }

    // MARK: packets

    private func packet(_ p: Data) {
        let flags = p[p.startIndex]
        if flags & 2 != 0 { held.removeAll(); offset = nil; needKey = true; onState?("LiveChar stopped — waiting"); return }
        var tsUs: UInt64 = 0
        for i in 1...8 { tsUs = tsUs << 8 | UInt64(p[p.startIndex + i]) }
        let ts = Double(tsUs) / 1e6
        let now = CACurrentMediaTime()
        let o = now - ts
        if offset == nil || o < offset! || o - offset! > 8 { if let off = offset, o - off > 8 { held.removeAll() }; offset = o }
        let body = p.subdata(in: (p.startIndex + 9)..<p.endIndex)
        if flags & 4 != 0 { audio(body, ts: ts); return }
        let item = (key: flags & 1 != 0, ts: ts, nals: splitAnnexB(body))
        if delay == 0 && held.isEmpty { decode(item) } else { held.append(item) }
    }

    private func release() {
        let now = CACurrentMediaTime()
        if delay > 0 && now - lastAudio > 20 { delay = 0 }        // voice stopped: no more waiting
        guard let offset else { return }
        while let f = held.first, f.ts + offset + delay <= now { held.removeFirst(); decode(f) }
        if held.count > 900 { held.removeFirst(held.count - 300) }
    }

    private func audio(_ pcm: Data, ts: Double) {
        lastAudio = CACurrentMediaTime()
        if delay == 0 { delay = 2.5 }
        guard let offset else { return }
        var due = ts + offset + delay
        let now = CACurrentMediaTime()
        if due < now + 0.05 { delay = min(6, delay + (now + 0.05 - due) + 0.25); due = now + 0.05 }
        let n = pcm.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(n)), let dst = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(n)
        pcm.withUnsafeBytes { raw in let s = raw.bindMemory(to: Int16.self); for i in 0..<n { dst[i] = Float(Int16(littleEndian: s[i])) / 32768 } }
        player.scheduleBuffer(buf, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: due)), options: [], completionHandler: nil)
        onAudio?(pcm, CMTime(seconds: due, preferredTimescale: 1_000_000))
        if !player.isPlaying { player.play() }
    }

    // MARK: H.264

    private func splitAnnexB(_ d: Data) -> [Data] {
        var out: [Data] = []
        let b = [UInt8](d)
        var i = 0, start = -1
        while i + 3 <= b.count {
            if b[i] == 0 && b[i + 1] == 0 && (b[i + 2] == 1 || (i + 3 < b.count && b[i + 2] == 0 && b[i + 3] == 1)) {
                let sc = b[i + 2] == 1 ? 3 : 4
                if start >= 0 { out.append(Data(b[start..<i])) }
                start = i + sc; i += sc
            } else { i += 1 }
        }
        if start >= 0 && start < b.count { out.append(Data(b[start...])) }
        return out
    }

    private func decode(_ f: (key: Bool, ts: Double, nals: [Data])) {
        var slices: [Data] = []
        for nal in f.nals where !nal.isEmpty {
            switch nal[nal.startIndex] & 0x1f {
            case 7: if nal != sps { sps = nal; format = nil }
            case 8: if nal != pps { pps = nal; format = nil }
            default: slices.append(nal)
            }
        }
        if format == nil, let sps, let pps { makeDecoder(sps, pps) }
        if f.key { needKey = false }
        guard !needKey, let decoder, let format, !slices.isEmpty else { return }

        var avcc = Data()
        for s in slices { var len = UInt32(s.count).bigEndian; avcc.append(Data(bytes: &len, count: 4)); avcc.append(s) }
        var block: CMBlockBuffer?
        let size = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) }
        var sb: CMSampleBuffer?
        var sizes = [size]
        let show = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: show, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sb) == noErr, let sb else { return }
        let st = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] status, _, image, pts, _ in
            guard status == noErr, let image else { return }
            self?.onFrame?(image, pts)
        }
        if st != noErr { needKey = true; self.format = nil }
    }

    private func makeDecoder(_ sps: Data, _ pps: Data) {
        if let d = decoder { VTDecompressionSessionInvalidate(d); decoder = nil }
        var fmt: CMVideoFormatDescription?
        let ok: OSStatus = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
            let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = [sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                                                                       parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        } }
        guard ok == noErr, let fmt else { return }
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        var d: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &d) == noErr, let d else { return }
        VTSessionSetProperty(d, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decoder = d; format = fmt
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        onState?("live · \(dims.width)×\(dims.height)")
    }

    var delaySeconds: Double { q.sync { delay } }
}

/// Shows decoded pixel buffers (feed mode) — hardware composited.
final class FrameLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

extension AVSampleBufferDisplayLayer {
    func show(_ pb: CVPixelBuffer) {
        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt) == noErr, let fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if status == .failed { flush() }
        enqueue(sb)
    }
}

/// Records the feed (video + voice) to an .mp4, in real time.
final class FeedRecorder {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let lock = NSLock()
    private var started = false
    let url: URL

    init(width: Int, height: Int) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("camtest-feed-\(Int(Date().timeIntervalSince1970)).mp4")
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                                                                      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]])
        video.expectsMediaDataInRealTime = true
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1])
        audio.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        writer.add(video); writer.add(audio)
    }

    private func begin(_ t: CMTime) -> Bool {
        if !started { guard writer.startWriting() else { return false }; writer.startSession(atSourceTime: t); started = true }
        return true
    }

    func append(_ pb: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        guard begin(t), video.isReadyForMoreMediaData else { return }
        adaptor.append(pb, withPresentationTime: t)
    }

    /// voice PCM at the moment it plays
    func append(pcm: Data, at t: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard started, audio.isReadyForMoreMediaData else { return }
        var asbd = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt) == noErr, let fmt else { return }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: pcm.count, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: pcm.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        _ = pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: pcm.count) }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: pcm.count / 2,
                                                                   presentationTimeStamp: t, packetDescriptions: nil, sampleBufferOut: &sb) == noErr, let sb else { return }
        audio.append(sb)
    }

    func finish() async -> URL? {
        lock.lock(); let s = started; lock.unlock()
        guard s else { return nil }
        video.markAsFinished(); audio.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        return writer.status == .completed ? url : nil
    }
}
