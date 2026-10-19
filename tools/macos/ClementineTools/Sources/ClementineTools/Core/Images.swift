// Reading and writing images with ImageIO and Core Image, and mapping between image pixels and the preview.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum Images {
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// The image upright (EXIF orientation applied), full size.
    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ToolError("“\(url.lastPathComponent)” isn't an image macOS can open.")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ToolError("“\(url.lastPathComponent)” couldn't be read.")
        }
        return image
    }

    /// A smaller copy for previews (long edge at most <maxPixels>).
    static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func downscaled(_ image: CGImage, maxPixels: Int) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxPixels else { return image }
        let scale = CGFloat(maxPixels) / CGFloat(longEdge)
        let ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(ci, from: ci.extent.integral) ?? image
    }

    /// The type of file to write for a source: the same when ImageIO can write it, otherwise PNG (or JPEG for photos).
    /// The extension to write <type> with: the source's own when it is that type ("jpg" stays "jpg").
    static func fileExtension(_ type: UTType, source: URL) -> String {
        if let own = UTType(filenameExtension: source.pathExtension.lowercased()), own == type { return source.pathExtension }
        return type == .jpeg ? "jpg" : type.preferredFilenameExtension ?? "png"
    }

    static func outputType(for source: URL) -> UTType {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        if let type = UTType(filenameExtension: source.pathExtension.lowercased()), writable.contains(type.identifier),
           type != .pdf {
            return type
        }
        return .png
    }

    static func isLossy(_ type: UTType) -> Bool {
        type == .jpeg || type == .heic || type == .heif || type.identifier == "public.avif"
    }

    /// Writes <image> as <type>. <quality> 0...1 for lossy types. <metadata> is copied in (orientation removed: the
    /// pixels are already upright).
    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.92, metadata: [CFString: Any]? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ToolError("macOS can't write \(type.localizedDescription ?? type.identifier) files.")
        }
        var props: [CFString: Any] = metadata ?? [:]
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if isLossy(type) {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ToolError("“\(url.lastPathComponent)” couldn't be written.")
        }
    }

    /// Encoded bytes of <image> as <type> (for size estimates).
    static func encoded(_ image: CGImage, type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if isLossy(type) { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The metadata of the first image of a file.
    static func metadata(_ url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    static func cgImage(_ ci: CIImage) -> CGImage? {
        context.createCGImage(ci, from: ci.extent)
    }

    /// Saves <image> next to <source> with <suffix>, in the source's format when possible.
    static func save(_ image: CGImage, from source: URL, suffix: String, keepMetadata: Bool = true) throws -> URL {
        let type = outputType(for: source)
        let url = Output.file(for: source, suffix: suffix, ext: fileExtension(type, source: source))
        try write(image, to: url, type: type, quality: 0.92, metadata: keepMetadata ? strippedForEdit(metadata(source)) : nil)
        return url
    }

    /// Metadata worth keeping on an edited copy: pixel sizes and thumbnails are dropped (the image changed).
    static func strippedForEdit(_ props: [CFString: Any]?) -> [CFString: Any]? {
        guard var props else { return nil }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation] {
            props.removeValue(forKey: key)
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            props[kCGImagePropertyExifDictionary] = exif
        }
        return props
    }
}

/// Where an image of <imageSize> pixels is drawn when fitted into <bounds>, and conversions between the two.
struct FitMapping {
    let imageSize: CGSize
    let rect: CGRect

    init(imageSize: CGSize, in bounds: CGSize, padding: CGFloat = 16) {
        self.imageSize = imageSize
        let available = CGSize(width: max(1, bounds.width - padding * 2), height: max(1, bounds.height - padding * 2))
        let scale = min(available.width / max(imageSize.width, 1), available.height / max(imageSize.height, 1))
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    var scale: CGFloat { rect.width / max(imageSize.width, 1) }

    /// Image pixels (top-left origin) → view points.
    func toView(_ r: CGRect) -> CGRect {
        CGRect(x: rect.minX + r.minX * scale, y: rect.minY + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale)
    }

    /// View points → image pixels (top-left origin), clamped to the image.
    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max((p.x - rect.minX) / scale, 0), imageSize.width),
                y: min(max((p.y - rect.minY) / scale, 0), imageSize.height))
    }
}

/// Converts a rectangle in top-left image pixels to Core Image coordinates (bottom-left origin).
func ciRect(_ r: CGRect, imageHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: imageHeight - r.maxY, width: r.width, height: r.height)
}

/// A rectangle drawn over a fitted image that can be moved and resized by its corners and edges.
/// The rectangle is in image pixels (top-left origin).
struct EditableRect: View {
    @Binding var rect: CGRect
    let mapping: FitMapping
    var aspect: CGFloat? = nil
    var color: Color = .accentColor
    var isSelected = true
    var onSelect: () -> Void = {}

    @State private var start: CGRect?

    var body: some View {
        let view = mapping.toView(rect)
        ZStack {
            Rectangle()
                .stroke(color, lineWidth: isSelected ? 2 : 1)
                .background(Rectangle().fill(color.opacity(0.08)))
                .frame(width: view.width, height: view.height)
                .position(x: view.midX, y: view.midY)
                .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                    onSelect()
                    let origin = start ?? rect
                    if start == nil { start = rect }
                    var r = origin
                    r.origin.x = min(max(0, origin.minX + g.translation.width / mapping.scale), mapping.imageSize.width - r.width)
                    r.origin.y = min(max(0, origin.minY + g.translation.height / mapping.scale), mapping.imageSize.height - r.height)
                    rect = r
                }.onEnded { _ in start = nil })
                .onTapGesture { onSelect() }
            if isSelected {
                ForEach(Handle.allCases, id: \.self) { handle in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(color, lineWidth: 1.5))
                        .frame(width: 11, height: 11)
                        .position(handle.point(in: view))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            if start == nil { start = rect }
                            rect = handle.resize(start!, by: CGSize(width: g.translation.width / mapping.scale,
                                                                    height: g.translation.height / mapping.scale),
                                                 bounds: CGRect(origin: .zero, size: mapping.imageSize), aspect: aspect)
                        }.onEnded { _ in start = nil })
                }
            }
        }
    }

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .top: return CGPoint(x: r.midX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .right: return CGPoint(x: r.maxX, y: r.midY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            case .bottom: return CGPoint(x: r.midX, y: r.maxY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .left: return CGPoint(x: r.minX, y: r.midY)
            }
        }

        func resize(_ r: CGRect, by d: CGSize, bounds: CGRect, aspect: CGFloat?) -> CGRect {
            var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
            switch self {
            case .topLeft: minX += d.width; minY += d.height
            case .top: minY += d.height
            case .topRight: maxX += d.width; minY += d.height
            case .right: maxX += d.width
            case .bottomRight: maxX += d.width; maxY += d.height
            case .bottom: maxY += d.height
            case .bottomLeft: minX += d.width; maxY += d.height
            case .left: minX += d.width
            }
            minX = max(bounds.minX, min(minX, maxX - 4)); maxX = min(bounds.maxX, max(maxX, minX + 4))
            minY = max(bounds.minY, min(minY, maxY - 4)); maxY = min(bounds.maxY, max(maxY, minY + 4))
            var out = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            if let aspect, aspect > 0 {
                // Keep the ratio: the dragged side leads, the other follows, anchored at the opposite corner/edge.
                let horizontal = [.left, .right].contains(self)
                let vertical = [.top, .bottom].contains(self)
                var w = out.width, h = out.height
                if horizontal || (!vertical && w / max(h, 1) > aspect) { h = w / aspect } else { w = h * aspect }
                w = min(w, bounds.width); h = min(h, bounds.height)
                if w / max(h, 1) > aspect { w = h * aspect } else { h = w / aspect }
                let anchorRight = [.topLeft, .left, .bottomLeft].contains(self)
                let anchorBottom = [.topLeft, .top, .topRight].contains(self)
                var x = anchorRight ? r.maxX - w : r.minX
                var y = anchorBottom ? r.maxY - h : r.minY
                if vertical { x = r.midX - w / 2 }
                if horizontal { y = r.midY - h / 2 }
                x = min(max(bounds.minX, x), bounds.maxX - w)
                y = min(max(bounds.minY, y), bounds.maxY - h)
                out = CGRect(x: x, y: y, width: w, height: h)
            }
            return out
        }
    }
}

/// Shows a CGImage fitted, with an overlay that receives the mapping.
struct FittedImage<Overlay: View>: View {
    let image: CGImage?
    @ViewBuilder var overlay: (FitMapping) -> Overlay

    var body: some View {
        GeometryReader { geo in
            if let image {
                let mapping = FitMapping(imageSize: CGSize(width: image.width, height: image.height), in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: mapping.rect.width, height: mapping.rect.height)
                        .position(x: mapping.rect.midX, y: mapping.rect.midY)
                    overlay(mapping)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

extension FittedImage where Overlay == EmptyView {
    init(image: CGImage?) {
        self.image = image
        self.overlay = { _ in EmptyView() }
    }
}

extension Color {
    var cgColor: CGColor { NSColor(self).usingColorSpace(.sRGB)?.cgColor ?? NSColor(self).cgColor }
    var ciColor: CIColor { CIColor(cgColor: cgColor) }
}

/// A photo for an editing tool: the full image (for saving) and a smaller copy (for the live preview).
@MainActor
final class PhotoModel: ObservableObject {
    @Published var full: CGImage?
    @Published var preview: CGImage?
    @Published var error: String?

    /// preview pixels × scale = full pixels.
    var scale: CGFloat {
        guard let full, let preview else { return 1 }
        return CGFloat(full.width) / CGFloat(max(preview.width, 1))
    }

    var previewSize: CGSize { preview.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    func load(_ url: URL, previewPixels: Int = 1800) async {
        do {
            let image = try await Task.detached { try Images.load(url) }.value
            full = image
            preview = Images.downscaled(image, maxPixels: previewPixels)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension CGRect {
    func scaled(_ s: CGFloat) -> CGRect { CGRect(x: minX * s, y: minY * s, width: width * s, height: height * s) }
}
