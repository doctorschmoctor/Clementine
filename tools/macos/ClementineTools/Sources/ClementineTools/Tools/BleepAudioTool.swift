// Bleep audio: replace sensitive parts of a recording with a tone; compare original and bleeped playback.

import SwiftUI

struct BleepAudioTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var playback = AudioPlayback()
    @State private var audio: AudioData?
    @State private var peaks: [Float] = []
    @State private var regions: [WaveRegion] = []
    @State private var selected: UUID?
    @State private var error: String?
    @State private var frequency = 1000.0
    @State private var volume = 50.0
    @State private var cursor = 0.0

    var body: some View {
        ToolShell(saveTitle: "Save", canSave: audio != nil && !regions.isEmpty, onSave: save) {
            VStack(spacing: 12) {
                if let error { Placeholder(text: error) }
                else if audio == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    WaveformView(peaks: peaks, duration: audio?.duration ?? 0, playhead: playback.isPlaying ? playback.position : cursor,
                                 regions: $regions, selected: $selected, onSeek: { cursor = $0 },
                                 onCreate: { range in
                                     let r = WaveRegion(range: range, color: .red)
                                     regions.append(r)
                                     selected = r.id
                                 })
                        .frame(maxHeight: .infinity)
                    HStack {
                        Button("Play original") { if let audio { playback.play(audio, from: start) } }
                        Button("Play bleeped") { if let b = bleeped() { playback.play(b, from: start) } }
                        Button("Stop") { playback.stop() }.disabled(!playback.isPlaying)
                        Spacer()
                        Text("Drag across the waveform to add a bleep; drag one to move it or its edges to adjust.").foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        } controls: {
            ControlSection("Bleeps") {
                Button("Add bleep at playhead (B)") {
                    let r = WaveRegion(range: cursor...min(audio?.duration ?? cursor, cursor + 0.5), color: .red)
                    regions.append(r); selected = r.id
                }.keyboardShortcut("b", modifiers: [])
                ForEach($regions) { $region in
                    HStack {
                        Button("\(Timecode.format(region.range.lowerBound)) – \(Timecode.format(region.range.upperBound))") {
                            selected = region.id; cursor = region.range.lowerBound
                        }
                        .buttonStyle(.link)
                        .fontWeight(selected == region.id ? .bold : .regular)
                        Spacer()
                        Button { regions.removeAll { $0.id == region.id } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    }
                }
                if let i = regions.firstIndex(where: { $0.id == selected }) {
                    TimecodeField(title: "From", seconds: Binding(get: { regions[i].range.lowerBound }, set: { v in
                        regions[i].range = min(v, regions[i].range.upperBound - 0.01)...regions[i].range.upperBound }), maximum: audio?.duration ?? 0)
                    TimecodeField(title: "To", seconds: Binding(get: { regions[i].range.upperBound }, set: { v in
                        regions[i].range = regions[i].range.lowerBound...max(v, regions[i].range.lowerBound + 0.01) }), maximum: audio?.duration ?? 0)
                }
            }
            ControlSection("Tone") {
                LabeledSlider(title: "Pitch", value: $frequency, range: 300...3000, step: 50) { "\(Int($0)) Hz" }
                LabeledSlider(title: "Volume", value: $volume, range: 5...100, step: 1) { "\(Int($0))%" }
            }
        }
        .task {
            do {
                let data = try await AudioData.load(context.file)
                audio = data
                peaks = data.peaks(1600)
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { playback.stop() }
    }

    /// Plays from a second before the selected bleep (or the cursor).
    private var start: Double {
        let t = regions.first(where: { $0.id == selected })?.range.lowerBound ?? cursor
        return max(0, t - 1)
    }

    private func bleeped() -> AudioData? {
        guard var out = audio else { return nil }
        let fs = out.sampleRate
        let amp = Float(volume / 100) * 0.8
        let fade = Int(0.005 * fs)
        for region in regions {
            let a = out.frame(at: region.range.lowerBound), b = out.frame(at: region.range.upperBound)
            guard b > a else { continue }
            for c in 0..<out.channels.count {
                for i in a..<b {
                    // Short fades at both ends so the cut doesn't click.
                    let edge = min(i - a, b - 1 - i)
                    let w = edge < fade ? Float(edge) / Float(fade) : 1
                    let tone = amp * Float(sin(2 * Double.pi * frequency * Double(i - a) / fs))
                    out.channels[c][i] = tone * w + out.channels[c][i] * (1 - w)
                }
            }
        }
        return out
    }

    private func save() {
        playback.stop()
        guard let data = bleeped() else { return }
        let source = context.file
        context.save { _ in [try data.save(from: source, suffix: "bleeped")] }
    }
}
