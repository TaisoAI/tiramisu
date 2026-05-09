import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import AppKit

/// Pixel-level helpers for the v0.5 selection tools — Magic Wand (color
/// flood-fill), Smart Select (Vision foreground instance segmentation), and
/// Refine Edge (morphological expand / contract on an existing path).
///
/// Outputs are converted into doc-space CGPaths via `maskToPath`, so they
/// plug into `DocumentStore.setSelection(path:)` exactly like the lasso /
/// marquee tools. Doc convention: top-down y, origin at the canvas top-left.
@MainActor
enum SelectionTools {

    // MARK: - Magic Wand

    /// Flood-fill from `seed` (doc top-down coords) in `image` (canvas-
    /// resolution composite). Selects connected pixels whose RGB Euclidean
    /// distance to the seed color is within `tolerance` (0…1, normalized
    /// to the maximum sRGB distance √3). When `contiguous` is false, every
    /// pixel in the image within tolerance is selected, regardless of
    /// connectivity. Returns a canvas-resolution single-channel mask
    /// (255 = selected, 0 = not).
    static func floodFill(in image: CGImage,
                          seed: CGPoint,
                          tolerance: Double,
                          contiguous: Bool) -> CGImage? {
        let w = image.width, h = image.height
        let sx = Int(seed.x.rounded()), sy = Int(seed.y.rounded())
        guard sx >= 0, sx < w, sy >= 0, sy < h else { return nil }

        // Read pixels into RGBA8 sRGB. CGContext is bottom-up so a buffer
        // row index corresponds to (h - 1 - docY).
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bmInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space,
                                  bitmapInfo: bmInfo) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // CGContext memory is laid out top-down: memory row 0 = top of image,
        // row h-1 = bottom. Doc top-down y aligns with that directly, so a
        // doc click at (sx, sy) maps to byte index (sy * w + sx) * 4.
        // (Earlier code did h-1-sy thinking memory was bottom-up — confused
        // CG's bottom-up draw coords with the buffer's actual layout.)
        let seedI = (sy * w + sx) * 4
        let sr = Int(bytes[seedI])
        let sg = Int(bytes[seedI + 1])
        let sb = Int(bytes[seedI + 2])
        // tolerance is normalized [0,1] of the max sRGB Euclidean distance
        // (√3 · 255 ≈ 441). Squared once so the inner loop avoids sqrt.
        let maxDist = tolerance * 255.0 * sqrt(3.0)
        let maxDistSq = maxDist * maxDist

        var mask = [UInt8](repeating: 0, count: w * h)

        @inline(__always)
        func match(_ idx: Int) -> Bool {
            let dr = Int(bytes[idx])     - sr
            let dg = Int(bytes[idx + 1]) - sg
            let db = Int(bytes[idx + 2]) - sb
            let d2 = Double(dr*dr + dg*dg + db*db)
            return d2 <= maxDistSq
        }

        if contiguous {
            var stack: [(Int, Int)] = [(sx, sy)]
            mask[sy * w + sx] = 255
            while let (cx, cy) = stack.popLast() {
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = cx + dx, ny = cy + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let mi = ny * w + nx
                    if mask[mi] != 0 { continue }
                    if match(mi * 4) {
                        mask[mi] = 255
                        stack.append((nx, ny))
                    }
                }
            }
        } else {
            for row in 0..<h {
                let rowBase = row * w
                for col in 0..<w {
                    if match((rowBase + col) * 4) {
                        mask[rowBase + col] = 255
                    }
                }
            }
        }

        return makeGrayImage(width: w, height: h, bytes: mask)
    }

    // MARK: - Smart Select (Vision)

    /// Run Vision foreground-instance segmentation on `image`, identify the
    /// instance under `click` (doc top-down coords), and return its binary
    /// mask sized to `canvasSize`. Returns nil when the click lands on the
    /// background or when Vision finds no instances.
    static func smartSelectMask(in image: CGImage,
                                click: CGPoint,
                                canvasSize: CGSize) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch {
            tlog("smartSelect: vision request failed: \(error)")
            return nil
        }
        guard let obs = request.results?.first else {
            tlog("smartSelect: no instance observation")
            return nil
        }

        // Iterate the detected instances and find the one whose mask
        // covers the click pixel. This is more robust than sampling
        // `obs.instanceMask` directly because that buffer's resolution
        // and orientation can differ from the source image, leading to
        // mis-mapped clicks.
        let target = CGRect(origin: .zero, size: canvasSize)
        let cx = Int(click.x.rounded())
        let cy = Int(click.y.rounded())
        for idx in obs.allInstances {
            guard let cg = scaledInstanceMask(obs: obs, instances: [idx],
                                              handler: handler, target: target) else {
                continue
            }
            if maskCoversPixel(cg, x: cx, y: cy) {
                return cg
            }
        }
        tlog("smartSelect: click did not land inside any of \(obs.allInstances.count) instance(s)")
        return nil
    }

    private static func scaledInstanceMask(obs: VNInstanceMaskObservation,
                                           instances: IndexSet,
                                           handler: VNImageRequestHandler,
                                           target: CGRect) -> CGImage? {
        do {
            let buf = try obs.generateScaledMaskForImage(forInstances: instances, from: handler)
            let ci = CIImage(cvPixelBuffer: buf)
            let scaleX = target.width / max(1, ci.extent.width)
            let scaleY = target.height / max(1, ci.extent.height)
            let scaled = ci
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .cropped(to: target)
            return LayerRenderer.ciContext.createCGImage(scaled, from: target)
        } catch {
            tlog("smartSelect: generateScaledMaskForImage failed: \(error)")
            return nil
        }
    }

    /// True when the pixel at doc top-down (x, y) in `mask` is non-zero
    /// (i.e., inside the masked region). Used by Smart Select to test
    /// "did the click land inside this instance?". Treats anything > 50%
    /// alpha as inside; a soft mask edge near the cursor still counts.
    private static func maskCoversPixel(_ mask: CGImage, x: Int, y: Int) -> Bool {
        guard x >= 0, x < mask.width, y >= 0, y < mask.height else { return false }
        let crop = mask.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) ?? mask
        var bytes: [UInt8] = [0, 0, 0, 0]
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return bytes.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            // Vision masks are usually grayscale-with-alpha; treat any
            // bright/opaque sample as "inside".
            let bright = max(buf[0], buf[1], buf[2])
            return bright > 128 || buf[3] > 128
        }
    }

    // MARK: - Refine Edge

    /// Expand or contract a doc-space CGPath by `radiusPx` doc pixels.
    /// Positive `radius` = expand, negative = contract. Implemented via
    /// CIMorphology max/min on a rasterized mask, then re-extracted via
    /// `maskToPath`. Result is in doc top-down coords.
    static func refineEdge(_ path: CGPath,
                           radiusPx: Double,
                           canvasSize: CGSize) -> CGPath? {
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        guard let mask = rasterizeMask(path, canvasSize: canvasSize) else { return nil }

        let ci = CIImage(cgImage: mask)
        let r = abs(radiusPx)
        let f: CIFilter
        if radiusPx > 0 {
            let m = CIFilter.morphologyMaximum()
            m.inputImage = ci
            m.radius = Float(r)
            f = m
        } else if radiusPx < 0 {
            let m = CIFilter.morphologyMinimum()
            m.inputImage = ci
            m.radius = Float(r)
            f = m
        } else {
            return path
        }
        guard let out = f.outputImage else { return nil }
        let ext = CGRect(x: 0, y: 0, width: w, height: h)
        guard let processed = LayerRenderer.ciContext.createCGImage(
            out.cropped(to: ext), from: ext) else { return nil }
        return maskToPath(processed, canvasSize: canvasSize)
    }

    // MARK: - Mask → Path

    /// Convert a binary single-channel mask CGImage into a CGPath in doc
    /// top-down coords. Uses Vision's `VNDetectContoursRequest`, which
    /// returns contours in normalized [0,1] coords with origin at the
    /// bottom-left; we flip Y and scale to canvas pixels.
    static func maskToPath(_ mask: CGImage, canvasSize: CGSize) -> CGPath? {
        let req = VNDetectContoursRequest()
        req.contrastAdjustment = 1.0
        req.detectsDarkOnLight = false
        req.maximumImageDimension = max(Int(canvasSize.width), Int(canvasSize.height))
        let handler = VNImageRequestHandler(cgImage: mask, options: [:])
        do { try handler.perform([req]) } catch {
            tlog("maskToPath: contour request failed: \(error)")
            return nil
        }
        guard let obs = req.results?.first as? VNContoursObservation else { return nil }

        // Vision normalizedPath: x in [0,1], y in [0,1] origin bottom-left.
        // Doc top-down: x in [0, canvasW], y in [0, canvasH] origin top-left.
        // Compose: scale by (canvasW, -canvasH), then translate by (0, canvasH).
        var t = CGAffineTransform(scaleX: canvasSize.width, y: -canvasSize.height)
            .concatenating(CGAffineTransform(translationX: 0, y: canvasSize.height))

        let result = CGMutablePath()
        for contour in obs.topLevelContours {
            if let mapped = contour.normalizedPath.copy(using: &t) {
                result.addPath(mapped)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Rasterize a doc-space CGPath into a canvas-resolution binary mask
    /// (white = inside, black = outside). Inverse of `maskToPath`.
    static func rasterizeMask(_ path: CGPath, canvasSize: CGSize) -> CGImage? {
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // CG is bottom-up; doc paths are top-down. Flip the path the same
        // way maskToPath flips the result so a round-trip is identity.
        var flip = CGAffineTransform(scaleX: 1, y: -1)
            .concatenating(CGAffineTransform(translationX: 0, y: CGFloat(h)))
        guard let flipped = path.copy(using: &flip) else { return nil }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(flipped)
        ctx.fillPath()
        return ctx.makeImage()
    }

    // MARK: - Helpers

    private static func makeGrayImage(width w: Int, height h: Int, bytes: [UInt8]) -> CGImage? {
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        guard let buf = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h) else { return nil }
        bytes.withUnsafeBufferPointer { src in
            buf.update(from: src.baseAddress!, count: w * h)
        }
        return ctx.makeImage()
    }
}
