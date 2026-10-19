// Create an audio visualizer: an MP4 of the recording with an animated spectrum or a still image, in landscape,
// portrait or square.

import Accelerate
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct VisualizerTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var playback = AudioPlayback()
    @State private var audio: AudioData?
    @State private var bands: [[Float]] = []
    @State private var settings = Settings()
    @State private var still: CGImage?
    @State private var error: String?

    static let fps = 30

    enum Style: String, CaseIterable, Identifiable { case bars = "Bars", wave = "Wave", still = "Still image"; var id: String { rawValue } }
    enum Shape: String, CaseIterable, Identifiable {
        case landscape = "Landscape", portrait = "Portrait", square = "Square"
        var id: String { rawValue }
        var size: CGSize {
            switch self { case .landscape: CGSize(width: 1920, height: 1080); case .portrait: CGSize(width: 1080, height: 1920); case .square: CGSize(width: 1080, height: 1080) }
        }
    }

    struct Settings: Equatable {
        var style: Style = .bars
        var shape: Shape = .landscape
        var background = Color(red: 0.07, green: 0.07, blue: 0.09)
        var accent = Color(red: 1.0, green: 0.55, blue: 0.2)
        var title = ""
        var image: URL?
        var progress = true
    }

    var body: some View {
        ToolShell(saveTitle: "Create video", canSave: audio != nil && (settings.style != .still || still != nil), onSave: save) {
            VStack(spacing: 10) {
                if let error { Placeholder(text: error) }
                else if audio == nil { ProgressView("Reading audio…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    TimelineView(.animation(paused: !playback.isPlaying)) { _ in
                        FittedImage(image: frame(at: playback.isPlaying ? playback.position : (audio?.duration ?? 0) * 0.3, scale: 0.5))
                    }
                    HStack {
                        Button(playback.isPlaying ? "Stop" : "Play") {
                            if playback.isPlaying { playback.stop() } else if let audio { playback.play(audio) }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        } controls: {
            ControlSection("Look") {
                Picker("", selection: $settings.style) { ForEach(Style.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                Picker("Shape", selection: $settings.shape) { ForEach(Shape.allCases) { Text($0.rawValue).tag($0) } }
                Text("\(Int(settings.shape.size.width)) × \(Int(settings.shape.size.height)), \(Self.fps) fps").font(.caption).foregroundStyle(.secondary)
            }
            ControlSection("Image") {
                Button(settings.image?.lastPathComponent ?? (settings.style == .still ? "Choose image…" : "Background image…")) {
                    if let url = FilePicker.pick(types: [.image], multiple: false).first {
                        settings.image = url
                        still = Images.thumbnail(url, maxPixels: 2000)
                    }
                }
                if settings.image != nil { Button("No image") { settings.image = nil; still = nil } }
            }
            ControlSection("Colours") {
                ColorPicker("Background", selection: $settings.background, supportsOpacity: false)
                ColorPicker("Accent", selection: $settings.accent, supportsOpacity: false)
            }
            ControlSection("Text") {
                TextField("Title", text: $settings.title).textFieldStyle(.roundedBorder)
                Toggle("Progress bar", isOn: $settings.progress)
            }
        }
        .task {
            settings.title = context.file.deletingPathExtension().lastPathComponent
            do {
                let data = try await AudioData.load(context.file)
                bands = await Task.detached { Self.spectrum(data, fps: Self.fps) }.value
                audio = data
                if let cover = await Self.coverArt(context.file) { still = cover }
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { playback.stop() }
    }

    private func frame(at t: Double, scale: CGFloat) -> CGImage? {
        guard let audio else { return nil }
        let i = min(bands.count - 1, max(0, Int(t * Double(Self.fps))))
        return Self.render(size: settings.shape.size, scale: scale, settings: settings, bands: bands.isEmpty ? [] : bands[i],
                           progress: t / max(audio.duration, 0.01), image: still)
    }

    static func coverArt(_ url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), let source = CGImageSourceCreateWithData(data as CFData, nil) {
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
        }
        return nil
    }

    /// 48 log-spaced bands per video frame (0...1), smoothed so bars fall gently.
    nonisolated static func spectrum(_ audio: AudioData, fps: Int) -> [[Float]] {
        let n = 2048, log2n = vDSP_Length(11), bandCount = 48
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let frames = Int(audio.duration * Double(fps)) + 1
        var mono = [Float](repeating: 0, count: audio.frameCount)
        for c in audio.channels { vDSP_vadd(mono, 1, c, 1, &mono, 1, vDSP_Length(mono.count)) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let fs = Float(audio.sampleRate)
        // Up to 16 kHz, or what the recording holds (just under half its sample rate).
        let top = min(16_000, fs * 0.45)
        let edges = (0...bandCount).map { 40 * pow(top / 40, Float($0) / Float(bandCount)) }
        var previous = [Float](repeating: 0, count: bandCount)
        var result: [[Float]] = []
        result.reserveCapacity(frames)
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var chunk = [Float](repeating: 0, count: n)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        for f in 0..<frames {
            let center = Int(Double(f) / Double(fps) * audio.sampleRate)
            let start = center - n / 2
            for i in 0..<n {
                let j = start + i
                chunk[i] = j >= 0 && j < mono.count ? mono[j] * window[i] : 0
            }
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    chunk.withUnsafeBufferPointer { c in
                        c.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
                }
            }
            var levels = [Float](repeating: 0, count: bandCount)
            for b in 0..<bandCount {
                let lo = min(n / 2 - 1, max(1, Int(edges[b] / fs * Float(n))))
                let hi = min(n / 2, max(lo + 1, Int(edges[b + 1] / fs * Float(n))))
                var peak: Float = 0
                for k in lo..<hi { peak = max(peak, magnitudes[k]) }
                let db = 20 * log10(max(peak / Float(n / 4), 1e-6))
                let v = min(1, max(0, (db + 60) / 60))
                levels[b] = max(v, previous[b] * 0.82)
            }
            previous = levels
            result.append(levels)
        }
        return result
    }

    /// One video frame. <scale> shrinks it for the preview.
    nonisolated static func render(size full: CGSize, scale: CGFloat, settings s: Settings, bands: [Float], progress: Double, image: CGImage?) -> CGImage? {
        let size = CGSize(width: full.width * scale, height: full.height * scale)
        guard let ctx = Drawing.context(size, opaque: true) else { return nil }
        draw(ctx, size: size, settings: s, bands: bands, progress: progress, image: image)
        return ctx.makeImage()
    }

    nonisolated static func draw(_ ctx: CGContext, size: CGSize, settings s: Settings, bands: [Float], progress: Double, image: CGImage?) {
        let all = CGRect(origin: .zero, size: size)
        let unit = min(size.width, size.height)
        ctx.setFillColor(s.background.cgColor)
        ctx.fill(all)
        let accent = s.accent.cgColor
        if s.style == .still, let image {
            Drawing.draw(Drawing.blurred(Images.downscaled(image, maxPixels: 400), radius: 18), in: Drawing.fill(image.size, all), ctx)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.35)); ctx.fill(all)
            let box = all.insetBy(dx: size.width * 0.12, dy: size.height * 0.16)
            let r = Drawing.fit(image.size, box)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: unit * 0.02, cornerHeight: unit * 0.02, transform: nil)); ctx.clip()
            Drawing.draw(image, in: r, ctx)
            ctx.restoreGState()
        } else {
            if let image {
                ctx.saveGState(); ctx.setAlpha(0.35)
                Drawing.draw(Drawing.blurred(Images.downscaled(image, maxPixels: 400), radius: 12), in: Drawing.fill(image.size, all), ctx)
                ctx.restoreGState()
            }
            let area = CGRect(x: size.width * 0.08, y: size.height * 0.3, width: size.width * 0.84, height: size.height * 0.4)
            if s.style == .bars, !bands.isEmpty {
                let gap = area.width / CGFloat(bands.count) * 0.3
                let w = area.width / CGFloat(bands.count) - gap
                ctx.setFillColor(accent)
                for (i, v) in bands.enumerated() {
                    let h = max(w * 0.6, area.height * CGFloat(v))
                    let x = area.minX + CGFloat(i) * (w + gap) + gap / 2
                    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: area.midY - h / 2, width: w, height: h),
                                       cornerWidth: w / 2, cornerHeight: min(w / 2, h / 2), transform: nil))
                }
                ctx.fillPath()
            } else if !bands.isEmpty {
                ctx.setStrokeColor(accent)
                ctx.setLineWidth(max(2, unit * 0.006))
                ctx.setLineJoin(.round)
                for mirror in [1.0, -1.0] {
                    for (i, v) in bands.enumerated() {
                        let x = area.minX + area.width * CGFloat(i) / CGFloat(bands.count - 1)
                        let y = area.midY - CGFloat(mirror) * area.height * 0.5 * CGFloat(v)
                        if i == 0 { ctx.move(to: CGPoint(x: x, y: y)) } else { ctx.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    ctx.strokePath()
                }
            }
        }
        if !s.title.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: unit * 0.05, weight: .bold),
                                                        .foregroundColor: NSColor.white, .paragraphStyle: style]
            (s.title as NSString).draw(in: CGRect(x: size.width * 0.06, y: size.height * (s.style == .still ? 0.04 : 0.16),
                                                  width: size.width * 0.88, height: unit * 0.08), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        if s.progress {
            let bar = CGRect(x: size.width * 0.08, y: size.height * 0.9, width: size.width * 0.84, height: max(3, unit * 0.006))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.25)); ctx.fill(bar)
            ctx.setFillColor(accent); ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(min(1, max(0, progress))), height: bar.height))
        }
    }

    private func save() {
        playback.stop()
        guard let audio else { return }
        let settings = self.settings, bands = self.bands, source = context.file
        var image = still
        context.save { ctx in
            if let url = settings.image { image = try? Images.downscaled(Images.load(url), maxPixels: 2400) }
            let out = Output.file(for: source, suffix: "visualizer", ext: "mp4")
            try await Self.write(to: out, audioURL: source, duration: audio.duration, settings: settings, bands: bands, image: image) { p in
                Task { @MainActor in ctx.progress = p }
            }
            return [out]
        }
    }

    nonisolated static func write(to url: URL, audioURL: URL, duration: Double, settings: Settings, bands: [[Float]], image: CGImage?,
                                  progress: @escaping (Double) -> Void) async throws {
        let size = settings.shape.size
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(videoInput)

        let asset = try await Media.open(audioURL, audioOnly: true)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ToolError("No audio in this file.") }
        let audioOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(audioOutput)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48_000, AVEncoderBitRateKey: 192_000,
        ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)
        reader.startReading()
        guard writer.startWriting() else { throw ToolError(writer.error?.localizedDescription ?? "The video couldn't be written.") }
        writer.startSession(atSourceTime: .zero)

        async let audioDone: Void = withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "clementine.visualizer.audio")) {
                while audioInput.isReadyForMoreMediaData {
                    guard let sample = audioOutput.copyNextSampleBuffer() else { audioInput.markAsFinished(); cont.resume(); return }
                    audioInput.append(sample)
                }
            }
        }

        let frames = max(1, Int(duration * Double(fps)))
        for f in 0..<frames {
            try Task.checkCancellation()
            while !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(3)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
                draw(ctx, size: size, settings: settings, bands: bands.isEmpty ? [] : bands[min(f, bands.count - 1)],
                     progress: Double(f) / Double(frames), image: image)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
            if f % 15 == 0 { progress(Double(f) / Double(frames)) }
        }
        videoInput.markAsFinished()
        await audioDone
        await writer.finishWriting()
        if writer.status != .completed { throw ToolError(writer.error?.localizedDescription ?? "The video couldn't be written.") }
    }
}
