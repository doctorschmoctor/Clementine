// Compress: smaller copies of images, videos, audio and PDFs, to a percentage or a target size.

import AVFoundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct CompressTool: View {
    @EnvironmentObject var context: ToolContext

    enum Kind { case image, video, audio, pdf }
    enum Mode: String, CaseIterable, Identifiable { case percent = "Percentage", size = "Target size"; var id: String { rawValue } }
    enum ImageFormat: String, CaseIterable, Identifiable { case same = "Same", jpeg = "JPEG", heic = "HEIC"; var id: String { rawValue } }

    @State private var mode: Mode = .percent
    @State private var reduction = 50.0
    @State private var targetMB = 1.0
    @State private var resize = false
    @State private var maxEdge = 2048.0
    @State private var imageFormat: ImageFormat = .same
    @State private var hevc = true
    @State private var flattenPdf = false
    @State private var preview: CGImage?

    private var kind: Kind {
        let ext = context.file.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if ext == "pdf" { return .pdf }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { return .video }
        if type?.conforms(to: .audio) == true { return .audio }
        if ["mkv", "webm", "avi", "wmv", "flv", "ts", "m2ts", "3gp", "ogv", "mpg", "mpeg", "vob"].contains(ext) { return .video }
        if ["opus", "ogg", "wma", "ape", "wv", "tta", "dsf", "dff", "amr", "ac3"].contains(ext) { return .audio }
        return .image
    }

    private var totalSize: Int64 { context.files.reduce(0) { $0 + fileSize($1) } }

    var body: some View {
        ToolShell(saveTitle: "Compress", onSave: save) {
            VStack(spacing: 12) {
                if kind == .image || kind == .pdf, let preview {
                    FittedImage(image: preview)
                } else {
                    Image(systemName: kind == .video ? "film" : kind == .audio ? "waveform" : "doc")
                        .font(.system(size: 64)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(context.files.count == 1 ? context.file.lastPathComponent : "\(context.files.count) files")
                    .font(.headline)
                Text("Now \(formatBytes(totalSize))  →  about \(formatBytes(targetBytes(totalSize)))")
                    .foregroundStyle(.secondary).padding(.bottom, 16)
            }
        } controls: {
            ControlSection("Reduce by") {
                Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                if mode == .percent {
                    LabeledSlider(title: "Smaller by", value: $reduction, range: 10...90, step: 5) { "\(Int($0))%" }
                } else {
                    NumberField(title: context.files.count > 1 ? "Each file (MB)" : "Target (MB)", value: $targetMB)
                }
            }
            switch kind {
            case .image:
                ControlSection("Image") {
                    Toggle("Resize while compressing", isOn: $resize)
                    if resize { NumberField(title: "Longest side (px)", value: $maxEdge) }
                    Picker("Format", selection: $imageFormat) { ForEach(ImageFormat.allCases) { Text($0.rawValue).tag($0) } }
                    Text("Lossless images (PNG, TIFF…) can only get smaller by resizing unless saved as JPEG or HEIC.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .video:
                ControlSection("Video") {
                    Toggle("HEVC (smaller, newer devices)", isOn: $hevc)
                    Toggle("Limit size", isOn: $resize)
                    if resize { NumberField(title: "Longest side (px)", value: $maxEdge) }
                }
            case .audio:
                Text("Audio is saved as AAC (M4A) at the bitrate that reaches the size.").font(.caption).foregroundStyle(.secondary)
            case .pdf:
                ControlSection("PDF") {
                    Toggle("Flatten pages to images", isOn: $flattenPdf)
                    Text(flattenPdf ? "Every page becomes a picture: text can't be selected any more, but any size can be reached."
                         : "Images inside are recompressed; text and drawings stay sharp.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await loadPreview() }
    }

    private func targetBytes(_ original: Int64) -> Int64 {
        mode == .percent ? Int64(Double(original) * (1 - reduction / 100)) : Int64(targetMB * 1_000_000) * Int64(max(1, context.files.count))
    }

    private func target(for file: URL) -> Int64 {
        mode == .percent ? Int64(Double(fileSize(file)) * (1 - reduction / 100)) : Int64(targetMB * 1_000_000)
    }

    private func loadPreview() async {
        if kind == .image {
            preview = Images.thumbnail(context.file, maxPixels: 1600)
        } else if kind == .pdf, let page = PDFDocument(url: context.file)?.page(at: 0) {
            preview = page.thumbnail(of: CGSize(width: 1200, height: 1200), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }

    private func save() {
        let files = context.files
        let kind = self.kind
        let settings = (resize: resize, maxEdge: Int(maxEdge), format: imageFormat, hevc: hevc, flatten: flattenPdf)
        let targets = files.map { target(for: $0) }
        context.save { ctx in
            var outputs: [URL] = []
            for (i, file) in files.enumerated() {
                ctx.status = files.count > 1 ? "Compressing \(i + 1) of \(files.count)…" : "Compressing…"
                let target = max(1024, targets[i])
                switch kind {
                case .image: outputs.append(try await Self.compressImage(file, target: target, resize: settings.resize ? settings.maxEdge : nil, format: settings.format))
                case .video: outputs.append(try await Self.compressVideo(file, target: target, maxEdge: settings.resize ? settings.maxEdge : nil, hevc: settings.hevc, ctx: ctx))
                case .audio: outputs.append(try await Self.compressAudio(file, target: target, ctx: ctx))
                case .pdf: outputs.append(try await Self.compressPdf(file, target: target, flatten: settings.flatten))
                }
            }
            return outputs
        }
    }

    static func compressImage(_ url: URL, target: Int64, resize: Int?, format: ImageFormat) async throws -> URL {
        var image = try Images.load(url)
        if let resize { image = Images.downscaled(image, maxPixels: resize) }
        var type = Images.outputType(for: url)
        switch format {
        case .jpeg: type = .jpeg
        case .heic: type = .heic
        case .same: break
        }
        if !Images.isLossy(type) {
            // Lossless: only size reduces it. Scale down until it fits (or 10% of the size).
            var scaled = image
            var data = Images.encoded(scaled, type: type, quality: 1)
            var factor = 1.0
            while let d = data, Int64(d.count) > target, factor > 0.1 {
                factor *= 0.85
                scaled = Images.downscaled(image, maxPixels: Int(Double(max(image.width, image.height)) * factor))
                data = Images.encoded(scaled, type: type, quality: 1)
            }
            image = scaled
            let out = Output.file(for: url, suffix: "compressed", ext: Images.fileExtension(type, source: url))
            try Images.write(image, to: out, type: type, metadata: Images.strippedForEdit(Images.metadata(url)))
            return out
        }
        // Lossy: the best quality that fits; still too big at the lowest quality → also scale down.
        var best = 0.05
        var lo = 0.05, hi = 0.95
        for _ in 0..<8 {
            let mid = (lo + hi) / 2
            if let d = Images.encoded(image, type: type, quality: mid), Int64(d.count) <= target { best = mid; lo = mid } else { hi = mid }
        }
        var factor = 1.0
        while let d = Images.encoded(image, type: type, quality: best), Int64(d.count) > target, factor > 0.15 {
            factor *= 0.85
            image = Images.downscaled(image, maxPixels: Int(Double(max(image.width, image.height)) * 0.85))
        }
        let out = Output.file(for: url, suffix: "compressed", ext: Images.fileExtension(type, source: url))
        try Images.write(image, to: out, type: type, quality: best, metadata: Images.strippedForEdit(Images.metadata(url)))
        return out
    }

    @MainActor
    static func compressVideo(_ url: URL, target: Int64, maxEdge: Int?, hevc: Bool, ctx: ToolContext) async throws -> URL {
        let asset = try await Media.open(url)
        let duration = max(0.5, try await asset.load(.duration).seconds)
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let audio = hasAudio ? 128_000 : 0
        let total = Double(target) * 8 * 0.96 / duration
        let video = max(150_000, Int(total) - audio)
        let (type, ext) = Media.videoType(for: url)
        let out = Output.file(for: url, suffix: "compressed", ext: ext)
        try await Transcoder.run(asset, to: out, type: type,
                                 settings: .init(videoBitrate: video, audioBitrate: max(audio, 64_000), maxEdge: maxEdge, hevc: hevc)) { p in
            Task { @MainActor in ctx.progress = p }
        }
        return out
    }

    @MainActor
    static func compressAudio(_ url: URL, target: Int64, ctx: ToolContext) async throws -> URL {
        let asset = try await Media.open(url, audioOnly: true)
        let duration = max(0.5, try await asset.load(.duration).seconds)
        let bitrate = min(320_000, max(32_000, Int(Double(target) * 8 * 0.97 / duration)))
        let out = Output.file(for: url, suffix: "compressed", ext: "m4a")
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ToolError("No audio in this file.") }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: out, fileType: .m4a)
        let channels = bitrate < 64_000 ? 1 : 2
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: channels, AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: bitrate,
        ])
        writer.add(input)
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "clementine.audio")) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished(); cont.resume(); return
                    }
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    Task { @MainActor in ctx.progress = min(1, t / duration) }
                    input.append(sample)
                }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw ToolError(writer.error?.localizedDescription ?? "Writing the audio failed.") }
        return out
    }

    static func compressPdf(_ url: URL, target: Int64, flatten: Bool) async throws -> URL {
        guard let document = PDFDocument(url: url) else { throw ToolError("“\(url.lastPathComponent)” couldn't be opened.") }
        let out = Output.file(for: url, suffix: "compressed", ext: "pdf")
        if !flatten {
            let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
            guard document.write(to: out, withOptions: options) else { throw ToolError("The PDF couldn't be written.") }
            if fileSize(out) >= Int64(Double(fileSize(url)) * 0.97) {
                try? FileManager.default.removeItem(at: out)
                throw ToolError("This PDF's images are already compact, so it can't get smaller this way. Turn on “Flatten pages to images” to reach a smaller size.")
            }
            return out
        }
        // Flatten: render each page as a JPEG; lower the resolution and quality until the result fits.
        var dpi = 150.0, quality = 0.8
        for _ in 0..<8 {
            let data = renderFlattened(document, dpi: dpi, quality: quality)
            if Int64(data.count) <= target || dpi <= 50 {
                try data.write(to: out)
                return out
            }
            if quality > 0.45 { quality -= 0.15 } else { dpi *= 0.75 }
        }
        try renderFlattened(document, dpi: dpi, quality: quality).write(to: out)
        return out
    }

    private static func renderFlattened(_ document: PDFDocument, dpi: Double, quality: Double) -> Data {
        let result = PDFDocument()
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let bounds = page.bounds(for: .cropBox)
            let scale = dpi / 72
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = page.thumbnail(of: size, for: .cropBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let jpeg = Images.encoded(cg, type: .jpeg, quality: quality),
                  let decoded = NSImage(data: jpeg) else { continue }
            decoded.size = bounds.size
            if let newPage = PDFPage(image: decoded) { result.insert(newPage, at: result.pageCount) }
        }
        return result.dataRepresentation() ?? Data()
    }
}
