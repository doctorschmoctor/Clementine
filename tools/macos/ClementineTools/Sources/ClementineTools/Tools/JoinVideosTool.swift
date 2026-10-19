// Join videos: clips in the order you choose, combined into one MP4 the size of the first clip (others fit inside).

import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct JoinVideosTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var video = VideoModel()
    @State private var clips: [URL] = []
    @State private var selection: URL?

    var body: some View {
        ToolShell(saveTitle: "Join", canSave: clips.count >= 2, onSave: save) {
            VStack(spacing: 0) {
                if let error = video.error { Placeholder(text: error) } else { PlayerView(player: video.player) }
                TransportBar(model: video)
            }
        } controls: {
            ControlSection("Clips, in order") {
                List(selection: $selection) {
                    ForEach(Array(clips.enumerated()), id: \.element) { index, url in
                        HStack {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                            Text(url.lastPathComponent).lineLimit(1)
                            if index == 0 { Spacer(); Text("canvas").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(url)
                    }
                    .onMove { clips.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 240)
                HStack {
                    Button("Add…") { clips += FilePicker.pick(types: [.movie, .video, UTType(filenameExtension: "mkv") ?? .movie]) }
                    Button("Remove") { clips.removeAll { $0 == selection }; selection = nil }.disabled(selection == nil)
                }
                Text("The first clip sets the size and frame of the result. MP4, MOV and MKV clips can be mixed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if clips.isEmpty { clips = context.files; selection = clips.first } }
        .onChange(of: selection) { _, url in
            if let url { Task { await video.load(url) } }
        }
    }

    private func save() {
        video.pause()
        let clips = self.clips
        context.save { ctx in
            ctx.status = "Preparing clips…"
            var assets: [AVURLAsset] = []
            for url in clips { assets.append(try await Media.open(url)) }
            let first = try await Media.videoTrack(assets[0])
            let renderSize = try await Media.displaySize(first)
            let fps = max(1, try await first.load(.nominalFrameRate))

            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ToolError("The clips couldn't be combined.")
            }
            var instructions: [AVMutableVideoCompositionInstruction] = []
            var cursor = CMTime.zero
            for asset in assets {
                let duration = try await asset.load(.duration)
                let range = CMTimeRange(start: .zero, duration: duration)
                let source = try await Media.videoTrack(asset)
                try videoTrack.insertTimeRange(range, of: source, at: cursor)
                if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                    try audioTrack.insertTimeRange(range, of: audio, at: cursor)
                }
                // Fit the clip, as shown (rotation applied), centred in the canvas.
                let (natural, transform) = try await source.load(.naturalSize, .preferredTransform)
                let shown = CGRect(origin: .zero, size: natural).applying(transform)
                let scale = min(renderSize.width / abs(shown.width), renderSize.height / abs(shown.height))
                let fitted = CGSize(width: abs(shown.width) * scale, height: abs(shown.height) * scale)
                let place = transform
                    .concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: (renderSize.width - fitted.width) / 2, y: (renderSize.height - fitted.height) / 2))
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                layer.setTransform(place, at: cursor)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: cursor, duration: duration)
                instruction.layerInstructions = [layer]
                instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
                instructions.append(instruction)
                cursor = cursor + duration
            }
            if audioTrack.segments.isEmpty { composition.removeTrack(audioTrack) }
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = CGSize(width: Int(renderSize.width / 2) * 2, height: Int(renderSize.height / 2) * 2)
            videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            videoComposition.instructions = instructions

            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw ToolError("The clips can't be exported.")
            }
            session.videoComposition = videoComposition
            ctx.status = "Joining…"
            let out = Output.file(for: clips[0], suffix: "joined", ext: "mp4")
            try await Media.export(session, to: out, type: .mp4, context: ctx)
            return [out]
        }
    }
}
