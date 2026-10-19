// Add a background: the photo on a new canvas (colour, gradient, another image or itself blurred), with padding,
// rounded corners and a shadow — for framed images and social posts.

import SwiftUI
import UniformTypeIdentifiers

struct BackgroundTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var photo = PhotoModel()
    @State private var settings = Settings()
    @State private var rendered: CGImage?

    enum Fill: String, CaseIterable, Identifiable { case color = "Colour", gradient = "Gradient", blurred = "Blurred photo", image = "Image"; var id: String { rawValue } }
    enum Canvas: String, CaseIterable, Identifiable {
        case auto = "Fit photo", square = "1:1", portrait = "4:5", story = "9:16", wide = "16:9", photo43 = "4:3"
        var id: String { rawValue }
        var ratio: CGFloat? {
            switch self { case .auto: nil; case .square: 1; case .portrait: 0.8; case .story: 9.0 / 16; case .wide: 16.0 / 9; case .photo43: 4.0 / 3 }
        }
    }

    struct Settings: Equatable {
        var fill: Fill = .gradient
        var color1 = Color(red: 0.98, green: 0.62, blue: 0.27)
        var color2 = Color(red: 0.93, green: 0.30, blue: 0.45)
        var angle = 135.0
        var backgroundImage: URL?
        var backgroundBlur = 30.0
        var canvas: Canvas = .auto
        var padding = 10.0
        var corners = 4.0
        var shadow = 40.0
        var shadowSize = 4.0
    }

    var body: some View {
        ToolShell(saveTitle: "Save", canSave: photo.full != nil, onSave: save) {
            if let error = photo.error { Placeholder(text: error) } else { FittedImage(image: rendered) }
        } controls: {
            ControlSection("Background") {
                Picker("Fill", selection: $settings.fill) { ForEach(Fill.allCases) { Text($0.rawValue).tag($0) } }
                switch settings.fill {
                case .color:
                    ColorPicker("Colour", selection: $settings.color1, supportsOpacity: false)
                case .gradient:
                    ColorPicker("From", selection: $settings.color1, supportsOpacity: false)
                    ColorPicker("To", selection: $settings.color2, supportsOpacity: false)
                    LabeledSlider(title: "Angle", value: $settings.angle, range: 0...360, step: 5) { "\(Int($0))°" }
                case .blurred:
                    LabeledSlider(title: "Blur", value: $settings.backgroundBlur, range: 0...100, step: 1)
                case .image:
                    Button(settings.backgroundImage?.lastPathComponent ?? "Choose image…") {
                        settings.backgroundImage = FilePicker.pick(types: [.image], multiple: false).first ?? settings.backgroundImage
                    }
                    LabeledSlider(title: "Blur", value: $settings.backgroundBlur, range: 0...100, step: 1)
                }
            }
            ControlSection("Canvas") {
                Picker("Shape", selection: $settings.canvas) { ForEach(Canvas.allCases) { Text($0.rawValue).tag($0) } }
                LabeledSlider(title: "Padding", value: $settings.padding, range: 0...40, step: 1) { "\(Int($0))%" }
            }
            ControlSection("Photo") {
                LabeledSlider(title: "Rounded corners", value: $settings.corners, range: 0...25, step: 0.5) { "\(Int($0))%" }
                LabeledSlider(title: "Shadow", value: $settings.shadow, range: 0...100, step: 1) { "\(Int($0))%" }
                LabeledSlider(title: "Shadow size", value: $settings.shadowSize, range: 0...15, step: 0.5) { "\(Int($0))%" }
            }
        }
        .task {
            await photo.load(context.file, previewPixels: 1400)
            rerender()
        }
        .onChange(of: settings) { _, _ in rerender() }
    }

    private func rerender() {
        guard let preview = photo.preview else { return }
        let settings = self.settings
        Task.detached {
            let image = Self.render(preview, settings)
            await MainActor.run { rendered = image }
        }
    }

    /// The finished picture for a photo of any size (the preview and the saved one look the same).
    nonisolated static func render(_ image: CGImage, _ s: Settings) -> CGImage? {
        let photo = image.size
        let pad = max(photo.width, photo.height) * CGFloat(s.padding / 100)
        var canvas = CGSize(width: photo.width + pad * 2, height: photo.height + pad * 2)
        if let ratio = s.canvas.ratio {
            if canvas.width / canvas.height > ratio { canvas.height = canvas.width / ratio } else { canvas.width = canvas.height * ratio }
        }
        guard let ctx = Drawing.context(canvas, opaque: true) else { return nil }
        let all = CGRect(origin: .zero, size: canvas)
        switch s.fill {
        case .color:
            ctx.setFillColor(s.color1.cgColor)
            ctx.fill(all)
        case .gradient:
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [s.color1.cgColor, s.color2.cgColor] as CFArray, locations: [0, 1])!
            let a = CGFloat(s.angle * Double.pi / 180)
            let r = hypot(canvas.width, canvas.height) / 2
            let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let d = CGPoint(x: cos(a) * r, y: sin(a) * r)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: c.x - d.x, y: c.y - d.y), end: CGPoint(x: c.x + d.x, y: c.y + d.y),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .blurred, .image:
            var bg = image
            if s.fill == .image, let url = s.backgroundImage, let other = try? Images.load(url) { bg = Images.downscaled(other, maxPixels: 2400) }
            let blur = CGFloat(s.backgroundBlur / 100) * max(canvas.width, canvas.height) * 0.04
            let small = Images.downscaled(bg, maxPixels: 1200)
            let scale = CGFloat(small.width) / CGFloat(bg.width)
            Drawing.draw(Drawing.blurred(small, radius: blur * scale), in: Drawing.fill(bg.size, all), ctx)
        }
        let frame = CGRect(x: (canvas.width - photo.width) / 2, y: (canvas.height - photo.height) / 2, width: photo.width, height: photo.height)
        let radius = min(photo.width, photo.height) * CGFloat(s.corners / 100)
        let rounded = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if s.shadow > 0 {
            let size = max(photo.width, photo.height) * CGFloat(s.shadowSize / 100)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: size * 0.35), blur: size, color: CGColor(gray: 0, alpha: CGFloat(s.shadow / 100)))
            ctx.addPath(rounded)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(rounded)
        ctx.clip()
        Drawing.draw(image, in: frame, ctx)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    private func save() {
        guard let full = photo.full else { return }
        let settings = self.settings, source = context.file
        context.save { _ in
            guard let image = await Task.detached(operation: { Self.render(full, settings) }).value else {
                throw ToolError("The picture couldn't be made.")
            }
            var type = Images.outputType(for: source)
            if type == .gif || type == .bmp { type = .png }
            let out = Output.file(for: source, suffix: "background", ext: Images.fileExtension(type, source: source))
            try Images.write(image, to: out, type: type, quality: 0.92)
            return [out]
        }
    }
}
