import CoreVideo
import Foundation
import LiveKit

/// What every engine reports back. All callbacks may arrive on any thread.
struct EngineEvents {
    var output: (CVPixelBuffer) -> Void = { _ in }
    var state: (String, Bool) -> Void = { _, _ in }       // text, isLive
    var note: (String) -> Void = { _ in }
    var stats: (String) -> Void = { _ in }
    var ended: (String) -> Void = { _ in }
}

protocol LiveEngine: AnyObject {
    func pushCamera(_ pb: CVPixelBuffer)
    /// Change the character while live. `image` nil = no image.
    func apply(prompt: String, image: Data?, imageChanged: Bool, enhance: Bool) async throws
    func stop() async
}

/// Remote video → our pipeline (LiveKit frames are NV12 CVPixelBuffers when hardware decoded).
final class FrameTap: NSObject, VideoRenderer, @unchecked Sendable {
    private let handler: (CVPixelBuffer) -> Void
    init(_ handler: @escaping (CVPixelBuffer) -> Void) { self.handler = handler }
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }
    func render(frame: VideoFrame) {
        if let b = frame.buffer as? CVPixelVideoBuffer { handler(b.pixelBuffer) }
        else if let b = frame.buffer as? I420VideoBuffer, let pb = b.toPixelBuffer() { handler(pb) }
    }
}

/// Decart Lucy: a control websocket (prompt, image, billing ticks), then a LiveKit room for the video.
/// Same protocol as @decartai/sdk 0.2.x.
final class LucyEngine: NSObject, LiveEngine, RoomDelegate, @unchecked Sendable {
    static let swapPrompt = "Substitute the character in the video with the person in the reference image."
    private static let inferencePrefix = "inference-server-"

    private let events: EngineEvents
    private var ws: URLSessionWebSocketTask?
    private var room: Room?
    private var capturer: BufferCapturer?
    private var tap: FrameTap!
    private var stopping = false
    private let lock = NSLock()
    private let roomWaiter = Once<(String, String)>()
    private var ackWaiter: (match: String, once: Once<[String: Any]>)?

    init(events: EngineEvents) {
        self.events = events
        super.init()
        tap = FrameTap { [weak self] pb in self?.events.output(pb) }
    }

    func start(token: String, model: String, fast: Bool, width: Int, height: Int,
               prompt: String, image: Data?, enhance: Bool) async throws {
        var c = URLComponents(string: "wss://api.decart.ai/v1/stream")!
        c.queryItems = [URLQueryItem(name: "api_key", value: token), URLQueryItem(name: "model", value: model),
                        URLQueryItem(name: "user_agent", value: "livechar-ios/1.0 lang/swift")]
        if fast { c.queryItems?.append(URLQueryItem(name: "speed", value: "fast")) }
        let task = URLSession.shared.webSocketTask(with: c.url!)
        task.maximumMessageSize = 16 << 20
        ws = task
        task.resume()
        receiveLoop(task)

        events.state("joining…", false)
        let text = prompt.isEmpty ? (image != nil ? Self.swapPrompt : "") : prompt
        let hasState = image != nil || !text.isEmpty
        try await send(["type": "livekit_join", "passthrough": !hasState])
        if let image {
            var m: [String: Any] = ["type": "set_image", "image_data": image.base64EncodedString(), "enhance_prompt": enhance]
            if !text.isEmpty { m["prompt"] = text }
            try await send(m)
        } else if !text.isEmpty {
            try await send(["type": "prompt", "prompt": text, "enhance_prompt": enhance])
        }

        let (url, roomToken) = try await roomWaiter.wait(timeout: 180, "Lucy did not answer")

        events.state("connecting video…", false)
        let room = Room(delegate: self)
        self.room = room
        try await room.connect(url: url, token: roomToken,
                               connectOptions: ConnectOptions(autoSubscribe: false),
                               roomOptions: RoomOptions(adaptiveStream: false, dynacast: false, suspendLocalVideoTracksInBackground: false))
        for p in room.remoteParticipants.values { subscribeIfInference(p) }

        let track = await LocalVideoTrack.createBufferTrack(name: "camera", source: .camera,
                                                            options: BufferCaptureOptions(dimensions: Dimensions(width: Int32(width), height: Int32(height)), fps: 30))
        capturer = track.capturer as? BufferCapturer
        _ = try await room.localParticipant.publish(videoTrack: track, options: VideoPublishOptions(
            name: "camera", encoding: VideoEncoding(maxBitrate: 3_500_000, maxFps: 30), simulcast: false, preferredCodec: .h264))
        events.state("connected", true)
    }

    func pushCamera(_ pb: CVPixelBuffer) { capturer?.capture(pb) }

    func apply(prompt: String, image: Data?, imageChanged: Bool, enhance: Bool) async throws {
        let text = prompt.isEmpty ? (image != nil ? Self.swapPrompt : "") : prompt
        // set_image replaces the whole state, so prompt + image always go together
        var m: [String: Any] = ["type": "set_image", "image_data": image.map { $0.base64EncodedString() } ?? NSNull(), "enhance_prompt": enhance]
        if !text.isEmpty { m["prompt"] = text }
        let ack = try await request(m, ack: "set_image_ack")
        if let ok = ack["success"] as? Bool, !ok { throw APIError(message: (ack["error"] as? String) ?? "Lucy refused the change", status: 0) }
    }

    func stop() async {
        stopping = true
        failWaiters(APIError(message: "Stopped", status: 0))
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        capturer = nil
        await room?.disconnect()
        room = nil
    }

    // MARK: control socket

    private func send(_ m: [String: Any]) async throws {
        guard let ws else { throw APIError(message: "Lucy connection closed", status: 0) }
        let data = try JSONSerialization.data(withJSONObject: m)
        try await ws.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func request(_ m: [String: Any], ack: String) async throws -> [String: Any] {
        let once = Once<[String: Any]>()
        setAck(ack, once)
        try await send(m)
        return try await once.wait(timeout: 30, "Lucy did not confirm the change")
    }

    private func setAck(_ match: String, _ once: Once<[String: Any]>) {
        lock.lock(); ackWaiter = (match, once); lock.unlock()
    }

    private func resolveAck(_ msg: [String: Any]?, _ error: Error?) {
        lock.lock(); let w = ackWaiter; ackWaiter = nil; lock.unlock()
        if let error { w?.once.finish(.failure(error)) } else { w?.once.finish(.success(msg ?? [:])) }
    }

    private func failWaiters(_ e: Error) {
        roomWaiter.finish(.failure(e))
        resolveAck(nil, e)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                var text: String?
                if case .string(let s) = msg { text = s } else if case .data(let d) = msg { text = String(data: d, encoding: .utf8) }
                if let text, let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { self.handle(obj) }
                self.receiveLoop(task)
            case .failure:
                guard !self.stopping else { return }
                let code = task.closeCode.rawValue
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let why: String
                if code == 1008 { why = "Lucy stopped the session (content policy)" }
                else if code == 1013 && reason.lowercased().contains("session limit") { why = "Lucy: too many sessions at once on this key" }
                else { why = reason.isEmpty ? "Lucy connection closed" : "Lucy: \(reason)" }
                self.failWaiters(APIError(message: why, status: 0))
                self.events.ended(why)
            }
        }
    }

    private func handle(_ m: [String: Any]) {
        let type = m["type"] as? String ?? ""
        lock.lock(); let ackMatch = ackWaiter?.match; lock.unlock()
        if type == ackMatch { resolveAck(m, nil); return }
        switch type {
        case "livekit_room_info":
            if let url = m["livekit_url"] as? String, let token = m["token"] as? String { roomWaiter.finish(.success((url, token))) }
            else { roomWaiter.finish(.failure(APIError(message: "Lucy sent a bad room", status: 0))) }
        case "queue_position":
            let pos = m["position"] as? Int ?? 0
            events.state(pos > 0 ? "in queue #\(pos)" : "in queue", false)
        case "generation_started":
            events.state("live", true)
        case "generation_tick":
            events.state("live", true)
            if let s = m["seconds"] as? Double { events.stats("billed \(Int(s))s") }
        case "generation_ended":
            let reason = m["reason"] as? String ?? ""
            if !stopping && !reason.isEmpty && reason != "client_disconnected" { events.ended("Lucy session ended (\(reason.replacingOccurrences(of: "_", with: " ")))") }
        case "error":
            let msg = m["error"] as? String ?? "error"
            if !roomWaiter.isDone {
                let busy = (m["error_type"] as? String) == "capacity"
                roomWaiter.finish(.failure(APIError(message: busy ? "Lucy is busy right now, try again in a minute" : "Lucy: \(msg)", status: 0)))
            } else {
                resolveAck(nil, APIError(message: "Lucy: \(msg)", status: 0))
                events.note("Lucy: \(msg)")
            }
        default: break
        }
    }

    // MARK: room

    private func subscribeIfInference(_ p: RemoteParticipant) {
        guard p.identity?.stringValue.hasPrefix(Self.inferencePrefix) == true else { return }
        for pub in p.trackPublications.values {
            if let rp = pub as? RemoteTrackPublication, rp.kind == .video { Task { try? await rp.set(subscribed: true) } }
        }
    }

    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        guard participant.identity?.stringValue.hasPrefix(Self.inferencePrefix) == true, publication.kind == .video else { return }
        Task { try? await publication.set(subscribed: true) }
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard participant.identity?.stringValue.hasPrefix(Self.inferencePrefix) == true,
              let track = publication.track as? RemoteVideoTrack else { return }
        track.add(videoRenderer: tap)
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        guard !stopping else { return }
        events.ended("Lucy video disconnected")
    }
}

/// A one-shot result to wait for, with a timeout. `finish` may come before `wait`; only the first result counts.
final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }

    func wait(timeout: Double, _ message: String) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            lock.lock()
            if let result { lock.unlock(); c.resume(with: result); return }
            cont = c
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { self.finish(.failure(APIError(message: message, status: 0))) }
        }
    }

    func finish(_ r: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let c = cont; cont = nil
        lock.unlock()
        c?.resume(with: r)
    }
}
