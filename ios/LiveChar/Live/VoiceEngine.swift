import AVFoundation
import Foundation
import QuartzCore

/// Splits 16 kHz mono speech into phrases at short pauses (port of Courier's SpeechChunker).
/// Each phrase carries the host time of its first sample, so the new voice can be put back
/// exactly where it was spoken.
final class SpeechChunker {
    private let frameSamples = 320            // 20 ms
    private let frameMs = 20.0
    private let pauseMs = 350.0
    private let maxMs = 2500.0                // shorter phrases = less delay
    private let minSpeechMs = 200.0
    private let preRollFrames = 6             // 120 ms before speech starts

    private var pending: [Int16] = []
    private var pendingTime: CFTimeInterval = 0
    private var frames: [[Int16]] = []
    private var phraseStart: CFTimeInterval = 0
    private var preRoll: [([Int16], CFTimeInterval)] = []
    private var speaking = false
    private var silentMs = 0.0
    private var speechMs = 0.0
    private var noiseFloor = 300.0

    func push(_ samples: [Int16], start: CFTimeInterval) -> [(pcm: [Int16], start: CFTimeInterval)] {
        if pending.isEmpty { pendingTime = start }
        pending += samples
        var out: [(pcm: [Int16], start: CFTimeInterval)] = []
        while pending.count >= frameSamples {
            let frame = Array(pending[0..<frameSamples])
            pending.removeFirst(frameSamples)
            let t = pendingTime
            pendingTime += frameMs / 1000
            if let p = feed(frame, at: t) { out.append(p) }
        }
        return out
    }

    func flush() -> (pcm: [Int16], start: CFTimeInterval)? {
        defer { reset() }
        guard speaking, speechMs >= minSpeechMs else { return nil }
        return (frames.flatMap { $0 }, phraseStart)
    }

    private func reset() { frames = []; speaking = false; silentMs = 0; speechMs = 0 }

    private func feed(_ frame: [Int16], at t: CFTimeInterval) -> (pcm: [Int16], start: CFTimeInterval)? {
        var sum = 0.0
        for s in frame { let v = Double(s); sum += v * v }
        let level = (sum / Double(frame.count)).squareRoot()
        let loud = level > max(500, noiseFloor * 3)
        if !speaking {
            if !loud { noiseFloor = noiseFloor * 0.95 + level * 0.05 }
            preRoll.append((frame, t))
            if preRoll.count > preRollFrames { preRoll.removeFirst() }
            if loud {
                speaking = true
                frames = preRoll.map { $0.0 }
                phraseStart = preRoll.first?.1 ?? t
                preRoll = []
                speechMs = frameMs; silentMs = 0
            }
            return nil
        }
        frames.append(frame)
        if loud { speechMs += frameMs; silentMs = 0 } else { silentMs += frameMs }
        if silentMs >= pauseMs || Double(frames.count) * frameMs >= maxMs { return flush() }
        return nil
    }
}

/// Natural voice changer: mic → phrases → server (/api/voice/convert, ElevenLabs speech-to-speech)
/// → the new voice, played in order (if "hear it" is on) and handed on with the phrase's original time.
final class VoiceEngine {
    struct Events {
        var converted: (Data, CFTimeInterval) -> Void = { _, _ in }   // 16 kHz s16le mono, original start (host time)
        var state: (String) -> Void = { _ in }
        var failed: (String) -> Void = { _ in }
        var balance: (Double) -> Void = { _ in }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let out16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var converter: AVAudioConverter?
    private let chunker = SpeechChunker()
    private let queue = DispatchQueue(label: "livechar.voice", qos: .userInitiated)
    private var waiting: [(pcm: [Int16], start: CFTimeInterval)] = []
    private var busy = false
    private var stopped = false
    private let voiceID: String
    private let events: Events

    var monitor = false { didSet { player.volume = monitor ? 1 : 0 } }

    init(voiceID: String, events: Events) {
        self.voiceID = voiceID
        self.events = events
    }

    static func authorize() async -> Bool {
        await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
    }

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw APIError(message: "No microphone available", status: 0) }
        converter = AVAudioConverter(from: inFormat, to: out16)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, when in self?.captured(buf, when) }
        engine.prepare()
        try engine.start()
        player.play()
        player.volume = monitor ? 1 : 0
        events.state("listening")
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.waiting.removeAll()
        }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    // MARK: capture

    private func captured(_ buf: AVAudioPCMBuffer, _ when: AVAudioTime) {
        let t = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : CACurrentMediaTime()
        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: out16, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        queue.async {
            guard !self.stopped else { return }
            for phrase in self.chunker.push(samples, start: t) { self.waiting.append(phrase) }
            self.next()
        }
    }

    // MARK: convert, one phrase at a time so they play in order

    private func next() {
        guard !busy, !stopped, !waiting.isEmpty else { return }
        busy = true
        let phrase = waiting.removeFirst()
        // fell far behind (slow network): drop old phrases rather than speaking late
        if waiting.count > 3 { waiting.removeFirst(waiting.count - 3) }
        Task {
            await self.convert(phrase)
            self.queue.async { self.busy = false; self.next() }
        }
    }

    private func convert(_ phrase: (pcm: [Int16], start: CFTimeInterval)) async {
        events.state("changing voice…")
        let body = phrase.pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            var req = try API.shared.request("/api/voice/convert?voice=\(voiceID)", method: "POST")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            req.timeoutInterval = 20
            let (bytes, resp) = try await API.shared.session.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                var d = Data()
                for try await b in bytes { d.append(b) }
                let msg = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String ?? "Voice error (HTTP \(code))"
                events.failed(msg)
                return
            }
            if let b = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Balance").flatMap(Double.init) { events.balance(b) }
            var all = Data()
            var chunk = Data()
            chunk.reserveCapacity(6400)
            for try await b in bytes {
                chunk.append(b)
                if chunk.count >= 6400 { play(chunk); all.append(chunk); chunk.removeAll(keepingCapacity: true) }
            }
            if chunk.count % 2 == 1 { chunk.removeLast() }
            if !chunk.isEmpty { play(chunk); all.append(chunk) }
            if !all.isEmpty { events.converted(all, phrase.start) }
            events.state("listening")
        } catch {
            if !stopped { events.state("voice: network problem, retrying with the next phrase") }
        }
    }

    private func play(_ pcm: Data) {
        let n = pcm.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(n)), let dst = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(n)
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<n { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        player.scheduleBuffer(buf, completionHandler: nil)
    }
}

enum VoiceAudioSession {
    /// Mic + speaker together (also keeps PiP working).
    static func activate() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try s.setPreferredIOBufferDuration(0.02)
        try s.setActive(true)
    }
}
