import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins

/// Decode the smart source back to a CGImage (from URL if reachable, else from embedded bytes).
enum SmartObjectEngine {
    /// Cache of decoded sources keyed by a hash of the backing data. PNG decode
    /// is expensive (~50ms for a large image); the drag loop would otherwise
    /// redo it every frame. Cached CGImages are cheap to hold (just a ref).
    nonisolated(unsafe) private static var decodeCache: [Int: CGImage] = [:]

    static func loadSource(_ smart: SmartSource) -> CGImage? {
        // Prefer the URL so external edits (double-click → save) show up.
        if let path = smart.sourcePath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return cachedDecode(data)
        }
        if let bytes = smart.sourceBytes {
            return cachedDecode(bytes)
        }
        return nil
    }

    private static func cachedDecode(_ data: Data) -> CGImage? {
        // Cheap O(1)-ish key: byte count + a hash of the first 32 bytes. Good
        // enough to distinguish different images without scanning all bytes
        // (which `Data.hashValue` does — ~O(n) on multi-MB PNGs).
        var hasher = Hasher()
        hasher.combine(data.count)
        data.prefix(32).forEach { hasher.combine($0) }
        let key = hasher.finalize()

        if let hit = decodeCache[key] { return hit }
        guard let cg = decode(data) else { return nil }
        decodeCache[key] = cg
        if decodeCache.count > 16 {
            decodeCache.removeValue(forKey: decodeCache.keys.first!)
        }
        return cg
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            tlog("decode: CGImageSourceCreateWithData failed (\(data.count) bytes)")
            return nil
        }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Rasterize the smart source into a canvas-sized CGImage, applying the transform.
    static func rasterize(_ smart: SmartSource, canvas: CGSize) -> CGImage? {
        guard var src = loadSource(smart) else {
            tlog("rasterize: loadSource returned nil")
            return nil
        }
        if let tweaked = applyEdgeTweaks(src,
                                         offset: smart.edgeOffset,
                                         feather: smart.edgeFeather,
                                         threshold: smart.edgeThreshold) {
            src = tweaked
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(data: nil,
                                  width: Int(canvas.width),
                                  height: Int(canvas.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            tlog("rasterize: CGContext init failed for \(Int(canvas.width))x\(Int(canvas.height))")
            return nil
        }
        ctx.interpolationQuality = .high

        ctx.translateBy(x: CGFloat(smart.centerX), y: canvas.height - CGFloat(smart.centerY))
        ctx.rotate(by: -CGFloat(smart.rotationDeg) * .pi / 180)
        let sx = CGFloat(smart.scaleX) * (smart.flipH ? -1 : 1)
        let sy = CGFloat(smart.scaleY) * (smart.flipV ? -1 : 1)
        ctx.scaleBy(x: sx, y: sy)
        let w = CGFloat(src.width), h = CGFloat(src.height)
        ctx.draw(src, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        let out = ctx.makeImage()
        tlog("rasterize: src=\(src.width)x\(src.height), scale=(\(sx),\(sy)), center=(\(smart.centerX),\(smart.centerY)), canvas=\(Int(canvas.width))x\(Int(canvas.height)) → \(out != nil ? "ok" : "FAILED")")
        return out
    }

    /// Post-process only the source's *alpha* channel. RGB is preserved inside the
    /// subject; alpha is dilated/eroded/feathered/thresholded independently. Requires
    /// the source to have transparency somewhere — has no useful effect on fully
    /// opaque images.
    static func applyEdgeTweaks(_ src: CGImage,
                                 offset: Double,
                                 feather: Double,
                                 threshold: Double) -> CGImage? {
        if abs(offset) < 0.01 && feather < 0.01 && threshold < 0.001 { return nil }
        let source = CIImage(cgImage: src)
        let extent = source.extent

        // 1. Extract the alpha channel as a standalone grayscale mask (A → RGB and A).
        let extract = CIFilter.colorMatrix()
        extract.inputImage = source
        extract.rVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        extract.gVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        extract.bVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        extract.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        var mask = extract.outputImage?.cropped(to: extent) ?? source

        // 2. Morphology on the mask only.
        if abs(offset) >= 0.01 {
            let name = offset > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum"
            mask = mask.applyingFilter(name, parameters: [kCIInputRadiusKey: abs(offset)])
                .cropped(to: extent)
        }

        // 3. Feather = gaussian blur on the mask only.
        if feather >= 0.01 {
            mask = mask.applyingGaussianBlur(sigma: feather).cropped(to: extent)
        }

        // 4. Threshold remap on the mask.
        if threshold >= 0.001 {
            let slope = CGFloat(1.0 / max(0.01, 1.0 - threshold))
            let bias = CGFloat(-threshold * Double(slope))
            let tf = CIFilter.colorMatrix()
            tf.inputImage = mask
            tf.rVector = CIVector(x: slope, y: 0, z: 0, w: 0)
            tf.gVector = CIVector(x: 0, y: slope, z: 0, w: 0)
            tf.bVector = CIVector(x: 0, y: 0, z: slope, w: 0)
            tf.aVector = CIVector(x: 0, y: 0, z: 0, w: slope)
            tf.biasVector = CIVector(x: bias, y: bias, z: bias, w: bias)
            if let out = tf.outputImage { mask = out.cropped(to: extent) }
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = mask
            clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
            clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
            if let out = clamp.outputImage { mask = out.cropped(to: extent) }
        }

        // 5. Rebuild: opaque RGB from original + new alpha from mask (via blend-with-mask).
        let opaqueMtx = CIFilter.colorMatrix()
        opaqueMtx.inputImage = source
        opaqueMtx.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        opaqueMtx.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        opaqueMtx.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        opaqueMtx.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        opaqueMtx.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let opaque = opaqueMtx.outputImage?.cropped(to: extent) ?? source

        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        let result = opaque.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask
        ])

        return LayerRenderer.ciContext.createCGImage(result, from: extent)
    }

    /// Apply edge-cleanup operations (morphology / feather / threshold) to a
    /// grayscale layer mask in SOURCE pixel space. v0.4 split: cutouts now
    /// live on `layer.mask` rather than baked into the smart source alpha,
    /// so the edge sliders that used to act on source alpha now act on the
    /// mask instead. Works in source coords so a "5px feather" is consistent
    /// regardless of how the smart object is placed on the canvas.
    static func processMaskEdges(_ mask: CGImage,
                                  offset: Double,
                                  feather: Double,
                                  threshold: Double) -> CGImage? {
        if abs(offset) < 0.01 && feather < 0.01 && threshold < 0.001 { return nil }
        var ci = CIImage(cgImage: mask)
        let extent = ci.extent

        if abs(offset) >= 0.01 {
            // Positive = grow the visible (white) region; negative = shrink.
            let name = offset > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum"
            ci = ci.applyingFilter(name, parameters: [kCIInputRadiusKey: abs(offset)])
                .cropped(to: extent)
        }
        if feather >= 0.01 {
            ci = ci.applyingGaussianBlur(sigma: feather).cropped(to: extent)
        }
        if threshold >= 0.001 {
            // Linear remap: pixels below `threshold` go to 0, above go up to 1.
            // Hardens the mask edge so feathered output reads as crisper.
            let slope = CGFloat(1.0 / max(0.01, 1.0 - threshold))
            let bias = CGFloat(-threshold * Double(slope))
            let tf = CIFilter.colorMatrix()
            tf.inputImage = ci
            tf.rVector = CIVector(x: slope, y: 0, z: 0, w: 0)
            tf.gVector = CIVector(x: 0, y: slope, z: 0, w: 0)
            tf.bVector = CIVector(x: 0, y: 0, z: slope, w: 0)
            tf.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            tf.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
            if let out = tf.outputImage { ci = out.cropped(to: extent) }
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = ci
            clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
            clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
            if let out = clamp.outputImage { ci = out.cropped(to: extent) }
        }
        return LayerRenderer.ciContext.createCGImage(ci, from: extent)
    }

    /// Rasterize a source-space mask through the SAME placement transform as
    /// `rasterize` uses for the photo, so the resulting canvas-sized grayscale
    /// mask aligns with the placed photo regardless of scale, rotation, flip,
    /// or center position. White outside the photo's transformed footprint
    /// (effectively unchanged) — actual hiding for the empty canvas region is
    /// handled by the photo's own alpha channel during composite.
    static func rasterizeMask(_ mask: CGImage, smart: SmartSource, canvas: CGSize) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        guard let ctx = CGContext(data: nil,
                                  width: Int(canvas.width),
                                  height: Int(canvas.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // White outside the photo so the renderer's SourceIn step leaves the
        // empty canvas regions alone — they're already alpha=0 from the photo
        // and don't need the mask to hide them again.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvas))

        ctx.translateBy(x: CGFloat(smart.centerX), y: canvas.height - CGFloat(smart.centerY))
        ctx.rotate(by: -CGFloat(smart.rotationDeg) * .pi / 180)
        let sx = CGFloat(smart.scaleX) * (smart.flipH ? -1 : 1)
        let sy = CGFloat(smart.scaleY) * (smart.flipV ? -1 : 1)
        ctx.scaleBy(x: sx, y: sy)
        let w = CGFloat(mask.width), h = CGFloat(mask.height)
        ctx.draw(mask, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage()
    }

    /// Compute a fit-to-canvas scale with margin so the dropped image doesn't overflow.
    static func initialTransform(sourceSize: CGSize, canvas: CGSize, margin: CGFloat = 0.9) -> (scale: Double, cx: Double, cy: Double) {
        let s = min((canvas.width * margin) / sourceSize.width,
                    (canvas.height * margin) / sourceSize.height, 1.0)
        return (Double(s), Double(canvas.width / 2), Double(canvas.height / 2))
    }
}

/// Decode an image from a file URL plus capture the bytes for snapshotting. Works for
/// everything ImageIO can decode on macOS (PNG, JPEG, HEIC, WebP 14+, TIFF, GIF, BMP).
struct LoadedImage: Sendable {
    let cgImage: CGImage
    let data: Data
    let format: String
}

enum SmartImageLoader {
    static func load(from url: URL) -> LoadedImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cg = SmartObjectEngine.decode(data) else { return nil }
        let fmt = (url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased())
        return LoadedImage(cgImage: cg, data: data, format: fmt)
    }
}

/// Watches a file path for changes (e.g. user edits the source in external editor and saves).
/// Uses DispatchSource for real change events; re-opens the fd after atomic writes (rename).
@MainActor
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var checkTimer: DispatchSourceTimer?
    private var lastModified: Date?
    private let path: String
    private let onChange: @MainActor () -> Void

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
        installDispatch()
        installFallbackTimer()
    }

    deinit {
        source?.cancel()
        if fileDescriptor >= 0 { close(fileDescriptor) }
        checkTimer?.cancel()
    }

    private func installDispatch() {
        source?.cancel()
        if fileDescriptor >= 0 { close(fileDescriptor); fileDescriptor = -1 }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd
        let q = DispatchQueue.main
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: q)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            self.onChange()
            // If the file was replaced atomically, re-open.
            self.installDispatch()
        }
        s.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 { close(self.fileDescriptor); self.fileDescriptor = -1 }
        }
        s.resume()
        source = s
    }

    /// Fallback poller for sandbox edge cases (500ms mtime check). Cheap — stat only.
    private func installFallbackTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let attrs = try? FileManager.default.attributesOfItem(atPath: self.path)
            if let mod = attrs?[.modificationDate] as? Date {
                if let prev = self.lastModified, mod != prev {
                    self.onChange()
                }
                self.lastModified = mod
            }
        }
        t.resume()
        checkTimer = t
    }
}
