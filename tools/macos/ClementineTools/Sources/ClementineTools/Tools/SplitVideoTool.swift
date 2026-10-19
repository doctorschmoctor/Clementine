// Split video: separate clips at points you set (or into equal parts), all saved in one folder.

import AVFoundation
import SwiftUI

struct SplitVideoTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var video = VideoModel()
    @State private var equal = false
    @State private var parts = 2
    @State private var points: [Double] = []

    private var cuts: [Double] {
        if equal { return (1..<max(parts, 2)).map { Double($0) * video.duration / Double(max(parts, 2)) } }
        return points.filter { $0 > 0.05 && $0 < video.duration - 0.05 }.sorted()
    }

    var body: some View {
        ToolShell(saveTitle: "Split", canSave: video.asset != nil && !cuts.isEmpty, onSave: save) {
            VStack(spacing: 0) {
                if let error = video.error { Placeholder(text: error) } else { PlayerView(player: video.player) }
                TransportBar(model: video, points: cuts)
            }
        } controls: {
            ControlSection("Split") {
                Picker("", selection: $equal) { Text("At points").tag(false); Text("Equal parts").tag(true) }
                    .pickerStyle(.segmented).labelsHidden()
                if equal {
                    Stepper("Parts: \(parts)", value: $parts, in: 2...100)
                    if video.duration > 0 { Text("Each about \(Timecode.format(video.duration / Double(parts)))").foregroundStyle(.secondary) }
                } else {
                    Button("Split at playhead (S)") { addPoint() }.keyboardShortcut("s", modifiers: [])
                    ForEach(Array(points.sorted().enumerated()), id: \.offset) { _, p in
                        HStack {
                            Button(Timecode.format(p)) { video.seek(p) }.buttonStyle(.link)
                            Spacer()
                            Button { points.removeAll { $0 == p } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                        }
                    }
                    if points.isEmpty { Text("Move to a frame and add a split point.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text("\(cuts.count + 1) clips will be saved in one folder.").foregroundStyle(.secondary)
        }
        .task { await video.load(context.file) }
    }

    private func addPoint() {
        let t = video.current
        if !points.contains(where: { abs($0 - t) < 0.01 }) { points.append(t) }
    }

    private func save() {
        guard let asset = video.asset else { return }
        video.pause()
        let source = context.file
        let bounds = [0] + cuts + [video.duration]
        context.save { ctx in
            let folder = try Output.folder(for: source, suffix: "parts")
            let (type, ext) = Media.videoType(for: source)
            let stem = source.deletingPathExtension().lastPathComponent
            var outputs: [URL] = []
            for i in 0..<(bounds.count - 1) {
                ctx.status = "Saving clip \(i + 1) of \(bounds.count - 1)…"
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                    throw ToolError("This video can't be split.")
                }
                session.timeRange = CMTimeRange(start: CMTime(seconds: bounds[i], preferredTimescale: 600),
                                                end: CMTime(seconds: bounds[i + 1], preferredTimescale: 600))
                let out = folder.appendingPathComponent(String(format: "%@ %02d", stem, i + 1)).appendingPathExtension(ext)
                try await Media.export(session, to: out, type: type, context: ctx)
                outputs.append(out)
            }
            return [folder]
        }
    }
}
