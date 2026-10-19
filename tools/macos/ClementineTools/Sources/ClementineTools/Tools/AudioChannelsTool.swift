// Convert audio channels: mono or stereo, with the left and right volume set separately and each previewed alone.

import SwiftUI

struct AudioChannelsTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var playback = AudioPlayback()
    @State private var audio: AudioData?
    @State private var error: String?
    @State private var stereo = false
    @State private var left = 100.0
    @State private var right = 100.0
    @State private var peaks: [Float] = []
    @State private var regions: [WaveRegion] = []
    @State private var selected: UUID?

    var body: some View {
        ToolShell(saveTitle: "Save", canSave: audio != nil, onSave: save) {
            VStack(spacing: 12) {
                if let error { Placeholder(text: error) }
                else if audio == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    WaveformView(peaks: peaks, duration: audio?.duration ?? 0, playhead: playback.isPlaying ? playback.position : nil,
                                 regions: $regions, selected: $selected)
                        .frame(maxHeight: .infinity).padding()
                    HStack {
                        Button("Play both") { preview(.both) }
                        Button("Left only") { preview(.left) }
                        Button("Right only") { preview(.right) }
                        Button("Stop") { playback.stop() }.disabled(!playback.isPlaying)
                    }
                    .padding(.bottom, 12)
                }
            }
        } controls: {
            ControlSection("Output") {
                Picker("", selection: $stereo) { Text("Mono").tag(false); Text("Stereo").tag(true) }
                    .pickerStyle(.segmented).labelsHidden()
                if let audio { Text("The file has \(audio.channels.count == 1 ? "one channel (mono)" : "\(audio.channels.count) channels").")
                    .font(.caption).foregroundStyle(.secondary) }
            }
            ControlSection("Volume") {
                LabeledSlider(title: "Left", value: $left, range: 0...200, step: 1) { "\(Int($0))%" }
                LabeledSlider(title: "Right", value: $right, range: 0...200, step: 1) { "\(Int($0))%" }
                Button("Reset") { left = 100; right = 100 }
            }
        }
        .task {
            do {
                let data = try await AudioData.load(context.file)
                audio = data
                stereo = data.channels.count == 1
                peaks = data.peaks(1200)
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { playback.stop() }
    }

    enum Solo { case both, left, right }

    private func processed(_ solo: Solo = .both) -> AudioData? {
        guard let audio else { return nil }
        let l = audio.channels[0]
        let r = audio.channels.count > 1 ? audio.channels[1] : l
        let gl = Float(left / 100) * (solo == .right ? 0 : 1)
        let gr = Float(right / 100) * (solo == .left ? 0 : 1)
        if stereo {
            return AudioData(sampleRate: audio.sampleRate, channels: [l.map { $0 * gl }, r.map { $0 * gr }])
        }
        let n = l.count
        var mono = [Float](repeating: 0, count: n)
        let both = audio.channels.count > 1
        for i in 0..<n { mono[i] = both ? (l[i] * gl + r[i] * gr) / 2 : l[i] * gl }
        if solo != .both {
            // Hear what one side contributes to the mono mix.
            return AudioData(sampleRate: audio.sampleRate, channels: [mono])
        }
        return AudioData(sampleRate: audio.sampleRate, channels: [mono])
    }

    private func preview(_ solo: Solo) {
        if let data = processed(solo) { playback.play(data) }
    }

    private func save() {
        playback.stop()
        guard let data = processed() else { return }
        let source = context.file, suffix = stereo ? "stereo" : "mono"
        context.save { _ in [try data.save(from: source, suffix: suffix)] }
    }
}
