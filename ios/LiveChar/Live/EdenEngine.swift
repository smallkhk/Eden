import CoreVideo
import Foundation
import LiveKitWebRTC
import QuartzCore

/// Eden Live on fal: one WebRTC peer connection negotiated through fal's WMA bridge (no trickle ICE),
/// a "control" data channel for prompt/image, and a heartbeat. Same protocol as @fal-ai/client's wma().
/// Every HTTP call goes through the LiveChar server's /api/fal/proxy, so the fal key never reaches the phone.
final class EdenEngine: NSObject, LiveEngine, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate, LKRTCVideoRenderer, @unchecked Sendable {
    static let swapPrompt = "The character from the reference image, same pose and framing as the camera, natural lighting, detailed, consistent identity."
    private static let wma = "https://wma.fal.run"

    private static let factory: LKRTCPeerConnectionFactory = {
        _ = LKRTCInitializeSSL()
        return LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
    }()

    private let events: EngineEvents
    private let endpoint: String
    private var pc: LKRTCPeerConnection?
    private var channel: LKRTCDataChannel?
    private var source: LKRTCVideoSource?
    private var capturer: LKRTCVideoCapturer?
    private var remoteTrack: LKRTCVideoTrack?
    private var sessionId = ""
    private var heartbeat: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var queued: [String] = []
    private var stopping = false
    private var failed = false
    private let lock = NSLock()
    private let pool = PixelPool()
    private let gather = Once<Void>()
    private var srflxOrRelay = 0
    private var quietTimer: DispatchWorkItem?
    var price: Double = 0

    init(endpoint: String, events: EngineEvents) {
        self.endpoint = endpoint
        self.events = events
    }

    // MARK: start

    func start(prompt: String, imageURL: String?, enhance: Bool) async throws {
        events.state("connecting…", false)
        let ice = await fetchIceServers()
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = ice
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
        _ = pc.addTransceiver(with: track, init: tinit)

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
        // no trickle ICE: wait for a usable, settled candidate set
        try? await gather.wait(timeout: 10, "ICE gathering timed out")
        guard let local = pc.localDescription else { throw APIError(message: "No local description", status: 0) }

        events.state("negotiating…", false)
        let answer = try await falJSON("/session", ["app_id": endpoint, "sdp": local.sdp, "type": "offer"], timeout: 60)
        guard let sdp = answer["sdp"] as? String else {
            throw APIError(message: "Eden: " + ((answer["error"] as? String) ?? (answer["detail"] as? String) ?? "no answer from the server"), status: 0)
        }
        sessionId = answer["session_id"] as? String ?? ""
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp)) { err in if let err { c.resume(throwing: err) } else { c.resume() } }
        }

        startHeartbeat()
        var cfg: [String: Any] = ["type": "configure", "enable_prompt_expansion": enhance]
        let text = prompt.isEmpty ? (imageURL != nil ? Self.swapPrompt : "") : prompt
        if !text.isEmpty { cfg["prompt"] = text }
        if let imageURL { cfg["image_url"] = imageURL }
        sendControl(cfg)
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.sendControl(["type": "ping", "ts": Int(Date().timeIntervalSince1970 * 1000)])
            }
        }
    }

    // MARK: fal bridge via the LiveChar proxy

    private func falJSON(_ path: String, _ body: [String: Any], timeout: Double = 15) async throws -> [String: Any] {
        var req = try API.shared.request("/api/fal/proxy", method: "POST", json: body)
        req.setValue(Self.wma + path, forHTTPHeaderField: "x-fal-target-url")
        req.timeoutInterval = timeout
        let (data, resp) = try await API.shared.session.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) {
            let msg = (obj["error"] as? String) ?? (obj["detail"] as? String) ?? (obj["message"] as? String) ?? "HTTP \(code)"
            throw APIError(message: "Eden: \(msg)", status: code)
        }
        return obj
    }

    private func fetchIceServers() async -> [LKRTCIceServer] {
        let fallback = [LKRTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        guard let obj = try? await falJSON("/ice", ["app_id": endpoint], timeout: 6),
              let list = obj["ice_servers"] as? [[String: Any]], !list.isEmpty else { return fallback }
        let servers = list.compactMap { s -> LKRTCIceServer? in
            let urls = (s["urls"] as? [String]) ?? ((s["urls"] as? String).map { [$0] }) ?? ((s["url"] as? String).map { [$0] }) ?? []
            guard !urls.isEmpty else { return nil }
            return LKRTCIceServer(urlStrings: urls, username: s["username"] as? String, credential: s["credential"] as? String)
        }
        return servers.isEmpty ? fallback : servers
    }

    private func startHeartbeat() {
        let id = sessionId
        guard !id.isEmpty else { return }
        heartbeat = Task { [weak self] in
            var strikes = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !self.stopping else { return }
                do { _ = try await self.falJSON("/session/heartbeat", ["session_id": id], timeout: 4); strikes = 0 }
                catch { strikes += 1; if strikes >= 3 { self.fail("Eden connection lost"); return } }
            }
        }
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
            if !stopping { fail("Eden control channel closed") }
        default: break
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard let m = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "configured", "reset_applied": events.state("live", true); events.note("")
        case "prompt_applied": events.note("Prompt applied")
        case "stats":
            var parts: [String] = []
            if let f = m["generation_fps"] as? Double { parts.append(String(format: "gen %.1f fps", f)) }
            if let l = m["latency_ms"] as? Double { parts.append("latency \(Int(l))ms") }
            if let u = m["billable_units"] as? Double, price > 0 { parts.append(String(format: "cost $%.3f", u * price)) }
            if !parts.isEmpty { events.stats(parts.joined(separator: "  ·  ")) }
        case "error":
            let msg = m["error"] as? String ?? "error"
            events.note("Eden: \(msg)")
            if (m["retryable"] as? Bool) != true { fail("Eden: \(msg)") }
        case "stream_exhausted": fail("The stream ended. Press Go live to start again.")
        default: break
        }
    }

    /// Builds the "target look" first frame for a character image (server: /api/first-frame) and returns its URL.
    var buildAnchor: ((Data) async throws -> String)?

    func apply(prompt: String, image: Data?, imageChanged: Bool, enhance: Bool) async throws {
        let text = prompt.isEmpty ? (image != nil ? Self.swapPrompt : "") : prompt
        if imageChanged, let image, let buildAnchor {
            // a new character needs a new anchor frame (short reset)
            let url = try await buildAnchor(image)
            var m: [String: Any] = ["type": "reset", "image_url": url]
            if !text.isEmpty { m["prompt"] = text }
            sendControl(m)
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
        heartbeat?.cancel(); pinger?.cancel()
        sendControl(["type": "stop"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        remoteTrack?.remove(self)
        channel?.close()
        pc?.close()
        pc = nil; channel = nil; capturer = nil; source = nil
        gather.finish(.success(()))
    }

    // MARK: peer connection delegate (same set as LiveKit's Transport)

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
        let sdp = candidate.sdp
        lock.lock()
        if sdp.contains(" typ srflx") || sdp.contains(" typ relay") { srflxOrRelay += 1 }
        let enough = srflxOrRelay > 0
        quietTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.gather.finish(.success(())) }
        quietTimer = item
        lock.unlock()
        if enough { DispatchQueue.global().asyncAfter(deadline: .now() + 1.25, execute: item) }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        if newState == .failed { fail("Eden: the video connection failed (network blocked?)") }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams mediaStreams: [LKRTCMediaStream]) {
        guard let track = rtpReceiver.track as? LKRTCVideoTrack else { return }
        remoteTrack = track
        track.add(self)
    }
}
