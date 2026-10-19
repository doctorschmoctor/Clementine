// Crop video: reframe to an area and exact output size, keeping the original audio.

import AVFoundation
import CoreImage
import SwiftUI

struct CropVideoTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var video = VideoModel()
    @State private var frame: CGImage?
    @State private var rect = CGRect.zero        // in video pixels (as shown)
    @State private var ratio: CropImageTool.Ratio = .free
    @State private var outWidth = 0.0
    @State private var outHeight = 0.0
    @State private var scaleOutput = false

    private var aspect: CGFloat? {
        switch ratio {
        case .free: nil
        case .original: video.size.width / max(video.size.height, 1)
        case .square: 1
        case .r43: 4.0 / 3
        case .r32: 3.0 / 2
        case .r169: 16.0 / 9
        case .r45: 4.0 / 5
        case .custom: 9.0 / 16
        }
    }

    private func pixelBinding(_ key: WritableKeyPath<CGRect, CGFloat>) -> Binding<Double> {
        Binding(get: { Double(rect[keyPath: key].rounded()) }, set: { v in
            var r = rect
            r[keyPath: key] = CGFloat(v)
            r = r.intersection(CGRect(origin: .zero, size: video.size))
            if !r.isNull && r.width > 2 && r.height > 2 { rect = r }
        })
    }

    var body: some View {
        ToolShell(saveTitle: "Crop", canSave: video.asset != nil && rect.width > 2, onSave: save) {
            VStack(spacing: 0) {
                if let error = video.error { Placeholder(text: error) } else {
                    FittedImage(image: frame) { mapping in
                        DimOutside(outer: mapping.rect, inner: mapping.toView(rect))
                        EditableRect(rect: $rect, mapping: mapping, aspect: aspect, color: .white)
                    }
                }
                TransportBar(model: video)
            }
        } controls: {
            ControlSection("Aspect ratio") {
                Picker("Ratio", selection: $ratio) {
                    ForEach(CropImageTool.Ratio.allCases) { r in Text(r == .custom ? "9:16" : r.rawValue).tag(r) }
                }
            }
            ControlSection("Area (pixels)") {
                NumberField(title: "X", value: pixelBinding(\.origin.x))
                NumberField(title: "Y", value: pixelBinding(\.origin.y))
                NumberField(title: "Width", value: pixelBinding(\.size.width))
                NumberField(title: "Height", value: pixelBinding(\.size.height))
                Text("Video \(Int(video.size.width)) × \(Int(video.size.height))").font(.caption).foregroundStyle(.secondary)
            }
            ControlSection("Output size") {
                Toggle("Scale to an exact size", isOn: $scaleOutput)
                if scaleOutput {
                    NumberField(title: "Width", value: $outWidth)
                    NumberField(title: "Height", value: $outHeight)
                }
                Text("The original audio is kept.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            await video.load(context.file)
            let s = video.size
            rect = CGRect(x: s.width * 0.1, y: s.height * 0.1, width: s.width * 0.8, height: s.height * 0.8)
            outWidth = Double(Int(rect.width / 2) * 2); outHeight = Double(Int(rect.height / 2) * 2)
            await grabFrame()
        }
        .onChange(of: video.current) { _, _ in Task { await grabFrame() } }
        .onChange(of: ratio) { _, _ in
            guard let aspect else { return }
            var w = rect.width, h = rect.height
            if w / h > aspect { w = h * aspect } else { h = w / aspect }
            rect = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        }
        .onChange(of: rect) { _, r in if !scaleOutput { outWidth = Double(Int(r.width / 2) * 2); outHeight = Double(Int(r.height / 2) * 2) } }
    }

    private func grabFrame() async {
        guard let asset = video.asset else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Full size: the crop rectangle is in the video's own pixels.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let (image, _) = try? await generator.image(at: CMTime(seconds: video.current, preferredTimescale: 600)) {
            frame = image
        }
    }

    private func save() {
        guard let asset = video.asset else { return }
        video.pause()
        let crop = rect.integral, size = video.size, source = context.file
        let output = CGSize(width: Int(scaleOutput ? outWidth : crop.width) / 2 * 2, height: Int(scaleOutput ? outHeight : crop.height) / 2 * 2)
        context.save { ctx in
            // Frames arrive upright (the track's rotation applied); crop there, in Core Image's bottom-left coordinates.
            let ci = ciRect(crop, imageHeight: size.height)
            let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
                let cropped = request.sourceImage.cropped(to: ci).transformed(by: CGAffineTransform(translationX: -ci.minX, y: -ci.minY))
                let scaled = cropped.transformed(by: CGAffineTransform(scaleX: output.width / ci.width, y: output.height / ci.height))
                request.finish(with: scaled, context: nil)
            }
            composition.renderSize = output
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                throw ToolError("This video can't be exported.")
            }
            session.videoComposition = composition
            let (type, ext) = Media.videoType(for: source)
            let out = Output.file(for: source, suffix: "cropped", ext: ext)
            try await Media.export(session, to: out, type: type, context: ctx)
            return [out]
        }
    }
}
