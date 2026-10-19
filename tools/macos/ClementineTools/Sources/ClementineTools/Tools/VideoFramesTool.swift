// Save video frames: pick exact frames, one step at a time, and export them as full-resolution PNGs.

import AVFoundation
import SwiftUI

struct VideoFramesTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var video = VideoModel()
    @State private var picked: [Double] = []
    @State private var thumbs: [Double: CGImage] = [:]

    var body: some View {
        ToolShell(saveTitle: picked.count > 1 ? "Save \(picked.count) frames" : "Save frame", canSave: video.asset != nil, onSave: save) {
            VStack(spacing: 0) {
                if let error = video.error { Placeholder(text: error) } else { PlayerView(player: video.player) }
                TransportBar(model: video, points: picked)
            }
        } controls: {
            ControlSection("Frames") {
                Button("Add this frame (F)") { add() }.keyboardShortcut("f", modifiers: [])
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                        ForEach(picked, id: \.self) { t in
                            VStack(spacing: 2) {
                                if let image = thumbs[t] {
                                    Image(decorative: image, scale: 1).resizable().scaledToFit().frame(height: 70)
                                } else { Rectangle().fill(.quaternary).frame(height: 70) }
                                HStack {
                                    Button(Timecode.format(t)) { video.seek(t) }.buttonStyle(.link).font(.caption)
                                    Button { picked.removeAll { $0 == t } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 200)
                Text(picked.isEmpty ? "With no frames added, the frame on screen is saved." : "Saved as PNG at the video's full size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await video.load(context.file) }
    }

    private func add() {
        let t = video.current
        guard !picked.contains(where: { abs($0 - t) < video.frameDuration / 2 }), let asset = video.asset else { return }
        picked.append(t)
        picked.sort()
        Task { thumbs[t] = try? await Frames.image(asset, at: t, maxPixels: 300) }
    }

    private func save() {
        guard let asset = video.asset else { return }
        video.pause()
        let times = picked.isEmpty ? [video.current] : picked
        let source = context.file
        context.save { ctx in
            let stem = source.deletingPathExtension().lastPathComponent
            let folder = times.count > 1 ? try Output.folder(for: source, suffix: "frames") : nil
            var outputs: [URL] = []
            for (i, t) in times.enumerated() {
                ctx.progress = Double(i) / Double(times.count)
                let image = try await Frames.image(asset, at: t)
                let name = "\(stem) \(Timecode.format(t).replacingOccurrences(of: ":", with: "-"))"
                let url = folder.map { Output.unique($0, name, "png") } ?? Output.file(for: source, suffix: "frame", ext: "png")
                try Images.write(image, to: url, type: .png)
                outputs.append(url)
            }
            return folder.map { [$0] } ?? outputs
        }
    }
}
