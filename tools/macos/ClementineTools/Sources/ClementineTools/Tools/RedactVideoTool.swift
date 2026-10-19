// Redact video: cover sensitive areas, each for its own time range, with solid colour, blur or pixels.

import AVFoundation
import CoreImage
import SwiftUI

struct RedactVideoTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var video = VideoModel()
    @State private var frame: CGImage?
    @State private var rendered: CGImage?
    @State private var boxes: [RedactBox] = []
    @State private var selected: UUID?
    @State private var detecting = false

    private func visible(_ box: RedactBox) -> Bool { video.current >= box.start - 0.001 && video.current <= box.end + 0.001 }

    var body: some View {
        ToolShell(saveTitle: "Save", canSave: video.asset != nil && !boxes.isEmpty, onSave: save) {
            VStack(spacing: 0) {
                if let error = video.error { Placeholder(text: error) } else {
                    FittedImage(image: rendered ?? frame) { mapping in
                        ForEach($boxes) { $box in
                            if visible(box) {
                                EditableRect(rect: $box.rect, mapping: mapping, color: .accentColor,
                                             isSelected: selected == box.id, onSelect: { selected = box.id })
                            }
                        }
                    }
                }
                TransportBar(model: video, marks: boxes.filter { $0.id == selected }.map { $0.start...min($0.end, video.duration) })
            }
        } controls: {
            RedactBoxControls(boxes: $boxes, selected: $selected, add: addBox)
            if let i = boxes.firstIndex(where: { $0.id == selected }) {
                ControlSection("When") {
                    TimecodeField(title: "From", seconds: $boxes[i].start, maximum: video.duration)
                    TimecodeField(title: "Until", seconds: Binding(get: { min(boxes[i].end, video.duration) }, set: { boxes[i].end = $0 }),
                                  maximum: video.duration)
                    HStack {
                        Button("From playhead") { boxes[i].start = min(video.current, boxes[i].end) }
                        Button("Until playhead") { boxes[i].end = max(video.current, boxes[i].start) }
                    }
                    Button("Whole video") { boxes[i].start = 0; boxes[i].end = .infinity }
                }
            }
            ControlSection("Find on this frame") {
                HStack {
                    Button("Faces") { detect(faces: true) }
                    Button("Text") { detect(faces: false) }
                    if detecting { ProgressView().controlSize(.small) }
                }
                Text("Found areas cover the whole video; set their times above.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await video.load(context.file); await grab() }
        .onChange(of: video.current) { _, _ in Task { await grab() } }
        .onChange(of: boxes) { _, _ in rerender() }
    }

    private func grab() async {
        guard let asset = video.asset else { return }
        frame = try? await Frames.image(asset, at: video.current)
        rerender()
    }

    private func addBox() {
        let s = video.size
        let box = RedactBox(rect: CGRect(x: s.width * 0.35, y: s.height * 0.35, width: s.width * 0.3, height: s.height * 0.2),
                            style: boxes.last?.style ?? .blur, color: boxes.last?.color ?? .black, start: video.current, end: .infinity)
        boxes.append(box)
        selected = box.id
    }

    private func detect(faces: Bool) {
        guard let frame else { return }
        detecting = true
        Task {
            let found = (try? await Task.detached { try Redaction.detect(frame, faces: faces, text: !faces) }.value) ?? []
            detecting = false
            boxes += found.map { RedactBox(rect: $0, style: faces ? .blur : .solid) }
            selected = boxes.last?.id
        }
    }

    private func rerender() {
        guard let frame else { return }
        let active = boxes.filter(visible)
        Task.detached {
            let out = Images.cgImage(Redaction.apply(CIImage(cgImage: frame), boxes: active, scale: 1))
            await MainActor.run { rendered = out }
        }
    }

    private func save() {
        guard let asset = video.asset else { return }
        video.pause()
        let boxes = self.boxes, source = context.file
        context.save { ctx in
            let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
                let t = request.compositionTime.seconds
                let active = boxes.filter { t >= $0.start - 0.001 && t <= $0.end + 0.001 }
                request.finish(with: Redaction.apply(request.sourceImage, boxes: active, scale: 1), context: nil)
            }
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                throw ToolError("This video can't be exported.")
            }
            session.videoComposition = composition
            let (type, ext) = Media.videoType(for: source)
            let out = Output.file(for: source, suffix: "redacted", ext: ext)
            try await Media.export(session, to: out, type: type, context: ctx)
            return [out]
        }
    }
}
