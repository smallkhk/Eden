import Foundation
import Network

/// Same-phone feed for the LiveChar camera hook (dylib): serves the encoded output on
/// http://127.0.0.1:8765/api/share/<anything>/stream in the same framing as the server's live link
/// ([u32 length][flags][u64 µs timestamp][H.264 Annex B]). Loopback only — nothing leaves the phone,
/// so the hooked app gets every frame right away, in order, with no internet in between.
/// Keeps running while LiveChar runs (in the background that means PiP on, so iOS keeps the app alive).
final class LocalFeed {
    static let shared = LocalFeed()
    static let port: UInt16 = 8765

    private let queue = DispatchQueue(label: "livechar.localfeed", qos: .userInitiated)
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var gop: [Data] = []          // since the last keyframe, so a new viewer starts clean
    private var gopBytes = 0

    private final class Client {
        let conn: NWConnection
        var ready = false
        var backlog = 0                   // bytes sent but not yet taken by the socket
        init(_ c: NWConnection) { conn = c }
    }

    func start() {
        queue.async {
            guard self.listener == nil else { return }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            guard let l = try? NWListener(using: params) else { return }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed = st { self?.queue.async { self?.listener?.cancel(); self?.listener = nil } }
            }
            l.start(queue: self.queue)
            self.listener = l
        }
    }

    private func accept(_ c: NWConnection) {
        let client = Client(c)
        let id = ObjectIdentifier(client)
        clients[id] = client
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.queue.async { self?.clients[id] = nil }
            default: break
            }
        }
        c.start(queue: queue)
        // read the request line, answer with a plain streaming response, then send the current GOP
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, _, err in
            guard let self, err == nil else { c.cancel(); return }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            client.ready = true
            for p in self.gop { self.write(p, to: client) }
        }
    }

    private func write(_ packet: Data, to c: Client) {
        if c.backlog > 3_000_000 { c.conn.cancel(); return }   // reader stuck: drop it, it reconnects
        c.backlog += packet.count
        c.conn.send(content: packet, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { c.backlog -= packet.count }
        })
    }

    /// One framed packet (length prefix included). Called from the encoder queue.
    func send(_ packet: Data, isKey: Bool) {
        queue.async {
            if isKey { self.gop.removeAll(); self.gopBytes = 0 }
            if self.gopBytes + packet.count <= 6_000_000 { self.gop.append(packet); self.gopBytes += packet.count }
            for c in self.clients.values where c.ready { self.write(packet, to: c) }
        }
    }

    /// Stream ended (session stopped): tell viewers, forget the GOP.
    func ended() {
        queue.async {
            var p = Data(count: 13)
            p[3] = 9; p[4] = 2
            self.gop.removeAll(); self.gopBytes = 0
            for c in self.clients.values where c.ready { self.write(p, to: c) }
        }
    }
}
