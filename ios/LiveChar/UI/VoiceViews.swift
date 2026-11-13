import AVFoundation
import SwiftUI

struct VoiceCard: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var live: LiveController
    @State private var picking = false

    private var available: Bool { app.config?.engines.voice ?? false }

    var body: some View {
        Card {
            Toggle(isOn: Binding(get: { live.voiceOn }, set: { on in Task { await live.setVoice(on: on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Change my voice").font(.subheadline.weight(.semibold))
                    Text(available ? "Natural voice (ElevenLabs). About 1–2 s behind you; recordings and the live link are lined up with the lips."
                                   : "Not set up yet — add an ElevenLabs key in the admin panel.")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
            }
            .tint(Theme.char)
            .disabled(!available)

            if live.voiceOn && available {
                Button { picking = true } label: {
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(Theme.char)
                        Text(live.voiceName.isEmpty ? "Pick a voice" : live.voiceName).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.dim)
                    }
                    .padding(12)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
                }
                Toggle("Hear the new voice (use headphones)", isOn: Binding(get: { live.voiceMonitor }, set: { live.setMonitor($0) }))
                    .font(.subheadline).tint(Theme.char)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Lip sync").font(.subheadline)
                        Spacer()
                        Text(String(format: "%+.2f s", live.avOffset)).font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim)
                    }
                    Slider(value: Binding(get: { live.avOffset }, set: { live.setAVOffset($0) }), in: -0.3...1.0, step: 0.05).tint(Theme.char)
                    Text("If the voice is early in your videos, move right; if it's late, move left.").font(.caption).foregroundStyle(Theme.dim)
                }
                if !live.voiceState.isEmpty && live.running {
                    Text("Voice: \(live.voiceState)").font(.caption).foregroundStyle(Theme.dim)
                }
            }
        }
        .sheet(isPresented: $picking) { VoicePicker().environmentObject(live) }
    }
}

struct VoicePicker: View {
    @EnvironmentObject var live: LiveController
    @Environment(\.dismiss) private var dismiss
    @State private var voices: [VoiceInfo] = []
    @State private var search = ""
    @State private var error = ""
    @State private var playing: String?
    @State private var player: AVPlayer?

    private var shown: [VoiceInfo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return voices }
        return voices.filter { ($0.name + " " + $0.detail).lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !error.isEmpty { Text(error).foregroundStyle(Theme.bad) }
                if voices.isEmpty && error.isEmpty { HStack { Spacer(); ProgressView(); Spacer() } }
                ForEach(shown) { v in
                    HStack(spacing: 12) {
                        Button { preview(v) } label: {
                            Image(systemName: playing == v.id ? "stop.circle.fill" : "play.circle.fill")
                                .font(.system(size: 30)).foregroundStyle(v.preview.isEmpty ? Theme.dim : Theme.char)
                        }
                        .buttonStyle(.plain)
                        .disabled(v.preview.isEmpty)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.name).font(.headline)
                            if !v.detail.isEmpty { Text(v.detail).font(.caption).foregroundStyle(Theme.dim).lineLimit(2) }
                        }
                        Spacer()
                        if v.id == live.voiceID { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        stopPreview()
                        Task { await live.chooseVoice(id: v.id, name: v.name) }
                        dismiss()
                    }
                }
            }
            .searchable(text: $search, prompt: "Search voices")
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { stopPreview(); dismiss() } } }
            .task { await load() }
            .onDisappear { stopPreview() }
        }
    }

    private func load() async {
        do { let r: VoicesResponse = try await API.shared.get("/api/voices"); voices = r.voices }
        catch { self.error = error.localizedDescription }
    }

    private func preview(_ v: VoiceInfo) {
        if playing == v.id { stopPreview(); return }
        guard let url = URL(string: v.preview) else { return }
        let p = AVPlayer(url: url)
        player = p; playing = v.id
        p.play()
    }

    private func stopPreview() { player?.pause(); player = nil; playing = nil }
}
