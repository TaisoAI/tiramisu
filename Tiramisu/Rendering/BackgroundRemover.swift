import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

enum BGRemovalError: Error { case noMask, cannotRender }

/// Uses Vision's built-in `VNGenerateForegroundInstanceMaskRequest` (macOS 14+) —
/// no model download, runs on Neural Engine. As of v0.4 the primary entry
/// point is `mask(from:)`, which returns a grayscale CGImage suitable for
/// `PXLayer.mask`. The legacy `remove(_:)` (destructive cutout) is kept for
/// callers that still want a baked alpha-removed image.
enum BackgroundRemover {

    /// Returns a grayscale mask the same size as `image`. White = foreground
    /// (reveal), black = background (hide). Drop into `PXLayer.mask` for
    /// non-destructive background removal. Synchronous — Vision's mask APIs
    /// don't actually need an async hop, and keeping it sync lets the
    /// ControlServer's blocking HTTP handler call it without deadlocking the
    /// main actor.
    static func mask(from image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { throw BGRemovalError.noMask }
        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )
        let ci = CIImage(cvPixelBuffer: maskBuffer)
        // Vision returns the mask at the request's image-buffer resolution.
        // Up-scale to the source image's pixel size so the mask aligns with
        // the layer's render space without any extra plumbing at apply time.
        let target = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let sx = target.width / max(1, ci.extent.width)
        let sy = target.height / max(1, ci.extent.height)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: target)
        guard let cg = LayerRenderer.ciContext.createCGImage(scaled, from: target) else {
            throw BGRemovalError.cannotRender
        }
        return cg
    }

    /// Legacy destructive cutout — returns an RGBA image with the background
    /// alpha-removed. New code should call `mask(from:)` and assign to
    /// `PXLayer.mask` instead.
    static func remove(_ image: CGImage) async throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { throw BGRemovalError.noMask }
        let maskedPixelBuffer = try observation.generateMaskedImage(
            ofInstances: observation.allInstances,
            from: handler,
            croppedToInstancesExtent: false
        )
        let ci = CIImage(cvPixelBuffer: maskedPixelBuffer)
        guard let cg = LayerRenderer.ciContext.createCGImage(ci, from: ci.extent) else {
            throw BGRemovalError.cannotRender
        }
        return cg
    }

    /// Inverts a grayscale mask in-place via CoreImage. Useful for the
    /// "Invert Mask" inspector action and the v0.4 ControlServer API.
    static func invert(_ mask: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: mask)
        let f = CIFilter.colorInvert()
        f.inputImage = ci
        guard let out = f.outputImage else { return nil }
        return LayerRenderer.ciContext.createCGImage(out, from: out.extent)
    }
}
