// Create a collage: several images arranged in a grid, row, column or featured layout, at a size you set.

import SwiftUI
import UniformTypeIdentifiers

struct CollageTool: View {
    @EnvironmentObject var context: ToolContext
    @State private var files: [URL] = []
    @State private var thumbs: [URL: CGImage] = [:]
    @State private var selection: URL?
    @State private var settings = Settings()
    @State private var rendered: CGImage?

    enum Layout: String, CaseIterable, Identifiable { case grid = "Grid", row = "Row", column = "Column", featured = "Featured"; var id: String { rawValue } }
    enum Format: String, CaseIterable, Identifiable { case jpeg = "JPEG", png = "PNG", heic = "HEIC"; var id: String { rawValue } }

    struct Settings: Equatable {
        var layout: Layout = .grid
        var width = 2048.0
        var height = 2048.0
        var spacing = 16.0
        var corners = 12.0
        var background = Color.white
        var format: Format = .jpeg
    }

    private let sizes: [(String, Double, Double)] = [("Square", 2048, 2048), ("Portrait 4:5", 1080, 1350), ("Landscape 16:9", 1920, 1080), ("Story 9:16", 1080, 1920)]

    var body: some View {
        ToolShell(saveTitle: "Save", canSave: !files.isEmpty, onSave: save) {
            FittedImage(image: rendered)
        } controls: {
            ControlSection("Images") {
                List(selection: $selection) {
                    ForEach(files, id: \.self) { url in Text(url.lastPathComponent).lineLimit(1).tag(url) }
                        .onMove { files.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 150)
                HStack {
                    Button("Add…") { files += FilePicker.pick(types: [.image]) }
                    Button("Remove") { files.removeAll { $0 == selection }; selection = nil }.disabled(selection == nil)
                }
            }
            ControlSection("Layout") {
                Picker("", selection: $settings.layout) { ForEach(Layout.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                if settings.layout == .featured { Text("The first image is the large one.").font(.caption).foregroundStyle(.secondary) }
            }
            ControlSection("Size") {
                Menu("Presets") { ForEach(sizes, id: \.0) { s in Button(s.0) { settings.width = s.1; settings.height = s.2 } } }
                NumberField(title: "Width (px)", value: $settings.width)
                NumberField(title: "Height (px)", value: $settings.height)
            }
            ControlSection("Style") {
                LabeledSlider(title: "Spacing", value: $settings.spacing, range: 0...80, step: 1) { "\(Int($0)) px" }
                LabeledSlider(title: "Corners", value: $settings.corners, range: 0...80, step: 1) { "\(Int($0)) px" }
                ColorPicker("Background", selection: $settings.background, supportsOpacity: false)
                Picker("Format", selection: $settings.format) { ForEach(Format.allCases) { Text($0.rawValue).tag($0) } }
            }
        }
        .onAppear { if files.isEmpty { files = context.files } }
        .task(id: files) {
            for url in files where thumbs[url] == nil { thumbs[url] = Images.thumbnail(url, maxPixels: 900) }
            rerender()
        }
        .onChange(of: settings) { _, _ in rerender() }
    }

    private func rerender() {
        let images = files.compactMap { thumbs[$0] }
        let settings = self.settings
        let scale = min(1, 1200 / max(settings.width, settings.height, 1))
        Task.detached {
            let image = Self.render(images, settings, scale: CGFloat(scale))
            await MainActor.run { rendered = image }
        }
    }

    /// Cells of the layout, for <count> images, in a canvas of <size>.
    nonisolated static func cells(_ count: Int, _ layout: Layout, _ size: CGSize, spacing: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let inner = CGRect(origin: .zero, size: size).insetBy(dx: spacing, dy: spacing)
        func grid(_ n: Int, in r: CGRect, columns: Int) -> [CGRect] {
            let cols = max(1, columns), rows = Int(ceil(Double(n) / Double(cols)))
            let w = (r.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let h = (r.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            return (0..<n).map { i in
                let row = i / cols, col = i % cols
                // A last row that isn't full is centred.
                let inRow = row == rows - 1 ? n - row * cols : cols
                let offset = CGFloat(cols - inRow) * (w + spacing) / 2
                return CGRect(x: r.minX + offset + CGFloat(col) * (w + spacing), y: r.minY + CGFloat(row) * (h + spacing), width: w, height: h)
            }
        }
        switch layout {
        case .grid: return grid(count, in: inner, columns: Int(ceil(sqrt(Double(count)))))
        case .row: return grid(count, in: inner, columns: count)
        case .column: return grid(count, in: inner, columns: 1)
        case .featured:
            if count == 1 { return [inner] }
            let landscape = size.width >= size.height
            let big: CGRect, rest: CGRect
            if landscape {
                let w = (inner.width - spacing) * 0.62
                big = CGRect(x: inner.minX, y: inner.minY, width: w, height: inner.height)
                rest = CGRect(x: big.maxX + spacing, y: inner.minY, width: inner.width - w - spacing, height: inner.height)
            } else {
                let h = (inner.height - spacing) * 0.62
                big = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: h)
                rest = CGRect(x: inner.minX, y: big.maxY + spacing, width: inner.width, height: inner.height - h - spacing)
            }
            let others = count - 1
            let cols = landscape ? (others > 3 ? 2 : 1) : min(others, 3)
            return [big] + grid(others, in: rest, columns: cols)
        }
    }

    nonisolated static func render(_ images: [CGImage], _ s: Settings, scale: CGFloat) -> CGImage? {
        let size = CGSize(width: s.width * scale, height: s.height * scale)
        guard let ctx = Drawing.context(size, opaque: true) else { return nil }
        ctx.setFillColor(s.background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        for (image, cell) in zip(images, cells(images.count, s.layout, size, spacing: CGFloat(s.spacing) * scale)) {
            ctx.saveGState()
            let r = CGFloat(s.corners) * scale
            ctx.addPath(CGPath(roundedRect: cell, cornerWidth: min(r, cell.width / 2), cornerHeight: min(r, cell.height / 2), transform: nil))
            ctx.clip()
            Drawing.draw(image, in: Drawing.fill(image.size, cell), ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    private func save() {
        let files = self.files, settings = self.settings
        context.save { _ in
            let images = try files.map { try Images.downscaled(Images.load($0), maxPixels: Int(max(settings.width, settings.height))) }
            guard let image = Self.render(images, settings, scale: 1) else { throw ToolError("The collage couldn't be made.") }
            let type: UTType = settings.format == .png ? .png : settings.format == .heic ? .heic : .jpeg
            let out = Output.file(for: files[0], suffix: "collage", ext: settings.format == .jpeg ? "jpg" : type.preferredFilenameExtension)
            try Images.write(image, to: out, type: type, quality: 0.92)
            return [out]
        }
    }
}
