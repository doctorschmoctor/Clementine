// Audio as samples: decoding any file macOS can read, writing WAV / AIFF / CAF / M4A, the waveform view and playback.

import AVFoundation
import SwiftUI

/// Decoded audio: one Float array per channel.
struct AudioData {
    var sampleRate: Double
    var channels: [[Float]]

    var frameCount: Int { channels.first?.count ?? 0 }
    var duration: Double { Double(frameCount) / sampleRate }

    static func load(_ url: URL) async throws -> AudioData {
        let asset = try await Media.open(url, audioOnly: true)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ToolError("“\(url.lastPathComponent)” has no audio.")
        }
        let descriptions = try await track.load(.formatDescriptions)
        var sampleRate = 44_100.0
        var channelCount = 2
        if let desc = descriptions.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            sampleRate = asbd.mSampleRate
            channelCount = Int(asbd.mChannelsPerFrame)
        }
        channelCount = max(1, min(channelCount, 8))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ])
        reader.add(output)
        guard reader.startReading() else { throw ToolError(reader.error?.localizedDescription ?? "The audio couldn't be read.") }
        var channels = Array(repeating: [Float](), count: channelCount)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            let count = length / MemoryLayout<Float>.size / channelCount
            pointer.withMemoryRebound(to: Float.self, capacity: count * channelCount) { samples in
                for c in 0..<channelCount {
                    channels[c].reserveCapacity(channels[c].count + count)
                    for i in 0..<count { channels[c].append(samples[i * channelCount + c]) }
                }
            }
        }
        if reader.status == .failed { throw ToolError(reader.error?.localizedDescription ?? "The audio couldn't be read.") }
        return AudioData(sampleRate: sampleRate, channels: channels)
    }

    /// Writes as <type> (WAV / AIFF / CAF in 24-bit, M4A as AAC). Nothing is left behind when it fails.
    func write(to url: URL, type: AVFileType) throws {
        do { try writeFile(to: url, type: type) } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func writeFile(to url: URL, type: AVFileType) throws {
        let channelCount = channels.count
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channelCount]
        switch type {
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            // AAC's bitrate limits depend on the sample rate: let the encoder pick it for "high" quality.
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
        default:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = type == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount)) else {
            throw ToolError("Unsupported audio format.")
        }
        let chunk = 65_536
        var start = 0
        while start < frameCount {
            let n = min(chunk, frameCount - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            for c in 0..<channelCount {
                channels[c].withUnsafeBufferPointer { src in
                    buffer.floatChannelData![c].update(from: src.baseAddress! + start, count: n)
                }
            }
            try file.write(from: buffer)
            start += n
        }
    }

    /// Peak level per bucket (0...1), all channels together, for drawing.
    func peaks(_ buckets: Int) -> [Float] {
        guard frameCount > 0, buckets > 0 else { return [] }
        let per = max(1, frameCount / buckets)
        return (0..<buckets).map { b in
            let start = b * per
            let end = min(frameCount, start + per)
            var peak: Float = 0
            if start < end {
                for channel in channels {
                    var i = start
                    while i < end { peak = max(peak, abs(channel[i])); i += max(1, (end - start) / 256) }
                }
            }
            return min(1, peak)
        }
    }

    func frame(at seconds: Double) -> Int { min(frameCount, max(0, Int(seconds * sampleRate))) }

    /// A copy of the part between two times.
    func slice(_ from: Double, _ to: Double) -> AudioData {
        let a = frame(at: from), b = max(a, frame(at: to))
        return AudioData(sampleRate: sampleRate, channels: channels.map { Array($0[a..<b]) })
    }

    /// Saves next to <source> with <suffix>: in the source's kind when AVFoundation writes it, else M4A.
    func save(from source: URL, suffix: String) throws -> URL {
        let (type, ext) = Media.audioType(for: source)
        let url = Output.file(for: source, suffix: suffix, ext: ext)
        try write(to: url, type: type)
        return url
    }
}

/// Plays audio samples (a preview), with the position published.
@MainActor
final class AudioPlayback: ObservableObject {
    @Published var position: Double = 0
    @Published var isPlaying = false
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var stopAt: Double?
    private var file: URL?

    /// Plays <data> from <from> (to <to>, or the end).
    func play(_ data: AudioData, from: Double = 0, to: Double? = nil) {
        stop()
        let url = Output.temporary("caf")
        do {
            try data.write(to: url, type: .caf)
            let player = try AVAudioPlayer(contentsOf: url)
            player.currentTime = from
            player.play()
            self.player = player
            file = url
            stopAt = to
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            isPlaying = false
        }
    }

    private func tick() {
        guard let player else { return }
        position = player.currentTime
        if !player.isPlaying || (stopAt.map { player.currentTime >= $0 } ?? false) { stop() }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        isPlaying = false
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}

/// A coloured span on the waveform.
struct WaveRegion: Identifiable, Equatable {
    var id = UUID()
    var range: ClosedRange<Double>
    var color: Color = .accentColor
}

/// The waveform with regions that can be moved and resized by their edges, and a playhead.
/// Clicking seeks; dragging on empty space creates a region when <onCreate> is set.
struct WaveformView: View {
    let peaks: [Float]
    let duration: Double
    var playhead: Double?
    @Binding var regions: [WaveRegion]
    @Binding var selected: UUID?
    var onSeek: (Double) -> Void = { _ in }
    var onCreate: ((ClosedRange<Double>) -> Void)? = nil
    /// Outside regions is dimmed (trim: the kept part is the region).
    var dimOutside = false

    @State private var drag: DragKind?

    enum DragKind { case move(UUID, ClosedRange<Double>), lower(UUID), upper(UUID), create(Double), seek }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let toX: (Double) -> CGFloat = { duration > 0 ? CGFloat($0 / duration) * w : 0 }
            let toT: (CGFloat) -> Double = { Double(min(max(0, $0), w) / max(w, 1)) * duration }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let mid = size.height / 2
                    let count = max(peaks.count, 1)
                    let barWidth = size.width / CGFloat(count)
                    var path = Path()
                    for (i, peak) in peaks.enumerated() {
                        let x = CGFloat(i) * barWidth
                        let hgt = max(1, CGFloat(peak) * (size.height / 2 - 4))
                        path.addRect(CGRect(x: x, y: mid - hgt, width: max(1, barWidth - 0.5), height: hgt * 2))
                    }
                    ctx.fill(path, with: .color(.secondary.opacity(0.7)))
                }
                if dimOutside, let r = regions.first {
                    Rectangle().fill(Color.black.opacity(0.35)).frame(width: max(0, toX(r.range.lowerBound)), height: h)
                    Rectangle().fill(Color.black.opacity(0.35))
                        .frame(width: max(0, w - toX(r.range.upperBound)), height: h)
                        .offset(x: toX(r.range.upperBound))
                }
                ForEach(regions) { region in
                    let x0 = toX(region.range.lowerBound), x1 = toX(region.range.upperBound)
                    ZStack {
                        Rectangle().fill(region.color.opacity(dimOutside ? 0.08 : 0.3))
                        Rectangle().stroke(region.color, lineWidth: selected == region.id ? 2 : 1)
                    }
                    .frame(width: max(2, x1 - x0), height: h)
                    .offset(x: x0)
                    .allowsHitTesting(false)
                }
                if let playhead {
                    Rectangle().fill(Color.primary).frame(width: 2, height: h).offset(x: toX(playhead) - 1).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let t = toT(g.location.x)
                if drag == nil {
                    let x = g.startLocation.x
                    if let r = regions.first(where: { abs(toX($0.range.lowerBound) - x) < 7 }) {
                        drag = .lower(r.id)
                    } else if let r = regions.first(where: { abs(toX($0.range.upperBound) - x) < 7 }) {
                        drag = .upper(r.id)
                    } else if let r = regions.first(where: { $0.range.contains(toT(x)) }), !dimOutside {
                        drag = .move(r.id, r.range)
                    } else if onCreate != nil && abs(g.translation.width) > 3 {
                        drag = .create(toT(x))
                    } else if abs(g.translation.width) <= 3 {
                        onSeek(t)
                        return
                    } else {
                        drag = .seek
                    }
                }
                switch drag {
                case .lower(let id):
                    if let i = regions.firstIndex(where: { $0.id == id }) {
                        selected = id
                        regions[i].range = min(t, regions[i].range.upperBound - 0.01)...regions[i].range.upperBound
                    }
                case .upper(let id):
                    if let i = regions.firstIndex(where: { $0.id == id }) {
                        selected = id
                        regions[i].range = regions[i].range.lowerBound...max(t, regions[i].range.lowerBound + 0.01)
                    }
                case .move(let id, let original):
                    if let i = regions.firstIndex(where: { $0.id == id }) {
                        selected = id
                        let length = original.upperBound - original.lowerBound
                        var start = original.lowerBound + Double(g.translation.width / max(w, 1)) * duration
                        start = min(max(0, start), duration - length)
                        regions[i].range = start...(start + length)
                    }
                case .create(let t0):
                    _ = t0
                case .seek:
                    onSeek(t)
                case nil:
                    break
                }
            }.onEnded { g in
                if case .create(let t0) = drag, let onCreate {
                    let t1 = toT(g.location.x)
                    if abs(t1 - t0) > 0.02 { onCreate(min(t0, t1)...max(t0, t1)) }
                } else if drag == nil {
                    onSeek(toT(g.location.x))
                }
                drag = nil
            })
        }
    }
}

extension Float {
    var decibels: Double { self > 0 ? 20 * log10(Double(self)) : -.infinity }
}
