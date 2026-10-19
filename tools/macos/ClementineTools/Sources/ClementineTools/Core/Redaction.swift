// Covering parts of a picture: solid colour, blur or pixels, and finding faces and text with Vision.

import CoreImage
import SwiftUI
import Vision

enum RedactStyle: String, CaseIterable, Identifiable, Codable {
    case solid = "Solid", blur = "Blur", pixelate = "Pixelate"
    var id: String { rawValue }
}

struct RedactBox: Identifiable, Equatable {
    var id = UUID()
    /// In image pixels, top-left origin (of the picture the tool previews).
    var rect: CGRect
    var style: RedactStyle = .solid
    var color: Color = .black
    /// Redact video: when it is on screen.
    var start: Double = 0
    var end: Double = .infinity
}

enum Redaction {
    /// <image> with <boxes> covered. <scale> converts box pixels to <image>'s pixels.
    static func apply(_ image: CIImage, boxes: [RedactBox], scale: CGFloat) -> CIImage {
        var out = image
        let extent = image.extent
        let strength = max(extent.width, extent.height)
        for box in boxes {
            let r = ciRect(box.rect.scaled(scale), imageHeight: extent.height).offsetBy(dx: extent.minX, dy: extent.minY)
                .intersection(extent)
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            let cover: CIImage
            switch box.style {
            case .solid:
                cover = CIImage(color: box.color.ciColor).cropped(to: r)
            case .blur:
                cover = image.clampedToExtent().applyingGaussianBlur(sigma: Double(max(8, strength * 0.012))).cropped(to: r)
            case .pixelate:
                let f = CIFilter(name: "CIPixellate", parameters: [
                    kCIInputImageKey: image.clampedToExtent(),
                    kCIInputScaleKey: max(8, strength * 0.015),
                    kCIInputCenterKey: CIVector(x: r.minX, y: r.minY),
                ])
                cover = (f?.outputImage ?? image).cropped(to: r)
            }
            out = cover.composited(over: out)
        }
        return out
    }

    /// Faces and/or text found in <image>, as rectangles in its pixels (top-left origin), with a little margin.
    static func detect(_ image: CGImage, faces: Bool, text: Bool) throws -> [CGRect] {
        var requests: [VNRequest] = []
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        if faces { requests.append(faceRequest) }
        if text { requests.append(textRequest) }
        try VNImageRequestHandler(cgImage: image).perform(requests)
        let size = image.size
        func convert(_ box: CGRect, margin: CGFloat) -> CGRect {
            let r = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
            return r.insetBy(dx: -r.width * margin, dy: -r.height * margin)
                .intersection(CGRect(origin: .zero, size: size))
        }
        var found: [CGRect] = []
        if faces { found += (faceRequest.results ?? []).map { convert($0.boundingBox, margin: 0.15) } }
        if text { found += (textRequest.results ?? []).map { convert($0.boundingBox, margin: 0.08) } }
        return found
    }
}

/// The controls for the selected box and the list of boxes, shared by the photo and video tools.
struct RedactBoxControls: View {
    @Binding var boxes: [RedactBox]
    @Binding var selected: UUID?
    var add: () -> Void

    var body: some View {
        ControlSection("Areas") {
            HStack {
                Button("Add area") { add() }
                Button("Remove") { boxes.removeAll { $0.id == selected }; selected = boxes.last?.id }
                    .disabled(selected == nil).keyboardShortcut(.delete, modifiers: [])
            }
            if let i = boxes.firstIndex(where: { $0.id == selected }) {
                Picker("Cover with", selection: $boxes[i].style) { ForEach(RedactStyle.allCases) { Text($0.rawValue).tag($0) } }
                if boxes[i].style == .solid { ColorPicker("Colour", selection: $boxes[i].color, supportsOpacity: false) }
                Button("Use for all areas") {
                    let style = boxes[i].style, color = boxes[i].color
                    for j in boxes.indices { boxes[j].style = style; boxes[j].color = color }
                }
            }
            Text("\(boxes.count) area\(boxes.count == 1 ? "" : "s"). Drag to move, drag the handles to resize; later areas sit on top.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
