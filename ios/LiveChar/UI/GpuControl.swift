import SwiftUI
import UserNotifications

/// Admin-only: start/stop your RunPod GPU from the phone, see its status and cost,
/// and get a notification when Eden is ready.
struct GpuStatus: Decodable {
    let state: String          // off | starting | ready
    let stage: String?
    let ready: Bool?
    let busy: Bool?
    let cost: Double?
    let uptime: Double?
    let profile: String?
    let error: String?
    let hasKey: Bool?
    let gpuType: String?
}

struct GpuControlCard: View {
    @EnvironmentObject var app: AppModel
    @State private var gpu: GpuStatus?
    @State private var working = false
    @State private var message = ""

    var body: some View {
        Card {
            HStack {
                Text("MY GPU").font(.caption.weight(.bold)).foregroundStyle(Theme.dim)
                Spacer()
                Text(label).font(.footnote.weight(.bold)).foregroundStyle(color)
            }
            if let g = gpu {
                Text(detail(g)).font(.footnote).foregroundStyle(Theme.dim)
            }
            HStack(spacing: 10) {
                if gpu?.state == "off" || gpu == nil {
                    Button { Task { await act("start") } } label: { Label("Start GPU", systemImage: "bolt.fill") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.ok))
                        .disabled(working || gpu?.hasKey == false)
                } else {
                    Button { Task { await act("stop") } } label: { Label("Stop GPU", systemImage: "stop.fill") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.bad))
                        .disabled(working)
                }
                Spacer()
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Theme.text.opacity(0.85)) }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: (gpu?.state == "starting" ? 5 : 15) * 1_000_000_000)
            }
        }
    }

    private var label: String {
        switch gpu?.state {
        case "ready": return gpu?.busy == true ? "Ready · in use" : "Ready"
        case "starting": return "Starting…"
        case "off": return "Off"
        default: return "…"
        }
    }

    private var color: Color {
        switch gpu?.state {
        case "ready": return Theme.ok
        case "starting": return Theme.gold
        default: return Theme.dim
        }
    }

    private func detail(_ g: GpuStatus) -> String {
        if let e = g.error, !e.isEmpty { return "Error: \(e)" }
        if g.hasKey == false { return "Add your RunPod key in Admin on the website" }
        var parts: [String] = []
        if g.state == "off" { parts.append("\(g.gpuType ?? "Cheap GPU") · billed per second only while on") }
        else if let t = g.gpuType, !t.isEmpty { parts.append(t) }
        if let s = g.stage, !s.isEmpty, g.state != "off" { parts.append(s) }
        if let c = g.cost, g.state != "off" {
            let up = g.uptime ?? 0
            parts.append(String(format: "$%.2f/hr · $%.2f so far", c, c * up / 3600))
        }
        if let p = g.profile, g.state == "ready" { parts.append(p.uppercased()) }
        return parts.joined(separator: " · ")
    }

    private func refresh() async {
        guard let g: GpuStatus = try? await API.shared.get("/api/admin/gpu") else { return }
        let was = gpu?.state
        gpu = g
        if was != nil, was != g.state { await app.refreshUser() }     // updates "My GPU" engine on/off
        if was == "starting", g.state == "ready" { notifyReady() }
    }

    private func act(_ what: String) async {
        working = true
        defer { working = false }
        if what == "start" {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        do {
            gpu = try await API.shared.post("/api/admin/gpu/\(what)", [:])
            message = what == "start" ? "Starting — about 3–8 minutes. You'll get a notification when it's ready." : "GPU stopped — billing stopped."
            await app.refreshUser()
        } catch {
            message = error.localizedDescription
        }
    }

    private func notifyReady() {
        message = "GPU is ready — press Go live."
        let c = UNMutableNotificationContent()
        c.title = "Your GPU is ready"
        c.body = "Eden 5B is live. Open LiveChar and press Go live."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lc-gpu-ready", content: c, trigger: nil))
    }
}
