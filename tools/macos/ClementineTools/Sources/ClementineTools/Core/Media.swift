// Video and audio with AVFoundation: opening files (FFmpeg only for what macOS can't open, like MKV or WebM),
// exporting, the player, and timecodes.

import AVFoundation
import AVKit
import SwiftUI

enum Media {
    /// An asset macOS can play for <url>. Files AVFoundation can't open are first converted with FFmpeg (the one Filee
    /// downloaded, or Homebrew's) into a temporary MOV / M4A.
    static func open(_ url: URL, audioOnly: Bool = false) async throws -> AVURLAsset {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        if (try? await asset.load(.isPlayable)) == true, let tracks = try? await asset.load(.tracks), !tracks.isEmpty {
            return asset
        }
        guard let ffmpeg = FFmpeg.path else {
            throw ToolError("macOS can't open “\(url.lastPathComponent)”. Install FFmpeg in Filee (Settings → Engines) to use files like this.")
        }
        let out = Output.temporary(audioOnly ? "m4a" : "mov")
        let copy = audioOnly ? ["-vn", "-c:a", "aac", "-b:a", "256k"] : ["-c", "copy", "-tag:v", "hvc1"]
        let copied = (try? await FFmpeg.run(ffmpeg, ["-y", "-i", url.path] + copy + [out.path])) != nil
        let copyPlays = copied ? await playable(out) : false
        if !copyPlays {
            try? FileManager.default.removeItem(at: out)
            let encode = audioOnly ? copy : ["-c:v", "h264_videotoolbox", "-b:v", "12M", "-c:a", "aac", "-b:a", "256k"]
            try await FFmpeg.run(ffmpeg, ["-y", "-i", url.path] + encode + [out.path])
        }
        let converted = AVURLAsset(url: out, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard await playable(out) else { throw ToolError("“\(url.lastPathComponent)” couldn't be opened.") }
        return converted
    }

    private static func playable(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).load(.isPlayable)) == true
    }

    static func videoTrack(_ asset: AVAsset) async throws -> AVAssetTrack {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError("This file has no video.")
        }
        return track
    }

    /// Size of a video track as shown (rotation applied).
    static func displaySize(_ track: AVAssetTrack) async throws -> CGSize {
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let r = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// Runs an export, reporting progress to <context>. Throws when it fails or is cancelled.
    @MainActor
    static func export(_ session: AVAssetExportSession, to url: URL, type: AVFileType, context: ToolContext?) async throws {
        session.outputURL = url
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in context?.progress = Double(session.progress) }
        }
        await session.export()
        timer.invalidate()
        switch session.status {
        case .completed: return
        case .cancelled: throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: url)
            throw ToolError(session.error?.localizedDescription ?? "The export failed.")
        }
    }

    /// The file type to save a video as: MOV stays MOV, everything else becomes MP4.
    static func videoType(for source: URL) -> (AVFileType, String) {
        source.pathExtension.lowercased() == "mov" ? (.mov, "mov") : (.mp4, "mp4")
    }

    /// The file type to save audio as when AVFoundation can write the source's kind, else M4A.
    static func audioType(for source: URL) -> (AVFileType, String) {
        switch source.pathExtension.lowercased() {
        case "wav", "wave": return (.wav, "wav")
        case "aif", "aiff": return (.aiff, "aiff")
        case "caf": return (.caf, "caf")
        default: return (.m4a, "m4a")
        }
    }
}

enum FFmpeg {
    /// The FFmpeg Filee downloaded, or a Homebrew one.
    static var path: String? {
        let fm = FileManager.default
        let engines = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Filee/engines")
        if let walker = fm.enumerator(at: engines, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.lastPathComponent == "ffmpeg" && fm.isExecutableFile(atPath: url.path) {
                return url.path
            }
        }
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static func run(_ ffmpeg: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-hide_banner", "-loglevel", "error"] + args
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(throwing: ToolError("FFmpeg failed: \(message.prefix(300))"))
                }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}

/// A playable video: the player, its duration and frame rate, kept in step with the playhead.
@MainActor
final class VideoModel: ObservableObject {
    let player = AVPlayer()
    @Published var asset: AVURLAsset?
    @Published var duration: Double = 0
    @Published var current: Double = 0
    @Published var frameRate: Double = 30
    @Published var size: CGSize = .zero
    @Published var isPlaying = false
    @Published var error: String?
    private var observer: Any?

    func load(_ url: URL) async {
        do {
            let asset = try await Media.open(url)
            self.asset = asset
            duration = try await asset.load(.duration).seconds
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                frameRate = Double(try await track.load(.nominalFrameRate))
                if frameRate <= 0 { frameRate = 30 }
                size = try await Media.displaySize(track)
            }
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self else { return }
                    self.current = time.seconds
                    self.isPlaying = self.player.rate != 0
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    var frameDuration: Double { 1 / max(frameRate, 1) }

    func seek(_ seconds: Double) {
        let t = min(max(0, seconds), duration)
        current = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(_ frames: Int) {
        player.pause()
        seek(current + Double(frames) * frameDuration)
    }

    func togglePlay() {
        if player.rate != 0 { player.pause() } else {
            if current >= duration - 0.05 { seek(0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func pause() { player.pause(); isPlaying = false }
}

/// AVKit's player view, without its own controls (the tools draw theirs).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var showsControls = false

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = showsControls ? .inline : .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}

/// Play/pause, frame stepping, a scrub bar and the time, for a VideoModel.
struct TransportBar: View {
    @ObservedObject var model: VideoModel
    var marks: [ClosedRange<Double>] = []
    var points: [Double] = []

    var body: some View {
        VStack(spacing: 6) {
            Timeline(duration: model.duration, current: model.current, ranges: marks, points: points) { model.seek($0) }
                .frame(height: 22)
            HStack(spacing: 10) {
                Button { model.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .help("Previous frame (←)").keyboardShortcut(.leftArrow, modifiers: [])
                Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                    .help("Play / pause (space)").keyboardShortcut(.space, modifiers: [])
                Button { model.step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .help("Next frame (→)").keyboardShortcut(.rightArrow, modifiers: [])
                Text(Timecode.format(model.current)).monospacedDigit()
                Text("/ " + Timecode.format(model.duration)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
    }
}

/// A horizontal timeline: the playhead, highlighted ranges and marked points. Click or drag to seek.
struct Timeline: View {
    let duration: Double
    let current: Double
    var ranges: [ClosedRange<Double>] = []
    var points: [Double] = []
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> CGFloat = { t in duration > 0 ? CGFloat(t / duration) * w : 0 }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                ForEach(Array(ranges.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(2, x(r.upperBound) - x(r.lowerBound)))
                        .offset(x: x(r.lowerBound))
                }
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    Rectangle().fill(Color.orange).frame(width: 2).offset(x: x(p) - 1)
                }
                Rectangle().fill(Color.primary).frame(width: 2).offset(x: x(current) - 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                seek(Double(min(max(0, g.location.x), w) / max(w, 1)) * duration)
            })
        }
    }
}

enum Timecode {
    /// "1:02:03.456" / "2:03.456".
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.000" }
        let s = max(0, seconds)
        let h = Int(s) / 3600, m = Int(s) / 60 % 60
        let rest = s - Double(h * 3600 + m * 60)
        return h > 0 ? String(format: "%d:%02d:%06.3f", h, m, rest) : String(format: "%d:%06.3f", m, rest)
    }

    /// Reads "1:02:03.456", "2:03.5" or "75.2" (seconds).
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }
}

/// A text field for a time in seconds, typed as a timecode.
struct TimecodeField: View {
    let title: String
    @Binding var seconds: Double
    var maximum: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 110)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        }
        .onAppear { text = Timecode.format(seconds) }
        .onChange(of: seconds) { _, v in if !focused { text = Timecode.format(v) } }
    }

    private func commit() {
        if let v = Timecode.parse(text) { seconds = min(max(0, v), maximum) }
        text = Timecode.format(seconds)
    }
}

enum Frames {
    /// The frame at <seconds>, upright, exactly (no nearby keyframe). <maxPixels> 0 = full size.
    static func image(_ asset: AVAsset, at seconds: Double, maxPixels: CGFloat = 0) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if maxPixels > 0 { generator.maximumSize = CGSize(width: maxPixels, height: maxPixels) }
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}
