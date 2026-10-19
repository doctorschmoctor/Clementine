// Normalize volume: a recording at a steady, standard loudness, with its range and true peak under control.

import SwiftUI

struct NormalizeAudioTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var playback = AudioPlayback()
    @State private var audio: AudioData?
    @State private var input: LoudnessStats?
    @State private var output: LoudnessStats?
    @State private var processed: AudioData?
    @State private var settings = Loudness.Settings()
    @State private var error: String?
    @State private var peaksIn: [Float] = []
    @State private var peaksOut: [Float] = []
    @State private var regions: [WaveRegion] = []
    @State private var selected: UUID?
    @State private var job: Task<Void, Never>?

    private let presets: [(String, Double)] = [("Streaming", -14), ("Podcast", -16), ("Broadcast", -23)]

    var body: some View {
        ToolShell(saveTitle: "Save", canSave: processed != nil, onSave: save) {
            VStack(alignment: .leading, spacing: 8) {
                if let error { Placeholder(text: error) }
                else if audio == nil { ProgressView("Measuring…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    Text("Before").font(.caption).foregroundStyle(.secondary)
                    WaveformView(peaks: peaksIn, duration: audio?.duration ?? 0, regions: $regions, selected: $selected)
                    Text("After").font(.caption).foregroundStyle(.secondary)
                    WaveformView(peaks: peaksOut, duration: audio?.duration ?? 0,
                                 playhead: playback.isPlaying ? playback.position : nil, regions: $regions, selected: $selected)
                    HStack {
                        Button("Play before") { if let audio { playback.play(audio) } }
                        Button("Play after") { if let processed { playback.play(processed) } }.disabled(processed == nil)
                        Button("Stop") { playback.stop() }.disabled(!playback.isPlaying)
                    }
                }
            }
            .padding()
        } controls: {
            ControlSection("Target loudness") {
                HStack { ForEach(presets, id: \.0) { p in Button(p.0) { settings.target = p.1 }.buttonStyle(.bordered) } }
                LabeledSlider(title: "Loudness", value: $settings.target, range: -30...(-5), step: 0.5) { String(format: "%.1f LUFS", $0) }
            }
            ControlSection("Loudness range") {
                Toggle("Limit the range", isOn: $settings.limitRange)
                if settings.limitRange {
                    LabeledSlider(title: "At most", value: $settings.maxRange, range: 3...20, step: 0.5) { String(format: "%.1f LU", $0) }
                }
                Text("Evens out quiet and loud passages so everything is easy to hear.").font(.caption).foregroundStyle(.secondary)
            }
            ControlSection("True peak") {
                LabeledSlider(title: "Ceiling", value: $settings.ceiling, range: -6...0, step: 0.1) { String(format: "%.1f dBTP", $0) }
            }
            ControlSection("Levels") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text(""); Text("Input").foregroundStyle(.secondary); Text("Output").foregroundStyle(.secondary) }
                    GridRow { Text("Loudness"); Text(stat(input?.integrated, "LUFS")); Text(stat(output?.integrated, "LUFS")) }
                    GridRow { Text("Range"); Text(stat(input?.range, "LU")); Text(stat(output?.range, "LU")) }
                    GridRow { Text("True peak"); Text(stat(input?.truePeak, "dBTP")); Text(stat(output?.truePeak, "dBTP")) }
                }
                .monospacedDigit()
                if processed == nil && audio != nil { ProgressView().controlSize(.small) }
            }
        }
        .task {
            do {
                let data = try await AudioData.load(context.file)
                let stats = await Task.detached { Loudness.measure(data) }.value
                audio = data
                input = stats
                peaksIn = data.peaks(1200)
                recompute()
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: settings) { _, _ in recompute() }
        .onDisappear { playback.stop() }
    }

    private func stat(_ v: Double?, _ unit: String) -> String { v.map { LoudnessStats.format($0, unit) } ?? "–" }

    private func recompute() {
        guard let audio, let input else { return }
        job?.cancel()
        processed = nil
        output = nil
        var settings = self.settings
        // AAC raises peaks a little when it encodes: keep more room under the ceiling for M4A.
        if Media.audioType(for: context.file).0 == .m4a { settings.ceiling -= 0.8 }
        job = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            let (data, stats) = await Task.detached { () -> (AudioData, LoudnessStats) in
                Loudness.normalize(audio, settings: settings, input: input)
            }.value
            if Task.isCancelled { return }
            processed = data
            output = stats
            peaksOut = data.peaks(1200)
        }
    }

    private func save() {
        playback.stop()
        guard let processed else { return }
        let source = context.file
        context.save { _ in [try processed.save(from: source, suffix: "normalized")] }
    }
}
