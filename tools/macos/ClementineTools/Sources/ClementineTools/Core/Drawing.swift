// Drawing finished images with Core Graphics in top-left coordinates (like the previews).

import AppKit
import CoreImage

enum Drawing {
    /// A bitmap context <size> pixels, origin at the top left, y down.
    static func context(_ size: CGSize, opaque: Bool = false) -> CGContext? {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        return ctx
    }

    /// Draws <image> upright into <rect> of a top-left context.
    static func draw(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// The rectangle that fills <target> with an image of <size>, centred (cut at the sides or top and bottom).
    static func fill(_ size: CGSize, _ target: CGRect) -> CGRect {
        let s = max(target.width / max(size.width, 1), target.height / max(size.height, 1))
        let w = size.width * s, h = size.height * s
        return CGRect(x: target.midX - w / 2, y: target.midY - h / 2, width: w, height: h)
    }

    /// The rectangle that fits an image of <size> inside <target>, centred.
    static func fit(_ size: CGSize, _ target: CGRect) -> CGRect {
        let s = min(target.width / max(size.width, 1), target.height / max(size.height, 1))
        let w = size.width * s, h = size.height * s
        return CGRect(x: target.midX - w / 2, y: target.midY - h / 2, width: w, height: h)
    }

    static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage {
        guard radius > 0.5 else { return image }
        let ci = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Images.context.createCGImage(ci, from: ci.extent) ?? image
    }
}

extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }
}
