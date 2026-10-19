// Edit photos: light, colour and detail, plus dehaze, clarity, grain and noise reduction, with a live preview.

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct EditPhotoTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var photo = PhotoModel()
    @State private var adj = Adjustments()
    @State private var rendered: CGImage?
    @State private var showOriginal = false

    struct Adjustments: Equatable {
        var exposure = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
        var temperature = 0.0, tint = 0.0, saturation = 0.0, vibrance = 0.0
        var sharpness = 0.0, clarity = 0.0, dehaze = 0.0, noise = 0.0, grain = 0.0, vignette = 0.0
    }

    var body: some View {
        ToolShell(saveTitle: "Save", canSave: photo.full != nil && adj != Adjustments(), onSave: save) {
            VStack(spacing: 0) {
                if let error = photo.error { Placeholder(text: error) } else {
                    FittedImage(image: showOriginal ? photo.preview : (rendered ?? photo.preview))
                }
                HStack {
                    Text("Hold to compare").foregroundStyle(.secondary)
                    Image(systemName: showOriginal ? "eye.slash" : "eye")
                }
                .padding(8)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0, pressing: { showOriginal = $0 }, perform: {})
            }
        } controls: {
            ControlSection("Light") {
                slider("Exposure", $adj.exposure, -2...2, "%+.2f EV")
                slider("Contrast", $adj.contrast)
                slider("Highlights", $adj.highlights)
                slider("Shadows", $adj.shadows)
                slider("Whites", $adj.whites)
                slider("Blacks", $adj.blacks)
            }
            ControlSection("Colour") {
                slider("Temperature", $adj.temperature)
                slider("Tint", $adj.tint)
                slider("Saturation", $adj.saturation)
                slider("Vibrance", $adj.vibrance)
            }
            ControlSection("Detail") {
                slider("Sharpness", $adj.sharpness, 0...100)
                slider("Clarity", $adj.clarity)
                slider("Dehaze", $adj.dehaze)
                slider("Noise reduction", $adj.noise, 0...100)
                slider("Grain", $adj.grain, 0...100)
                slider("Vignette", $adj.vignette, 0...100)
            }
            Button("Reset all") { adj = Adjustments() }
        }
        .task { await photo.load(context.file, previewPixels: 1600); rerender() }
        .onChange(of: adj) { _, _ in rerender() }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double> = -100...100, _ format: String = "%+.0f") -> some View {
        LabeledSlider(title: title, value: value, range: range) { String(format: format, $0) }
            .onTapGesture(count: 2) { value.wrappedValue = 0 }
    }

    private func rerender() {
        guard let preview = photo.preview, let full = photo.full else { return }
        let adj = self.adj
        // Radii are set for the full photo: the preview, smaller, gets them smaller.
        let scale = CGFloat(preview.width) / CGFloat(full.width)
        Task.detached {
            let out = Images.cgImage(Self.apply(adj, to: CIImage(cgImage: preview), scale: scale))
            await MainActor.run { rendered = out }
        }
    }

    nonisolated static func apply(_ a: Adjustments, to input: CIImage, scale: CGFloat) -> CIImage {
        let extent = input.extent
        let longEdge = max(extent.width, extent.height) / max(scale, 0.01)
        var img = input
        func f(_ v: Double) -> Float { Float(v / 100) }

        if a.noise > 0 {
            let n = CIFilter.noiseReduction()
            n.inputImage = img; n.noiseLevel = 0.005 + 0.04 * f(a.noise); n.sharpness = 0.4
            img = n.outputImage ?? img
        }
        if a.temperature != 0 || a.tint != 0 {
            let t = CIFilter.temperatureAndTint()
            t.inputImage = img
            t.neutral = CIVector(x: 6500, y: 0)
            t.targetNeutral = CIVector(x: CGFloat(6500 - a.temperature * 30), y: CGFloat(a.tint))
            img = t.outputImage ?? img
        }
        if a.exposure != 0 {
            let e = CIFilter.exposureAdjust(); e.inputImage = img; e.ev = Float(a.exposure); img = e.outputImage ?? img
        }
        if a.highlights < 0 || a.shadows != 0 {
            // Negative highlights recover bright areas; shadows lift (or deepen) the dark ones.
            let h = CIFilter.highlightShadowAdjust()
            h.inputImage = img
            h.highlightAmount = 1 + min(0, f(a.highlights)) * 0.9
            h.shadowAmount = f(a.shadows)
            h.radius = Float(longEdge * scale * 0.01)
            img = h.outputImage ?? img
        }
        if a.highlights > 0 {
            let c = CIFilter.toneCurve()
            c.inputImage = img
            c.point0 = CGPoint(x: 0, y: 0); c.point1 = CGPoint(x: 0.25, y: 0.25); c.point2 = CGPoint(x: 0.5, y: 0.5)
            c.point3 = CGPoint(x: 0.75, y: CGFloat(0.75 + f(a.highlights) * 0.1)); c.point4 = CGPoint(x: 1, y: 1)
            img = c.outputImage ?? img
        }
        if a.whites != 0 || a.blacks != 0 {
            // A tone curve: lifts or lowers the ends.
            let c = CIFilter.toneCurve()
            c.inputImage = img
            c.point0 = CGPoint(x: 0, y: CGFloat(max(0, f(a.blacks)) * 0.15))
            c.point1 = CGPoint(x: 0.25, y: CGFloat(0.25 + f(a.blacks) * 0.06))
            c.point2 = CGPoint(x: 0.5, y: 0.5)
            c.point3 = CGPoint(x: 0.75, y: CGFloat(0.75 + f(a.whites) * 0.06))
            c.point4 = CGPoint(x: 1, y: CGFloat(1 + min(0, f(a.whites)) * 0.15))
            img = c.outputImage ?? img
        }
        if a.dehaze != 0 {
            // Haze lifts the darks and washes out colour: pull the black point down, add local contrast and colour.
            let d = f(a.dehaze)
            let c = CIFilter.toneCurve()
            c.inputImage = img
            c.point0 = CGPoint(x: CGFloat(max(0, d) * 0.08), y: CGFloat(max(0, -d) * 0.1))
            c.point1 = CGPoint(x: 0.25, y: CGFloat(0.25 - d * 0.05))
            c.point2 = CGPoint(x: 0.5, y: CGFloat(0.5 - d * 0.02))
            c.point3 = CGPoint(x: 0.75, y: 0.75)
            c.point4 = CGPoint(x: 1, y: 1)
            img = c.outputImage ?? img
            let u = CIFilter.unsharpMask()
            u.inputImage = img; u.radius = Float(longEdge * scale * 0.02); u.intensity = 0.6 * d
            img = u.outputImage ?? img
            let s = CIFilter.colorControls(); s.inputImage = img; s.saturation = 1 + 0.25 * d; img = s.outputImage ?? img
        }
        if a.contrast != 0 || a.saturation != 0 {
            let c = CIFilter.colorControls()
            c.inputImage = img
            c.contrast = 1 + f(a.contrast) * 0.5
            c.saturation = 1 + f(a.saturation)
            img = c.outputImage ?? img
        }
        if a.vibrance != 0 {
            let v = CIFilter.vibrance(); v.inputImage = img; v.amount = f(a.vibrance); img = v.outputImage ?? img
        }
        if a.clarity != 0 {
            let u = CIFilter.unsharpMask()
            u.inputImage = img; u.radius = Float(longEdge * scale * 0.012); u.intensity = 0.8 * f(a.clarity)
            img = u.outputImage ?? img
        }
        if a.sharpness > 0 {
            let s = CIFilter.sharpenLuminance()
            s.inputImage = img; s.sharpness = 1.5 * f(a.sharpness); s.radius = Float(max(1, 1.5 * scale * 2))
            img = s.outputImage ?? img
        }
        if a.vignette > 0 {
            let v = CIFilter.vignette(); v.inputImage = img; v.intensity = 1.5 * f(a.vignette); v.radius = 1.2
            img = v.outputImage ?? img
        }
        if a.grain > 0 {
            // Monochrome noise, softly blended (scaled so grain looks the same in the preview and the photo).
            let noise = CIFilter.randomGenerator().outputImage!
                .transformed(by: CGAffineTransform(scaleX: max(scale, 0.25), y: max(scale, 0.25)))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(0.35 * f(a.grain))),
                ])
                .cropped(to: extent)
            img = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: img])
        }
        return img.cropped(to: extent)
    }

    private func save() {
        guard let full = photo.full else { return }
        let adj = self.adj, source = context.file
        context.save { _ in
            guard let image = await Task.detached(operation: { Images.cgImage(Self.apply(adj, to: CIImage(cgImage: full), scale: 1)) }).value else {
                throw ToolError("The photo couldn't be made.")
            }
            return [try Images.save(image, from: source, suffix: "edited")]
        }
    }
}
