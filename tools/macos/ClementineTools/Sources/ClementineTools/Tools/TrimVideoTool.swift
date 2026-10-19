// Trim video: keep one exact section, set frame by frame or by timecode, saved without re-encoding.

import AVFoundation
import SwiftUI

struct TrimVideoTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var video = VideoModel()
    @State private var start = 0.0
    @State private var end = 0.0

    var body: some View {
        ToolShell(saveTitle: "Trim", canSave: video.asset != nil && end - start > 0.05, onSave: save) {
            VStack(spacing: 0) {
                if let error = video.error { Placeholder(text: error) } else { PlayerView(player: video.player) }
                TransportBar(model: video, marks: end > start ? [start...end] : [])
            }
        } controls: {
            ControlSection("Keep") {
                TimecodeField(title: "Start", seconds: $start, maximum: video.duration)
                TimecodeField(title: "End", seconds: $end, maximum: video.duration)
                HStack {
                    Button("Start at playhead (I)") { start = min(video.current, end) }.keyboardShortcut("i", modifiers: [])
                    Button("End at playhead (O)") { end = max(video.current, start) }.keyboardShortcut("o", modifiers: [])
                }
                HStack {
                    Button("Go to start") { video.seek(start) }
                    Button("Go to end") { video.seek(end) }
                    Button("Play section") { playSection() }
                }
                Text("Length \(Timecode.format(max(0, end - start)))").foregroundStyle(.secondary)
            }
            Text("Step frame by frame with ← and →. The video is copied as it is, so quality doesn't change.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            await video.load(context.file)
            end = video.duration
        }
    }

    private func playSection() {
        video.seek(start)
        video.player.play()
        let stop = end
        Task {
            while video.player.rate != 0 && video.current < stop { try? await Task.sleep(for: .milliseconds(30)) }
            video.pause()
        }
    }

    private func save() {
        guard let asset = video.asset else { return }
        video.pause()
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let source = context.file
        context.save { ctx in
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw ToolError("This video can't be trimmed.")
            }
            session.timeRange = range
            let (type, ext) = Media.videoType(for: source)
            let out = Output.file(for: source, suffix: "trimmed", ext: ext)
            try await Media.export(session, to: out, type: type, context: ctx)
            return [out]
        }
    }
}
