// Redact photos: cover private parts with solid colour, blur or pixels; faces and text can be found automatically.

import SwiftUI

struct RedactImageTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var photo = PhotoModel()
    @State private var boxes: [RedactBox] = []
    @State private var selected: UUID?
    @State private var rendered: CGImage?
    @State private var detecting = false
    @State private var message: String?

    var body: some View {
        ToolShell(saveTitle: "Save", canSave: photo.full != nil && !boxes.isEmpty, onSave: save) {
            if let error = photo.error { Placeholder(text: error) } else {
                FittedImage(image: rendered ?? photo.preview) { mapping in
                    ForEach($boxes) { $box in
                        EditableRect(rect: $box.rect, mapping: mapping, color: .accentColor,
                                     isSelected: selected == box.id, onSelect: { selected = box.id })
                    }
                }
            }
        } controls: {
            ControlSection("Find automatically") {
                HStack {
                    Button("Faces") { detect(faces: true, text: false) }
                    Button("Text") { detect(faces: false, text: true) }
                    if detecting { ProgressView().controlSize(.small) }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text("Found on this Mac with Vision; nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
            }
            RedactBoxControls(boxes: $boxes, selected: $selected, add: addBox)
        }
        .task { await photo.load(context.file, previewPixels: 1600) }
        .onChange(of: boxes) { _, _ in rerender() }
    }

    private func addBox() {
        let s = photo.previewSize
        let box = RedactBox(rect: CGRect(x: s.width * 0.35, y: s.height * 0.35, width: s.width * 0.3, height: s.height * 0.2),
                            style: boxes.last?.style ?? .solid, color: boxes.last?.color ?? .black)
        boxes.append(box)
        selected = box.id
    }

    private func detect(faces: Bool, text: Bool) {
        guard let preview = photo.preview else { return }
        detecting = true
        message = nil
        Task {
            let found = (try? await Task.detached { try Redaction.detect(preview, faces: faces, text: text) }.value) ?? []
            detecting = false
            let style: RedactStyle = faces ? .blur : .solid
            boxes += found.map { RedactBox(rect: $0, style: style) }
            selected = boxes.last?.id
            message = found.isEmpty ? "Nothing found." : "Added \(found.count) area\(found.count == 1 ? "" : "s")."
        }
    }

    private func rerender() {
        guard let preview = photo.preview else { return }
        let boxes = self.boxes
        Task.detached {
            let out = Images.cgImage(Redaction.apply(CIImage(cgImage: preview), boxes: boxes, scale: 1))
            await MainActor.run { rendered = out }
        }
    }

    private func save() {
        guard let full = photo.full else { return }
        let boxes = self.boxes, scale = photo.scale, source = context.file
        context.save { _ in
            guard let image = Images.cgImage(Redaction.apply(CIImage(cgImage: full), boxes: boxes, scale: scale)) else {
                throw ToolError("The picture couldn't be made.")
            }
            // Redacting is about privacy: the copy keeps no metadata (camera, place, time).
            return [try Images.save(image, from: source, suffix: "redacted", keepMetadata: false)]
        }
    }
}
