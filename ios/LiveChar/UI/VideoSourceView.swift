import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A movie file copied out of the Photos picker into a temp file we can play.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("livechar-src-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}

struct VideoSourceCard: View {
    @EnvironmentObject var live: LiveController
    @State private var pick: PhotosPickerItem?
    @State private var loading = false
    @State private var error = ""

    var body: some View {
        Card {
            Text("SOURCE").font(.caption.weight(.bold)).foregroundStyle(Theme.dim)
            Picker("Source", selection: Binding(get: { live.source }, set: { live.source = $0 })) {
                Text("Camera").tag(LiveController.Source.camera)
                Text("Video file").tag(LiveController.Source.videoFile)
            }
            .pickerStyle(.segmented)
            .disabled(live.running || live.starting)

            if live.source == .videoFile {
                PhotosPicker(selection: $pick, matching: .videos) {
                    HStack {
                        Image(systemName: loading ? "hourglass" : "film").foregroundStyle(Theme.char)
                        Text(live.videoName.isEmpty ? "Choose a video" : live.videoName).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.dim)
                    }
                    .padding(12)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
                }
                Text("Plays straight to your live cam, looped and filling the screen. No AI, no balance used.")
                    .font(.caption).foregroundStyle(Theme.dim)
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(Theme.bad) }
            }
        }
        .onChange(of: pick) { item in
            guard let item else { return }
            loading = true; error = ""
            Task {
                do {
                    if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                        live.setVideo(movie.url, name: "Video selected")
                    } else { error = "Couldn't load that video" }
                } catch { self.error = error.localizedDescription }
                loading = false; pick = nil
            }
        }
    }
}
