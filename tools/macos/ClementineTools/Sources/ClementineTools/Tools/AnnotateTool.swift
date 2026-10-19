// Annotate photos: arrows, lines, shapes, text, callouts, numbered labels, magnifiers, images, pen and highlighter.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Annotation: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case select, arrow, line, rectangle, ellipse, text, callout, number, magnifier, image, pen, highlighter
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .select: "cursorarrow"
            case .arrow: "arrow.up.right"
            case .line: "line.diagonal"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .text: "textformat"
            case .callout: "text.bubble"
            case .number: "1.circle"
            case .magnifier: "plus.magnifyingglass"
            case .image: "photo"
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            }
        }
        var name: String { rawValue == "select" ? "Select" : rawValue.capitalized }
    }

    var id = UUID()
    var kind: Kind
    /// In preview pixels (top-left origin). For a callout: start = the point it shows, end = the text box.
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: Color = .red
    var width: CGFloat = 6
    var text = "Text"
    var fontSize: CGFloat = 36
    var number = 1
    var zoom: CGFloat = 2
    var filled = false
    var imageURL: URL?

    var rect: CGRect { CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)) }

    /// Roughly what it covers, for picking it with the mouse.
    var bounds: CGRect {
        switch kind {
        case .pen, .highlighter:
            guard let first = points.first else { return .zero }
            return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -width, dy: -width)
        case .text:
            let size = AnnotationRenderer.textSize(text, fontSize)
            return CGRect(origin: start, size: size)
        case .callout:
            return AnnotationRenderer.calloutBox(self).union(CGRect(origin: start, size: .zero)).insetBy(dx: -8, dy: -8)
        case .number:
            let r = fontSize * 0.7
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .magnifier:
            let r = hypot(end.x - start.x, end.y - start.y)
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        default:
            return rect.insetBy(dx: -max(width, 6), dy: -max(width, 6))
        }
    }

    mutating func move(by d: CGSize) {
        start.x += d.width; start.y += d.height
        end.x += d.width; end.y += d.height
        points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
    }
}

enum AnnotationRenderer {
    static func font(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .semibold) }

    static func textSize(_ text: String, _ size: CGFloat) -> CGSize {
        let s = (text.isEmpty ? " " : text as NSString).size(withAttributes: [.font: font(size)])
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }

    static func calloutBox(_ a: Annotation) -> CGRect {
        let size = textSize(a.text, a.fontSize)
        let pad = a.fontSize * 0.5
        return CGRect(x: a.end.x - pad, y: a.end.y - pad, width: size.width + pad * 2, height: size.height + pad * 2)
    }

    /// Draws <base> and the annotations into a top-left context; <scale> converts preview pixels to the context's.
    static func draw(_ items: [Annotation], base: CGImage, scale: CGFloat, images: [URL: CGImage], ctx: CGContext) {
        let size = CGSize(width: base.width, height: base.height)
        Drawing.draw(base, in: CGRect(origin: .zero, size: size), ctx)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        for a in items { draw(a, base: base, baseScale: scale, images: images, ctx: ctx) }
        ctx.restoreGState()
    }

    private static func draw(_ a: Annotation, base: CGImage, baseScale: CGFloat, images: [URL: CGImage], ctx: CGContext) {
        let color = a.color.cgColor
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(a.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a.kind {
        case .select:
            break
        case .line:
            ctx.move(to: a.start); ctx.addLine(to: a.end); ctx.strokePath()
        case .arrow:
            let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x)
            let head = max(a.width * 4, 16)
            let back = CGPoint(x: a.end.x - cos(angle) * head * 0.8, y: a.end.y - sin(angle) * head * 0.8)
            ctx.move(to: a.start); ctx.addLine(to: back); ctx.strokePath()
            ctx.move(to: a.end)
            ctx.addLine(to: CGPoint(x: a.end.x - cos(angle - 0.45) * head, y: a.end.y - sin(angle - 0.45) * head))
            ctx.addLine(to: CGPoint(x: a.end.x - cos(angle + 0.45) * head, y: a.end.y - sin(angle + 0.45) * head))
            ctx.closePath(); ctx.fillPath()
        case .rectangle:
            let path = CGPath(roundedRect: a.rect, cornerWidth: a.width, cornerHeight: a.width, transform: nil)
            ctx.addPath(path)
            if a.filled { ctx.fillPath() } else { ctx.strokePath() }
        case .ellipse:
            ctx.addEllipse(in: a.rect)
            if a.filled { ctx.fillPath() } else { ctx.strokePath() }
        case .text:
            drawText(a.text, at: a.start, size: a.fontSize, color: NSColor(a.color), shadow: true)
        case .callout:
            let box = calloutBox(a)
            let target = a.start
            let edge = CGPoint(x: min(max(target.x, box.minX), box.maxX), y: min(max(target.y, box.minY), box.maxY))
            ctx.setLineWidth(max(2, a.width * 0.5))
            ctx.move(to: target); ctx.addLine(to: edge); ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: target.x - a.width, y: target.y - a.width, width: a.width * 2, height: a.width * 2))
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: a.fontSize * 0.35, cornerHeight: a.fontSize * 0.35, transform: nil))
            ctx.fillPath()
            drawText(a.text, at: CGPoint(x: box.minX + a.fontSize * 0.5, y: box.minY + a.fontSize * 0.5), size: a.fontSize,
                     color: contrasting(a.color), shadow: false)
        case .number:
            let r = a.fontSize * 0.7
            ctx.fillEllipse(in: CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2))
            let text = "\(a.number)"
            let size = textSize(text, a.fontSize * 0.9)
            drawText(text, at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2), size: a.fontSize * 0.9,
                     color: contrasting(a.color), shadow: false)
        case .magnifier:
            let r = max(8, hypot(a.end.x - a.start.x, a.end.y - a.start.y))
            let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
            ctx.saveGState()
            ctx.addEllipse(in: circle)
            ctx.clip()
            // The base around the centre, <zoom> times larger (base pixels = preview pixels × baseScale).
            let full = CGRect(x: 0, y: 0, width: CGFloat(base.width) / baseScale, height: CGFloat(base.height) / baseScale)
            let z = a.zoom
            let drawn = CGRect(x: a.start.x - a.start.x * z, y: a.start.y - a.start.y * z, width: full.width * z, height: full.height * z)
            Drawing.draw(base, in: drawn, ctx)
            ctx.restoreGState()
            ctx.setLineWidth(max(3, a.width * 0.6))
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.strokeEllipse(in: circle)
            ctx.setLineWidth(1.5)
            ctx.setStrokeColor(color)
            ctx.strokeEllipse(in: circle.insetBy(dx: -max(1.5, a.width * 0.3), dy: -max(1.5, a.width * 0.3)))
        case .image:
            if let url = a.imageURL, let image = images[url] {
                Drawing.draw(image, in: Drawing.fit(image.size, a.rect), ctx)
            }
        case .pen, .highlighter:
            guard let first = a.points.first else { break }
            if a.kind == .highlighter {
                ctx.setBlendMode(.multiply)
                ctx.setStrokeColor(color.copy(alpha: 0.45) ?? color)
                ctx.setLineCap(.square)
            }
            ctx.move(to: first)
            for p in a.points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func contrasting(_ color: Color) -> NSColor {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum > 0.6 ? .black : .white
    }

    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor, shadow: Bool) {
        var attrs: [NSAttributedString.Key: Any] = [.font: font(size), .foregroundColor: color]
        if shadow {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.55)
            s.shadowBlurRadius = size * 0.12
            s.shadowOffset = NSSize(width: 0, height: -size * 0.04)
            attrs[.shadow] = s
        }
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}

struct AnnotateTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var photo = PhotoModel()
    @State private var items: [Annotation] = []
    @State private var history: [[Annotation]] = []
    @State private var tool: Annotation.Kind = .arrow
    @State private var selected: UUID?
    @State private var color = Color.red
    @State private var lineWidth: CGFloat = 6
    @State private var fontSize: CGFloat = 36
    @State private var images: [URL: CGImage] = [:]
    @State private var rendered: CGImage?
    @State private var dragStart: [Annotation]?

    var body: some View {
        ToolShell(saveTitle: "Save", canSave: photo.full != nil && !items.isEmpty, sidebarWidth: 290, onSave: save) {
            if let error = photo.error { Placeholder(text: error) } else {
                FittedImage(image: rendered ?? photo.preview) { mapping in
                    Color.clear
                        .frame(width: mapping.rect.width, height: mapping.rect.height)
                        .position(x: mapping.rect.midX, y: mapping.rect.midY)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { g in
                            drag(g, mapping)
                        }.onEnded { g in
                            endDrag(g, mapping)
                        })
                    if let item = items.first(where: { $0.id == selected }) {
                        let b = mapping.toView(item.bounds)
                        Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: b.width, height: b.height).position(x: b.midX, y: b.midY)
                            .allowsHitTesting(false)
                    }
                }
            }
        } controls: {
            ControlSection("Tool") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(Annotation.Kind.allCases) { kind in
                        Button { choose(kind) } label: {
                            Image(systemName: kind.icon).frame(width: 30, height: 24)
                        }
                        .buttonStyle(.bordered)
                        .tint(tool == kind ? .accentColor : nil)
                        .help(kind.name)
                    }
                }
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            ControlSection("Style") {
                ColorPicker("Colour", selection: binding(\.color, $color))
                LabeledSlider(title: "Line", value: doubleBinding(binding(\.width, $lineWidth)), range: 1...40, step: 1)
                LabeledSlider(title: "Text size", value: doubleBinding(binding(\.fontSize, $fontSize)), range: 12...160, step: 1)
            }
            if let i = items.firstIndex(where: { $0.id == selected }) {
                ControlSection("Selected") {
                    if [.text, .callout].contains(items[i].kind) {
                        TextField("Text", text: $items[i].text, axis: .vertical).textFieldStyle(.roundedBorder)
                    }
                    if [.rectangle, .ellipse].contains(items[i].kind) { Toggle("Filled", isOn: $items[i].filled) }
                    if items[i].kind == .number { Stepper("Number \(items[i].number)", value: $items[i].number, in: 0...999) }
                    if items[i].kind == .magnifier {
                        LabeledSlider(title: "Zoom", value: doubleBinding($items[i].zoom), range: 1.25...6, step: 0.25) { String(format: "%.2g×", $0) }
                    }
                    HStack {
                        Button("Delete") { remember(); items.removeAll { $0.id == selected }; selected = nil }
                            .keyboardShortcut(.delete, modifiers: [])
                        Button("Bring to front") { remember(); let item = items.remove(at: i); items.append(item) }
                    }
                }
            }
            HStack {
                Button("Undo") { undo() }.keyboardShortcut("z", modifiers: .command).disabled(history.isEmpty)
                Button("Clear") { remember(); items = []; selected = nil }.disabled(items.isEmpty)
            }
        }
        .task { await photo.load(context.file, previewPixels: 1800); rerender() }
        .onChange(of: items) { _, _ in rerender() }
    }

    private var hint: String {
        switch tool {
        case .select: "Click a mark to select it, drag to move it."
        case .text, .number: "Click where it goes."
        case .callout: "Drag from the point to show to where the text goes."
        case .magnifier: "Drag from the centre outwards."
        case .image: "Drag the area for the image."
        default: "Drag on the photo."
        }
    }

    /// A style control that edits the selected mark (and becomes the style of new ones).
    private func binding<T>(_ key: WritableKeyPath<Annotation, T>, _ fallback: Binding<T>) -> Binding<T> {
        Binding(get: { items.first(where: { $0.id == selected }).map { $0[keyPath: key] } ?? fallback.wrappedValue },
                set: { v in
                    fallback.wrappedValue = v
                    if let i = items.firstIndex(where: { $0.id == selected }) { items[i][keyPath: key] = v }
                })
    }

    private func doubleBinding(_ b: Binding<CGFloat>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = CGFloat($0) })
    }

    private func choose(_ kind: Annotation.Kind) {
        tool = kind
        if kind != .select { selected = nil }
    }

    private func remember() {
        history.append(items)
        if history.count > 100 { history.removeFirst() }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        items = last
        if !items.contains(where: { $0.id == selected }) { selected = nil }
    }

    private func drag(_ g: DragGesture.Value, _ mapping: FitMapping) {
        // The overlay is the image's frame: its local points are view points offset by the image's origin.
        let viewStart = CGPoint(x: g.startLocation.x + mapping.rect.minX, y: g.startLocation.y + mapping.rect.minY)
        let viewNow = CGPoint(x: g.location.x + mapping.rect.minX, y: g.location.y + mapping.rect.minY)
        let p0 = mapping.toImage(viewStart), p = mapping.toImage(viewNow)
        if dragStart == nil {
            dragStart = items
            if tool == .select {
                selected = items.last(where: { $0.bounds.contains(p0) })?.id
                return
            }
            remember()
            var item = Annotation(kind: tool, start: p0, end: p0, color: color, width: lineWidth, fontSize: fontSize)
            switch tool {
            case .number: item.number = (items.filter { $0.kind == .number }.map(\.number).max() ?? 0) + 1
            case .pen, .highlighter:
                item.points = [p0]
                if tool == .highlighter { item.width = max(lineWidth * 3, 18); item.color = color == .red ? .yellow : color }
            case .image:
                guard let url = FilePicker.pick(types: [.image], multiple: false).first else { dragStart = nil; return }
                images[url] = images[url] ?? Images.thumbnail(url, maxPixels: 2400)
                item.imageURL = url
                if let img = images[url] {
                    let w = photo.previewSize.width * 0.3
                    item.start = p0
                    item.end = CGPoint(x: p0.x + w, y: p0.y + w * CGFloat(img.height) / CGFloat(img.width))
                }
            case .callout: item.text = "Note"
            default: break
            }
            items.append(item)
            selected = item.id
            return
        }
        guard let i = items.firstIndex(where: { $0.id == selected }) else { return }
        if tool == .select, let before = dragStart?.first(where: { $0.id == selected }) {
            var moved = before
            moved.move(by: CGSize(width: p.x - p0.x, height: p.y - p0.y))
            items[i] = moved
            return
        }
        switch items[i].kind {
        case .pen, .highlighter: items[i].points.append(p)
        case .text, .number: items[i].start = p
        case .image where items[i].end != items[i].start && hypot(p.x - p0.x, p.y - p0.y) < 4: break
        default: items[i].end = p
        }
    }

    private func endDrag(_ g: DragGesture.Value, _ mapping: FitMapping) {
        defer { dragStart = nil }
        if tool == .select, let before = dragStart, before != items { history.append(before) }
        // A click with a shape tool makes nothing useful: drop it.
        if let i = items.firstIndex(where: { $0.id == selected }), [.arrow, .line, .rectangle, .ellipse, .magnifier].contains(items[i].kind),
           hypot(items[i].end.x - items[i].start.x, items[i].end.y - items[i].start.y) < 3 {
            items.remove(at: i)
            selected = nil
            _ = history.popLast()
        }
        if let i = items.firstIndex(where: { $0.id == selected }), items[i].kind == .callout,
           hypot(items[i].end.x - items[i].start.x, items[i].end.y - items[i].start.y) < 3 {
            items[i].end = CGPoint(x: items[i].start.x + 60, y: items[i].start.y - 80)
        }
    }

    private func rerender() {
        guard let preview = photo.preview else { return }
        guard let ctx = Drawing.context(preview.size) else { return }
        AnnotationRenderer.draw(items, base: preview, scale: 1, images: images, ctx: ctx)
        rendered = ctx.makeImage()
    }

    private func save() {
        guard let full = photo.full else { return }
        let items = self.items, scale = photo.scale, source = context.file
        var images = self.images
        context.save { _ in
            for url in Set(items.compactMap(\.imageURL)) { images[url] = try? Images.load(url) }
            guard let ctx = Drawing.context(full.size) else { throw ToolError("The picture couldn't be made.") }
            AnnotationRenderer.draw(items, base: full, scale: scale, images: images, ctx: ctx)
            guard let image = ctx.makeImage() else { throw ToolError("The picture couldn't be made.") }
            var type = Images.outputType(for: source)
            if type == .gif || type == .bmp { type = .png }
            let out = Output.file(for: source, suffix: "annotated", ext: Images.fileExtension(type, source: source))
            try Images.write(image, to: out, type: type, quality: 0.92, metadata: Images.strippedForEdit(Images.metadata(source)))
            return [out]
        }
    }
}
