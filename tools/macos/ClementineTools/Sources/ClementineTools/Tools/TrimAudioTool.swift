// Trim audio: keep one section, set on the waveform or by time; silence can be cut from the start and end only.

import SwiftUI

struct TrimAudioTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var playback = AudioPlayback()
    @State private var audio: AudioData?
    @State private var peaks: [Float] = []
    @State private var regions: [WaveRegion] = []
    @State private var selected: UUID?
    @State private var error: String?
    @State private var threshold = -45.0

    private var range: ClosedRange<Double> { regions.first?.range ?? 0...0 }

    private func edge(_ upper: Bool) -> Binding<Double> {
        Binding(get: { upper ? range.upperBound : range.lowerBound }, set: { v in
            guard !regions.isEmpty else { return }
            regions[0].range = upper ? range.lowerBound...max(v, range.lowerBound + 0.01) : min(v, range.upperBound - 0.01)...range.upperBound
        })
    }

    var body: some View {
        ToolShell(saveTitle: "Trim", canSave: audio != nil && range.upperBound - range.lowerBound > 0.01, onSave: save) {
            VStack(spacing: 12) {
                if let error { Placeholder(text: error) }
                else if audio == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    WaveformView(peaks: peaks, duration: audio?.duration ?? 0, playhead: playback.isPlaying ? playback.position : nil,
                                 regions: $regions, selected: $selected, onSeek: { t in if let audio { playback.play(audio, from: t) } },
                                 dimOutside: true)
                        .frame(maxHeight: .infinity)
                    HStack {
                        Button("Play section") { if let audio { playback.play(audio, from: range.lowerBound, to: range.upperBound) } }
                        Button("Stop") { playback.stop() }.disabled(!playback.isPlaying)
                        Spacer()
                        Text("Drag the edges of the highlighted part. Click to listen from there.").foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        } controls: {
            ControlSection("Keep") {
                TimecodeField(title: "Start", seconds: edge(false), maximum: audio?.duration ?? 0)
                TimecodeField(title: "End", seconds: edge(true), maximum: audio?.duration ?? 0)
                Text("Length \(Timecode.format(range.upperBound - range.lowerBound))").foregroundStyle(.secondary)
            }
            ControlSection("Silence") {
                Button("Remove silence at start and end") { trimSilence() }
                LabeledSlider(title: "Silent below", value: $threshold, range: -70...(-20), step: 1) { "\(Int($0)) dB" }
                Text("Only the beginning and the end are trimmed; pauses inside stay.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            do {
                let data = try await AudioData.load(context.file)
                audio = data
                peaks = data.peaks(1600)
                regions = [WaveRegion(range: 0...data.duration)]
                selected = regions[0].id
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { playback.stop() }
    }

    private func trimSilence() {
        guard let audio, !regions.isEmpty else { return }
        let limit = Float(pow(10, threshold / 20))
        let n = audio.frameCount
        func loud(_ i: Int) -> Bool { audio.channels.contains { abs($0[i]) > limit } }
        var first = 0
        while first < n && !loud(first) { first += 1 }
        var last = n - 1
        while last > first && !loud(last) { last -= 1 }
        guard first < last else { return }
        let pad = 0.05
        regions[0].range = max(0, Double(first) / audio.sampleRate - pad)...min(audio.duration, Double(last) / audio.sampleRate + pad)
    }

    private func save() {
        playback.stop()
        guard let audio else { return }
        let part = audio.slice(range.lowerBound, range.upperBound), source = context.file
        context.save { _ in [try part.save(from: source, suffix: "trimmed")] }
    }
}
