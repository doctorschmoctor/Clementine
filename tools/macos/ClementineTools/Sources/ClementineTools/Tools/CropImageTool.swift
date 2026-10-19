// Crop images: the exact area to keep, by dragging or by pixel numbers, free or at an aspect ratio.

import SwiftUI

struct CropImageTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var photo = PhotoModel()
    @State private var rect = CGRect.zero          // in preview pixels
    @State private var ratio: Ratio = .free
    @State private var customW = 3.0
    @State private var customH = 2.0
    @State private var portrait = false

    enum Ratio: String, CaseIterable, Identifiable {
        case free = "Free", original = "Original", square = "1:1", r43 = "4:3", r32 = "3:2", r169 = "16:9", r45 = "4:5", custom = "Custom"
        var id: String { rawValue }
    }

    private var aspect: CGFloat? {
        let base: CGFloat?
        switch ratio {
        case .free: return nil
        case .original: base = photo.previewSize.width / max(photo.previewSize.height, 1)
        case .square: base = 1
        case .r43: base = 4.0 / 3
        case .r32: base = 3.0 / 2
        case .r169: base = 16.0 / 9
        case .r45: base = 4.0 / 5
        case .custom: base = CGFloat(customW / max(customH, 0.01))
        }
        guard let base else { return nil }
        return portrait ? 1 / base : base
    }

    /// The crop in full-size pixels, for the number fields.
    private func fullBinding(_ key: WritableKeyPath<CGRect, CGFloat>) -> Binding<Double> {
        Binding(get: { Double((rect[keyPath: key] * photo.scale).rounded()) },
                set: { v in
                    var r = rect
                    r[keyPath: key] = CGFloat(v) / photo.scale
                    let bounds = CGRect(origin: .zero, size: photo.previewSize)
                    r = r.intersection(bounds)
                    if !r.isNull && r.width > 1 && r.height > 1 { rect = r }
                })
    }

    var body: some View {
        ToolShell(saveTitle: "Crop", canSave: photo.full != nil && rect.width > 1, onSave: save) {
            if let error = photo.error { Placeholder(text: error) } else {
                FittedImage(image: photo.preview) { mapping in
                    // Dim what is cut away.
                    DimOutside(outer: mapping.rect, inner: mapping.toView(rect))
                    EditableRect(rect: $rect, mapping: mapping, aspect: aspect, color: .white)
                }
            }
        } controls: {
            ControlSection("Aspect ratio") {
                Picker("Ratio", selection: $ratio) { ForEach(Ratio.allCases) { Text($0.rawValue).tag($0) } }
                if ratio == .custom {
                    HStack {
                        TextField("W", value: $customW, format: .number).textFieldStyle(.roundedBorder)
                        Text(":")
                        TextField("H", value: $customH, format: .number).textFieldStyle(.roundedBorder)
                    }
                }
                if ratio != .free && ratio != .square {
                    Toggle("Portrait", isOn: $portrait)
                }
            }
            ControlSection("Area (pixels)") {
                NumberField(title: "X", value: fullBinding(\.origin.x))
                NumberField(title: "Y", value: fullBinding(\.origin.y))
                NumberField(title: "Width", value: fullBinding(\.size.width))
                NumberField(title: "Height", value: fullBinding(\.size.height))
                if let full = photo.full {
                    Text("Original \(full.width) × \(full.height)").font(.caption).foregroundStyle(.secondary)
                }
                Button("Select all") { rect = CGRect(origin: .zero, size: photo.previewSize) }
            }
        }
        .task {
            await photo.load(context.file)
            let s = photo.previewSize
            rect = CGRect(x: s.width * 0.1, y: s.height * 0.1, width: s.width * 0.8, height: s.height * 0.8)
        }
        .onChange(of: ratio) { _, _ in applyAspect() }
        .onChange(of: portrait) { _, _ in applyAspect() }
        .onChange(of: customW) { _, _ in applyAspect() }
        .onChange(of: customH) { _, _ in applyAspect() }
    }

    /// Fits the largest rectangle of the ratio inside the current one, centred.
    private func applyAspect() {
        guard let aspect else { return }
        var w = rect.width, h = rect.height
        if w / h > aspect { w = h * aspect } else { h = w / aspect }
        rect = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    private func save() {
        guard let full = photo.full else { return }
        let crop = rect.scaled(photo.scale).integral.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        let source = context.file
        context.save { _ in
            guard let cropped = full.cropping(to: crop) else { throw ToolError("The image couldn't be cropped.") }
            return [try Images.save(cropped, from: source, suffix: "cropped")]
        }
    }
}

/// Darkens <outer> except <inner> (the part that is kept).
struct DimOutside: View {
    let outer: CGRect
    let inner: CGRect
    var body: some View {
        Canvas { ctx, _ in
            var path = Path()
            path.addRect(outer)
            path.addRect(inner)
            ctx.fill(path, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }
}
