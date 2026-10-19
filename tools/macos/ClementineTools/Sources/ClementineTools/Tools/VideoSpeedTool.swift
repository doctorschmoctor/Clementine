// Change video speed: a slower or faster copy, keeping the pitch of the sound if you like.

import AVFoundation
import SwiftUI

struct VideoSpeedTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var video = VideoModel()
    @State private var speed = 2.0
    @State private var preservePitch = true

    private let presets: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]

    var body: some View {
        ToolShell(saveTitle: "Save", canSave: video.asset != nil && speed != 1, onSave: save) {
            VStack(spacing: 0) {
                if let error = video.error { Placeholder(text: error) } else { PlayerView(player: video.player) }
                TransportBar(model: video)
            }
        } controls: {
            ControlSection("Speed") {
                LabeledSlider(title: "Speed", value: $speed, range: 0.1...8, step: 0.05) { String(format: "%.2g×", $0) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                    ForEach(presets, id: \.self) { p in
                        Button(String(format: "%g×", p)) { speed = p }.buttonStyle(.bordered)
                    }
                }
            }
            ControlSection("Sound") {
                Toggle("Keep the pitch", isOn: $preservePitch)
                Text("Videos without sound work too.").font(.caption).foregroundStyle(.secondary)
            }
            if video.duration > 0 {
                Text("New length: \(Timecode.format(video.duration / speed))").foregroundStyle(.secondary)
            }
        }
        .task { await video.load(context.file); applyPreview() }
        .onChange(of: speed) { _, _ in applyPreview() }
        .onChange(of: preservePitch) { _, _ in applyPreview() }
    }

    private func applyPreview() {
        video.player.currentItem?.audioTimePitchAlgorithm = preservePitch ? .spectral : .varispeed
        if video.player.rate != 0 { video.player.rate = Float(speed) }
        video.player.defaultRate = Float(speed)
    }

    private func save() {
        guard let asset = video.asset else { return }
        video.pause()
        let speed = self.speed, pitch = preservePitch, source = context.file
        context.save { ctx in
            let composition = AVMutableComposition()
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            for track in try await asset.loadTracks(withMediaType: .video) {
                let t = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                try t?.insertTimeRange(range, of: track, at: .zero)
                t?.preferredTransform = try await track.load(.preferredTransform)
            }
            for track in try await asset.loadTracks(withMediaType: .audio) {
                let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try t?.insertTimeRange(range, of: track, at: .zero)
            }
            composition.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / speed))
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw ToolError("This video can't be exported.")
            }
            session.audioTimePitchAlgorithm = pitch ? .spectral : .varispeed
            let (type, ext) = Media.videoType(for: source)
            let out = Output.file(for: source, suffix: String(format: "%gx", speed), ext: ext)
            try await Media.export(session, to: out, type: type, context: ctx)
            return [out]
        }
    }
}
