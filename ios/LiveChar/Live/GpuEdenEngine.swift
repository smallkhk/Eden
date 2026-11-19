import CoreVideo
import Foundation
import LiveKitWebRTC
import QuartzCore

/// Eden 5B on your own RunPod GPU. Same "control" data-channel messages as EdenEngine (fal),
/// but the offer goes straight to the pod (https://<pod>-8000.proxy.runpod.net/offer) with a short
/// signed ticket from the LiveChar server (/api/gpu/connect), and media runs through the pod's
/// TURN relay over TCP. Character images that are not a fal URL are sent over HTTP (they are too big
/// for a data-channel message).
final class GpuEdenEngine: NSObject, LiveEngine, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate, LKRTCVideoRenderer, @unchecked Sendable {
    struct Ticket: Decodable {
        struct Ice: Decodable { let urls: [String]; let username: String?; let credential: String? }
        let url: String
        let token: String
        let iceServers: [Ice]
    }

    private static let factory: LKRTCPeerConnectionFactory = {
        _ = LKRTCInitializeSSL()
        return LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
    }()

    private let events: EngineEvents
    private let sessionID: String
    private var podURL = ""
    private var pc: LKRTCPeerConnection?
    private var channel: LKRTCDataChannel?
    private var source: LKRTCVideoSource?
    private var capturer: LKRTCVideoCapturer?
    private var remoteTrack: LKRTCVideoTrack?
    private var pinger: Task<Void, Never>?
    private var queued: [String] = []
    private var stopping = false
    private var failed = false
    private var rtt: Int?
    private let lock = NSLock()
    private let pool = PixelPool()
    private let gather = Once<Void>()
    private var relays = 0
    private var quietTimer: DispatchWorkItem?

    /// Returns the character "look" for an image: a fal URL (https://…) or a data URL (data:image/…).
    var buildLook: ((Data) async throws -> String)?

    /// Eden face lock: HyperSwap the exact face from the original photo onto every Eden frame.
    var faceLock = true
    var faceImage: String?          // original reference photo (data URL) for the face lock

    func setFaceLock(_ on: Bool) {
        faceLock = on
        sendControl(["type": "options", "face_lock": on])
    }

    init(sessionID: String, events: EngineEvents) {
        self.sessionID = sessionID
        self.events = events
    }

    // MARK: start

    func start(prompt: String, look: String?) async throws {
        events.state("connecting…", false)
        let ticket: Ticket = try await API.shared.post("/api/gpu/connect", ["id": sessionID])
        podURL = ticket.url

        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = ticket.iceServers.map { LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.iceTransportPolicy = .relay          // the pod is only reachable through its TURN relay
        config.continualGatheringPolicy = .gatherOnce
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw APIError(message: "Could not create the video connection", status: 0)
        }
        self.pc = pc

        let source = Self.factory.videoSource()
        self.source = source
        capturer = LKRTCVideoCapturer(delegate: source)
        let track = Self.factory.videoTrack(with: source, trackId: "camera")
        let tinit = LKRTCRtpTransceiverInit()
        tinit.direction = .sendRecv
        tinit.streamIds = ["livechar"]
        // Send the camera at full quality: high bitrate floor, never shrink the picture to save bandwidth.
        let enc = LKRTCRtpEncodingParameters()
        enc.isActive = true
        enc.maxBitrateBps = NSNumber(value: 6_000_000)
        enc.minBitrateBps = NSNumber(value: 2_000_000)
        enc.maxFramerate = NSNumber(value: 30)
        tinit.sendEncodings = [enc]
        if let tr = pc.addTransceiver(with: track, init: tinit) {
            let p = tr.sender.parameters
            p.degradationPreference = NSNumber(value: LKRTCDegradationPreference.maintainResolution.rawValue)
            tr.sender.parameters = p
        }

        let dcConfig = LKRTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        channel = pc.dataChannel(forLabel: "control", configuration: dcConfig)
        channel?.delegate = self

        let offer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.offer(for: constraints) { sd, err in
                if let sd { c.resume(returning: sd) } else { c.resume(throwing: err ?? APIError(message: "No offer", status: 0)) }
            }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(offer) { err in if let err { c.resume(throwing: err) } else { c.resume() } }
        }
        try? await gather.wait(timeout: 8, "Relay timed out")
        guard let local = pc.localDescription else { throw APIError(message: "No local description", status: 0) }

        events.state("negotiating…", false)
        var body: [String: Any] = ["sdp": local.sdp, "type": "offer", "token": ticket.token]
        if let look, look.hasPrefix("data:") { body["image"] = look }
        if faceLock, let faceImage { body["face_image"] = faceImage }
        let answer = try await pod("/offer", body, timeout: 30)
        guard let sdp = answer["sdp"] as? String else { throw APIError(message: "GPU: no answer", status: 0) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp)) { err in if let err { c.resume(throwing: err) } else { c.resume() } }
        }

        var cfg: [String: Any] = ["type": "configure", "face_lock": faceLock]
        let text = prompt.isEmpty ? (look != nil ? EdenEngine.swapPrompt : "") : prompt
        if !text.isEmpty { cfg["prompt"] = text }
        if let look, !look.hasPrefix("data:") { cfg["image_url"] = look }
        sendControl(cfg)
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.sendControl(["type": "ping", "ts": Int(Date().timeIntervalSince1970 * 1000)])
            }
        }
    }

    /// POST JSON to the pod (not the LiveChar server).
    private func pod(_ path: String, _ body: [String: Any], timeout: Double) async throws -> [String: Any] {
        guard let url = URL(string: podURL + path) else { throw APIError(message: "Bad GPU address", status: 0) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) {
            throw APIError(message: "GPU: " + ((obj["error"] as? String) ?? "HTTP \(code)"), status: code)
        }
        return obj
    }

    // MARK: control channel

    private func sendControl(_ m: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: m), let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let ch = channel
        if ch?.readyState != .open { if queued.count < 64 { queued.append(text) }; lock.unlock(); return }
        lock.unlock()
        ch?.sendData(LKRTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            lock.lock(); let q = queued; queued.removeAll(); lock.unlock()
            for t in q { dataChannel.sendData(LKRTCDataBuffer(data: Data(t.utf8), isBinary: false)) }
        case .closed:
            if !stopping { fail("GPU connection closed") }
        default: break
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard let m = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "configured", "reset_applied": events.state("live", true); events.note("")
        case "prompt_applied": events.note("Prompt applied")
        case "pong":
            if let ts = m["client_ts"] as? Double { rtt = Int(Date().timeIntervalSince1970 * 1000 - ts) }
        case "stats":
            var parts: [String] = []
            if let f = m["generation_fps"] as? Double { parts.append(String(format: "gen %.1f fps", f)) }
            if let rtt { parts.append("rtt \(rtt)ms") }
            if let p = m["profile"] as? String { parts.append(p.uppercased()) }
            if !parts.isEmpty { events.stats(parts.joined(separator: "  ·  ")) }
        case "error":
            let msg = m["error"] as? String ?? "error"
            events.note("GPU: \(msg)")
            if (m["retryable"] as? Bool) != true { fail("GPU: \(msg)") }
        case "stream_exhausted": fail("The stream ended. Press Go live to start again.")
        default: break
        }
    }

    func apply(prompt: String, image: Data?, imageChanged: Bool, enhance: Bool) async throws {
        let text = prompt.isEmpty ? (image != nil ? EdenEngine.swapPrompt : "") : prompt
        if imageChanged, let image, let buildLook {
            let look = try await buildLook(image)
            if look.hasPrefix("data:") {
                // fresh ticket, image over HTTP
                let t: Ticket = try await API.shared.post("/api/gpu/connect", ["id": sessionID])
                var body: [String: Any] = ["token": t.token, "image": look]
                if !text.isEmpty { body["prompt"] = text }
                _ = try await pod("/reset", body, timeout: 30)
            } else {
                var m: [String: Any] = ["type": "reset", "image_url": look]
                if !text.isEmpty { m["prompt"] = text }
                sendControl(m)
            }
        } else if !text.isEmpty {
            sendControl(["type": "prompt", "prompt": text])
        }
    }

    // MARK: video

    func pushCamera(_ pb: CVPixelBuffer) {
        guard let source, let capturer else { return }
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pb), rotation: LKRTCVideoRotation(rawValue: 0)!,
                                    timeStampNs: Int64(CACurrentMediaTime() * 1_000_000_000))
        source.capturer(capturer, didCapture: frame)
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let buffer = frame?.buffer else { return }
        if let cv = buffer as? LKRTCCVPixelBuffer { events.output(cv.pixelBuffer); return }
        let i420 = buffer.toI420()
        let w = Int(i420.width), h = Int(i420.height)
        guard let out = pool.buffer(w, h) else { return }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let dstY = CVPixelBufferGetBaseAddressOfPlane(out, 0), let dstUV = CVPixelBufferGetBaseAddressOfPlane(out, 1) else { return }
        LKRTCYUVHelper.i420(toNV12: i420.dataY, srcStrideY: i420.strideY, srcU: i420.dataU, srcStrideU: i420.strideU,
                            srcV: i420.dataV, srcStrideV: i420.strideV,
                            dstY: dstY.assumingMemoryBound(to: UInt8.self), dstStrideY: Int32(CVPixelBufferGetBytesPerRowOfPlane(out, 0)),
                            dstUV: dstUV.assumingMemoryBound(to: UInt8.self), dstStrideUV: Int32(CVPixelBufferGetBytesPerRowOfPlane(out, 1)),
                            width: i420.width, height: i420.height)
        events.output(out)
    }

    // MARK: stop

    private func fail(_ why: String) {
        lock.lock(); let first = !failed && !stopping; failed = true; lock.unlock()
        if first { events.ended(why) }
    }

    func stop() async {
        stopping = true
        pinger?.cancel()
        sendControl(["type": "stop"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        remoteTrack?.remove(self)
        channel?.close()
        pc?.close()
        pc = nil; channel = nil; capturer = nil; source = nil
        gather.finish(.success(()))
    }

    // MARK: peer connection delegate

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        if newState == .complete { gather.finish(.success(())) }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        lock.lock()
        if candidate.sdp.contains(" typ relay") { relays += 1 }
        let enough = relays > 0
        quietTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.gather.finish(.success(())) }
        quietTimer = item
        lock.unlock()
        if enough { DispatchQueue.global().asyncAfter(deadline: .now() + 0.75, execute: item) }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        if newState == .failed { fail("GPU: the video connection failed (network blocked?)") }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams mediaStreams: [LKRTCMediaStream]) {
        guard let track = rtpReceiver.track as? LKRTCVideoTrack else { return }
        remoteTrack = track
        track.add(self)
    }
}
