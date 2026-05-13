import Foundation
import AppKit
import CoreGraphics
import CoreImage

/// Drives a generative fill operation against a layer and an optional rectangular
/// selection. Produces a new image that's blended into the layer's smart source.
@MainActor
enum GenerativeFillCoordinator {
    /// Run a generative fill, Photoshop-style:
    /// - Sends the *composited* document (all visible layers below + active) as
    ///   model context, so the fill harmonizes with surrounding lighting/content.
    /// - Returns the result on a NEW raster layer placed above the active one,
    ///   leaving the source untouched (non-destructive).
    static func fill(store: DocumentStore,
                      mode: GenerativeFillMode = .generate,
                      prompt: String,
                      service: GenerativeFillService,
                      progress: @MainActor @escaping (String) -> Void = { _ in }) async throws {
        guard let activeLayer = store.activeLayer else {
            throw GenerativeFillError.predictionFailed("No active layer")
        }

        // 1. Build the model's context image and the mask. Expand mode runs a
        //    specialized outpaint pipeline; everything else keeps the existing
        //    selection-or-full-canvas behavior.
        let canvas = store.canvasSize
        let context: CGImage
        let mask: CGImage
        if mode == .expand {
            // Default: pre-fill the empty bands with stretched edge texture
            // so the model has strong priors to "continue" rather than
            // freedom to invent. Even mask-aware backends (FLUX-Fill,
            // Replicate flux-fill-dev) hallucinate subjects — including
            // faces — when the bands arrive transparent and the prompt is
            // generic. A service can opt back into bare-context by
            // overriding needsPrepFill = false, but the protocol default is
            // true now. preferredInputSize != nil forces prep-fill too
            // (the tiled SD path needs real content in each tile).
            let needsPrepFill = service.preferredInputSize != nil || service.needsPrepFill
            if needsPrepFill {
                let prepared = try buildExpandInput(store: store, layer: activeLayer)
                context = prepared.image
                mask = prepared.mask
                tlog("Generative Fill (Expand prep): layer bounds \(Int(prepared.layerBounds.width))x\(Int(prepared.layerBounds.height)) inside \(Int(canvas.width))x\(Int(canvas.height))")
            } else {
                // Mask-aware backend: send the bare composite + a clean mask.
                guard let composed = LayerRenderer.composite(store: store) else {
                    throw GenerativeFillError.predictionFailed("Could not composite document")
                }
                let bounds = try expandLayerBounds(store: store, layer: activeLayer)
                context = composed
                mask = buildExpandMaskOnly(canvas: canvas, layerBounds: bounds)
                tlog("Generative Fill (Expand bare): layer bounds \(Int(bounds.width))x\(Int(bounds.height)) inside \(Int(canvas.width))x\(Int(canvas.height)) — sending unfilled context to mask-aware backend")
            }
        } else {
            guard let composed = LayerRenderer.composite(store: store) else {
                throw GenerativeFillError.predictionFailed("Could not composite document")
            }
            context = composed
            // Soft selection mask wins over the bbox rect — gives the model
            // feathered fill edges that smoothly blend with the surrounding
            // pixels instead of cutting hard at a rectangle.
            if let soft = store.selectionMask {
                mask = buildCanvasMask(canvas: canvas, selectionMask: soft)
            } else {
                mask = buildCanvasMask(canvas: canvas, selectionDoc: store.selectionRect)
            }
        }

        tlog("Generative Fill: starting (mode=\(mode), canvas=\(Int(canvas.width))x\(Int(canvas.height)), selection=\(store.selectionRect.map { "\(Int($0.width))x\(Int($0.height))@(\(Int($0.minX)),\(Int($0.minY)))" } ?? "none"))")
        store.generativeProgress = "Submitting…"
        progress("Submitting…")
        defer { store.generativeProgress = nil }
        store.checkpoint("Generative Fill")

        dumpDebugImage(context, name: "expand-context")
        dumpDebugImage(mask, name: "expand-mask")

        let fillOnly: CGImage
        if mode == .expand, let tileSize = service.preferredInputSize {
            // Backends that internally rescale to a fixed size (Local SD → 512²)
            // can't outpaint a non-square canvas without aspect distortion. Run
            // one tile per band edge at native resolution and composite the
            // band-only portions onto a transparent canvas.
            let bounds = (try buildExpandInput(store: store, layer: activeLayer)).layerBounds
            fillOnly = try await runExpandTiled(
                contextImage: context, canvasMask: mask, layerBounds: bounds,
                canvas: canvas, tileSize: tileSize,
                service: service, prompt: prompt
            ) { msg in
                Task { @MainActor in
                    store.generativeProgress = msg
                    progress(msg)
                }
            }
        } else {
            let result = try await service.fill(image: context, mask: mask, prompt: prompt) { msg in
                Task { @MainActor in
                    store.generativeProgress = msg
                    progress(msg)
                }
            }
            tlog("Generative Fill: model returned \(result.width)x\(result.height)")
            progress("Compositing…")
            dumpDebugImage(result, name: "expand-result-raw")
            let resized = resize(result, to: canvas) ?? result
            // Let the model regenerate the FULL canvas (mask-aware backends
            // handle preservation internally — same VAE pass as the bands so
            // there's no inter-region color drift inside the model output).
            // Then, *after* generation, bake the band mask onto the result's
            // alpha channel so the new layer is transparent in the original
            // area and the layer underneath continues to contribute. This is
            // the "full regen + post-hoc alpha" pattern the user asked for —
            // simpler and more predictable than feathered clipping.
            fillOnly = clipToMask(resized, mask: mask)
        }
        dumpDebugImage(fillOnly, name: "expand-fillOnly")

        // 5. Wrap it as a new smart layer placed above the active one.
        guard let png = LayerSnapshot.encodePNG(fillOnly) else { throw GenerativeFillError.encodeFailed }
        let smart = SmartSource(
            sourcePath: nil,
            sourceBytes: png,
            sourceFormat: "png",
            pixelWidth: fillOnly.width,
            pixelHeight: fillOnly.height,
            centerX: Double(canvas.width / 2),
            centerY: Double(canvas.height / 2),
            scaleX: 1, scaleY: 1
        )
        let new = PXLayer(name: "Generative Fill", kind: .raster)
        new.smart = smart

        // Insert above the active layer (active = selected; layers array is bottom→top).
        if let activeIdx = store.layers.firstIndex(where: { $0.id == activeLayer.id }) {
            store.layers.insert(new, at: activeIdx + 1)
        } else {
            store.layers.append(new)
        }
        store.activeLayerID = new.id
        store.invalidate()
        tlog("Generative Fill → new layer '\(new.name)' (\(fillOnly.width)x\(fillOnly.height), \(png.count) bytes)")
    }

    /// Build a canvas mask from a soft (alpha-graded) selection mask.
    /// Black background + the mask drawn on top, in the same RGBA8 sRGB
    /// format as the bbox-rect path. CGImage memory rows are doc top-down
    /// in both cases, so byte layout matches what every backend already
    /// expects from `buildCanvasMask(canvas:selectionDoc:)`.
    private static func buildCanvasMask(canvas: CGSize, selectionMask: CGImage) -> CGImage {
        let w = Int(canvas.width), h = Int(canvas.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // No Y-flip needed: ctx.draw preserves the image's row order, and the
        // soft mask is already in doc top-down memory layout from the
        // SelectionTools pipeline (rasterizeMask / featherMask / refineEdgeMask).
        ctx.draw(selectionMask, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private static func buildCanvasMask(canvas: CGSize, selectionDoc: CGRect?) -> CGImage {
        let w = Int(canvas.width), h = Int(canvas.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let r = selectionDoc {
            // doc top-down → cgcontext y-up: flip Y.
            let y = canvas.height - r.maxY
            let rect = CGRect(x: r.minX, y: y, width: r.width, height: r.height)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect)
        } else {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        return ctx.makeImage()!
    }

    private static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        // Always re-render through sRGB / premultipliedLast (RGBA8). Even when
        // dimensions already match the target, model outputs sometimes carry
        // unusual color spaces / alpha modes that fail PNG encoding later.
        // Forcing the redraw normalizes the format.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    /// Apply a Gaussian blur to a mask so the binary on/off boundary
    /// becomes a soft alpha gradient over `radius` pixels. Used in Expand
    /// mode to hide the VAE-roundtrip seam where generated bands meet the
    /// pristine original layer underneath. Without this, even a 1-pixel
    /// VAE drift in color reads as a hard line at the mask edge.
    private static func featherMask(_ mask: CGImage, radius: Double) -> CGImage {
        let ci = CIImage(cgImage: mask)
        let blurred = ci.applyingGaussianBlur(sigma: radius).cropped(to: ci.extent)
        return LayerRenderer.ciContext.createCGImage(blurred, from: ci.extent) ?? mask
    }

    /// Keep only the white-mask regions of `image`; the rest becomes
    /// transparent. Direct per-pixel alpha baking — no CGContext.clip,
    /// no CIBlendWithMask. Both of those have unpredictable interactions
    /// with various color spaces / alpha modes from the model's PNG output.
    /// This reads pixel bytes directly: output RGB = input RGB, output alpha
    /// = mask luminance.
    private static func clipToMask(_ image: CGImage, mask: CGImage) -> CGImage {
        let w = image.width, h = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        // 1. Render image into a known RGBA8 buffer.
        let bytesPerRow = w * 4
        var imageBytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let imageCtx = CGContext(
            data: &imageBytes, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        imageCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 2. Render mask into a known 8-bit grayscale buffer (luminance).
        let grayCS = CGColorSpaceCreateDeviceGray()
        var maskBytes = [UInt8](repeating: 0, count: w * h)
        guard let maskCtx = CGContext(
            data: &maskBytes, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w, space: grayCS,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return image }
        maskCtx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 3. Bake mask luminance into the image's alpha channel, premultiplying
        //    RGB to match `premultipliedLast` so alpha-respecting consumers
        //    (PNG encode, AppKit drawing) render correctly.
        for i in 0..<(w * h) {
            let alpha = maskBytes[i]
            let af = Float(alpha) / 255.0
            let bi = i * 4
            imageBytes[bi]     = UInt8(Float(imageBytes[bi])     * af)
            imageBytes[bi + 1] = UInt8(Float(imageBytes[bi + 1]) * af)
            imageBytes[bi + 2] = UInt8(Float(imageBytes[bi + 2]) * af)
            imageBytes[bi + 3] = alpha
        }

        // 4. Build a new CGImage from the baked bytes.
        guard let outCtx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        // Copy raw bytes into the output context's buffer via a CGImage
        // round-trip. (Faster path: CGImage from bytes via dataProvider.)
        guard let provider = CGDataProvider(data: Data(imageBytes) as CFData),
              let baked = CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return image }
        outCtx.draw(baked, in: CGRect(x: 0, y: 0, width: w, height: h))
        return outCtx.makeImage() ?? image
    }

    /// White rect on black, in source-image pixel coords. If no selection, full white (= regenerate everything).
    private static func buildMask(sourceSize: CGSize,
                                   selectionDoc: CGRect?,
                                   smart: SmartSource,
                                   canvas: CGSize) -> CGImage {
        let w = Int(sourceSize.width), h = Int(sourceSize.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        if let docRect = selectionDoc {
            // doc → source-image coords. The smart transform places the source
            // centered at smart.center with smart.scale. So a doc point P maps to
            // source point: (P - center) / scale + sourceSize/2
            let sx = max(0.001, smart.scaleX), sy = max(0.001, smart.scaleY)
            let imgX1 = (docRect.minX - smart.centerX) / sx + sourceSize.width / 2
            let imgY1Top = (docRect.minY - smart.centerY) / sy + sourceSize.height / 2
            let imgX2 = (docRect.maxX - smart.centerX) / sx + sourceSize.width / 2
            let imgY2Top = (docRect.maxY - smart.centerY) / sy + sourceSize.height / 2
            // Source image space here is top-down; CGContext is bottom-up so flip Y.
            let imgY1 = sourceSize.height - imgY2Top
            let imgY2 = sourceSize.height - imgY1Top
            let rect = CGRect(x: imgX1, y: imgY1, width: imgX2 - imgX1, height: imgY2 - imgY1)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(origin: .zero, size: sourceSize))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect.intersection(CGRect(origin: .zero, size: sourceSize)))
        } else {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: sourceSize))
        }
        return ctx.makeImage()!
    }

    /// Tile-around-seam outpainting for backends with a fixed input size.
    /// One tile per band edge (left / right / top / bottom). Each tile is
    /// `tileSize` in canvas pixels, positioned so it covers the band plus
    /// adjacent image overlap. Result tiles are clipped via the canvas-space
    /// mask and drawn onto a transparent canvas-sized output.
    private static func runExpandTiled(
        contextImage: CGImage,
        canvasMask: CGImage,
        layerBounds: CGRect,
        canvas: CGSize,
        tileSize: CGSize,
        service: GenerativeFillService,
        prompt: String,
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> CGImage {
        let tw = tileSize.width, th = tileSize.height
        // Layer bounds are in top-down doc coords; tile rects are also top-down.
        // Each tile is placed so the band sits along one edge of the tile and
        // the remainder is image overlap.
        var tiles: [(rect: CGRect, label: String)] = []
        let bandThreshold: CGFloat = 8
        let canvasRect = CGRect(origin: .zero, size: canvas)

        // Generate vertical tile y-positions covering [0, canvas.height] using
        // tiles of height `th`. For canvases <= th, one tile centered.
        // For larger canvases, anchor first tile at y=0 and last at y=canvas.h-th,
        // adding intermediate tiles every (th/2) for some overlap.
        // Distribute slots evenly so the first starts at 0, the last at
        // canvas-tile, and intermediate steps don't exceed `tile - minOverlap`.
        func slots(canvas: CGFloat, tile: CGFloat, minOverlap: CGFloat = 64) -> [CGFloat] {
            if canvas <= tile { return [max(0, (canvas - tile) / 2)] }
            let span = canvas - tile
            let maxStep = max(1, tile - minOverlap)
            let n = max(2, Int(ceil(span / maxStep)) + 1)
            let step = span / CGFloat(n - 1)
            return (0..<n).map { CGFloat($0) * step }
        }
        let vSlotsArr = slots(canvas: canvas.height, tile: th)
        let hSlotsArr = slots(canvas: canvas.width, tile: tw)
        func verticalSlots() -> [CGFloat] { vSlotsArr }
        func horizontalSlots() -> [CGFloat] { hSlotsArr }
        let vSlots = verticalSlots()
        let hSlots = horizontalSlots()

        if layerBounds.minX > bandThreshold {
            for (i, vy) in vSlots.enumerated() {
                tiles.append((rect: CGRect(x: 0, y: vy, width: tw, height: th)
                                .intersection(canvasRect),
                              label: "left-\(i)"))
            }
        }
        if (canvas.width - layerBounds.maxX) > bandThreshold {
            for (i, vy) in vSlots.enumerated() {
                tiles.append((rect: CGRect(x: max(0, canvas.width - tw), y: vy, width: tw, height: th)
                                .intersection(canvasRect),
                              label: "right-\(i)"))
            }
        }
        if layerBounds.minY > bandThreshold {
            for (i, hx) in hSlots.enumerated() {
                tiles.append((rect: CGRect(x: hx, y: 0, width: tw, height: th)
                                .intersection(canvasRect),
                              label: "top-\(i)"))
            }
        }
        if (canvas.height - layerBounds.maxY) > bandThreshold {
            for (i, hx) in hSlots.enumerated() {
                tiles.append((rect: CGRect(x: hx, y: max(0, canvas.height - th), width: tw, height: th)
                                .intersection(canvasRect),
                              label: "bottom-\(i)"))
            }
        }
        tlog("Expand tiles: \(tiles.count) (\(tiles.map(\.label).joined(separator: ", ")))")

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let outCtx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw GenerativeFillError.predictionFailed("Could not allocate tiled output context") }
        outCtx.interpolationQuality = .high

        // Compute fade flags per tile: feather toward neighbors that share the band.
        let labels = tiles.map(\.label)
        func neighbors(_ label: String) -> (top: Bool, bottom: Bool, left: Bool, right: Bool) {
            let parts = label.split(separator: "-")
            guard parts.count == 2, let idx = Int(parts[1]) else { return (false, false, false, false) }
            let band = String(parts[0])
            let prev = labels.contains("\(band)-\(idx - 1)")
            let next = labels.contains("\(band)-\(idx + 1)")
            if band == "left" || band == "right" {
                return (top: prev, bottom: next, left: false, right: false)
            } else {
                return (top: false, bottom: false, left: prev, right: next)
            }
        }
        let fadeSize = Int((min(tw, th) - 284) / 2) // half the tile-to-tile overlap

        for (index, tile) in tiles.enumerated() {
            progress("Tile \(index + 1) of \(tiles.count) (\(tile.label))…")
            guard let tileImage = cropTopDown(contextImage, to: tile.rect),
                  let tileMask = cropTopDown(canvasMask, to: tile.rect) else {
                tlog("Expand tile \(tile.label): crop failed")
                continue
            }
            dumpDebugImage(tileImage, name: "expand-tile-\(tile.label)-in")
            dumpDebugImage(tileMask, name: "expand-tile-\(tile.label)-mask")

            let tileResult = try await service.fill(image: tileImage, mask: tileMask, prompt: prompt, progress: progress)
            dumpDebugImage(tileResult, name: "expand-tile-\(tile.label)-result")

            let resized = resize(tileResult, to: tile.rect.size) ?? tileResult
            let clipped = clipToMask(resized, mask: tileMask)
            // Cross-fade tile edges that share a band with another tile so the
            // hard tile boundary is softened where two tiles overlap.
            let f = neighbors(tile.label)
            let faded = applyTileFade(clipped,
                                       fadeTop: f.top, fadeBottom: f.bottom,
                                       fadeLeft: f.left, fadeRight: f.right,
                                       fadeSize: fadeSize)
            dumpDebugImage(faded, name: "expand-tile-\(tile.label)-clipped")

            let drawRect = CGRect(x: tile.rect.minX,
                                  y: canvas.height - tile.rect.maxY,
                                  width: tile.rect.width,
                                  height: tile.rect.height)
            outCtx.draw(faded, in: drawRect)
        }

        guard let combined = outCtx.makeImage() else {
            throw GenerativeFillError.predictionFailed("Could not finalize tiled output")
        }
        return combined
    }

    /// Multiply an image's premultiplied-alpha by a vertical/horizontal fade
    /// gradient. Used to cross-fade overlapping tiles so adjacent tile bodies
    /// merge instead of producing a hard seam.
    private static func applyTileFade(_ image: CGImage,
                                       fadeTop: Bool, fadeBottom: Bool,
                                       fadeLeft: Bool, fadeRight: Bool,
                                       fadeSize: Int) -> CGImage {
        let w = image.width, h = image.height
        let bytesPerRow = w * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * h)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &rgba, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let f = max(1, fadeSize)
        for y in 0..<h {
            for x in 0..<w {
                var fx = 1.0, fy = 1.0
                if fadeTop && y < f { fy = min(fy, Double(y) / Double(f)) }
                if fadeBottom && y >= h - f { fy = min(fy, Double(h - 1 - y) / Double(f)) }
                if fadeLeft && x < f { fx = min(fx, Double(x) / Double(f)) }
                if fadeRight && x >= w - f { fx = min(fx, Double(w - 1 - x) / Double(f)) }
                let factor = fx * fy
                let i = y * bytesPerRow + x * 4
                rgba[i]     = UInt8(Double(rgba[i])     * factor)
                rgba[i + 1] = UInt8(Double(rgba[i + 1]) * factor)
                rgba[i + 2] = UInt8(Double(rgba[i + 2]) * factor)
                rgba[i + 3] = UInt8(Double(rgba[i + 3]) * factor)
            }
        }
        return ctx.makeImage() ?? image
    }

    /// 8-bit per-channel pseudo-random noise canvas. Cheap, no dependencies.
    /// Uses a simple LCG seeded by a fresh UInt64 each call so successive
    /// generations vary.
    private static func makeGaussianNoise(width: Int, height: Int) -> CGImage {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        var state = UInt64.random(in: 1..<UInt64.max)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            // xorshift64
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let r = UInt8((state &* 6364136223846793005) >> 56)
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let g = UInt8((state &* 6364136223846793005) >> 56)
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let b = UInt8((state &* 6364136223846793005) >> 56)
            bytes[i] = r
            bytes[i + 1] = g
            bytes[i + 2] = b
            bytes[i + 3] = 255
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    /// Crop a CGImage using a top-down (PNG-style) rect. CGImage's own
    /// `cropping(to:)` uses the image's native coord space, which for our
    /// PNG-encoded inputs is top-down.
    private static func cropTopDown(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let r = CGRect(x: floor(rect.minX), y: floor(rect.minY),
                       width: floor(rect.width), height: floor(rect.height))
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard r.width > 0, r.height > 0 else { return nil }
        return image.cropping(to: r)
    }

    private static func dumpDebugImage(_ image: CGImage, name: String) {
        guard let data = LayerSnapshot.encodePNG(image) else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tiramisu-\(name).png")
        try? data.write(to: url)
        tlog("dump: \(name) → \(url.path) (\(image.width)x\(image.height), \(data.count) bytes)")
    }

    /// Compute layer bounds in canvas top-down coords for Expand mode, without
    /// doing any of the heavy diffusion-fill prep work.
    private static func expandLayerBounds(store: DocumentStore, layer: PXLayer) throws -> CGRect {
        guard let smart = layer.smart else {
            throw GenerativeFillError.predictionFailed(
                "Expand needs a Smart Object. Re-add the image as a Smart Object (Place Image…, Paste, or drag-drop).")
        }
        let canvas = store.canvasSize
        let lw = max(1.0, Double(smart.pixelWidth) * smart.scaleX)
        let lh = max(1.0, Double(smart.pixelHeight) * smart.scaleY)
        let bounds = CGRect(x: smart.centerX - lw / 2,
                            y: smart.centerY - lh / 2,
                            width: lw, height: lh)
        if bounds.contains(CGRect(origin: .zero, size: canvas).insetBy(dx: -1, dy: -1)) {
            throw GenerativeFillError.predictionFailed(
                "Active layer fills the canvas — no empty bands to outpaint.")
        }
        return bounds
    }

    /// Build the band-only mask for Expand mode. White outside the layer
    /// (= inpaint these regions), black inside the preserve rect.
    ///
    /// The preserve rect is pulled INWARD from each band-edge by a small
    /// fixed overlap so FLUX-Fill has a few pixels of transition zone to
    /// blend the band content with existing layer pixels. We only inset on
    /// edges that have a real band (so we don't eat into edges that are
    /// already aligned with the canvas). Cap the inset at a fraction of the
    /// band width on that edge so it never invades the layer for tiny bands.
    private static func buildExpandMaskOnly(canvas: CGSize,
                                              layerBounds: CGRect,
                                              overlapPx: CGFloat = 16) -> CGImage {
        let w = Int(canvas.width), h = Int(canvas.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h,
                             bitsPerComponent: 8, bytesPerRow: 0, space: space,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Per-edge overlap, only when there's a real band on that edge.
        let bandL = layerBounds.minX
        let bandR = canvas.width - layerBounds.maxX
        let bandT = layerBounds.minY
        let bandB = canvas.height - layerBounds.maxY
        let insetL: CGFloat = bandL > 1 ? min(overlapPx, max(0, bandL * 0.5)) : 0
        let insetR: CGFloat = bandR > 1 ? min(overlapPx, max(0, bandR * 0.5)) : 0
        let insetT: CGFloat = bandT > 1 ? min(overlapPx, max(0, bandT * 0.5)) : 0
        let insetB: CGFloat = bandB > 1 ? min(overlapPx, max(0, bandB * 0.5)) : 0
        let preserveRect = CGRect(
            x: layerBounds.minX + insetL,
            y: canvas.height - layerBounds.maxY + insetB,
            width: layerBounds.width - insetL - insetR,
            height: layerBounds.height - insetT - insetB
        )
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(preserveRect)
        return ctx.makeImage()!
    }

    private struct ExpandInput {
        let image: CGImage      // canvas-size context with edge-padded empty regions
        let mask: CGImage       // canvas-size mask (white in regions to outpaint)
        let layerBounds: CGRect // layer's bounds in canvas coords (top-down)
    }

    /// Prepare image + mask for outpainting. Detects the active layer's bounds
    /// in the canvas, edge-pads the source image into the empty regions so the
    /// model has plausible texture to refine instead of black, and builds a
    /// mask that's white in those empty regions (with feather into the layer).
    private static func buildExpandInput(store: DocumentStore, layer: PXLayer) throws -> ExpandInput {
        guard let smart = layer.smart else {
            throw GenerativeFillError.predictionFailed("Expand needs a Smart Object. The active layer '\(layer.name)' was added as a baked raster (probably via an old Place Image…). Re-add the image with File → Place Image… (now creates Smart Objects), Paste Image as New Layer (⌘⇧V), or drag-drop from Finder, and try again.")
        }
        guard let source = SmartObjectEngine.loadSource(smart) else {
            throw GenerativeFillError.predictionFailed("Could not decode smart layer source bytes — file may be missing or corrupt.")
        }
        let canvas = store.canvasSize
        // Layer bounds in canvas pixel coords (top-down). Rotation is ignored
        // for v1 — outpainting a rotated layer is rare and mask geometry gets messy.
        let lw = max(1.0, Double(smart.pixelWidth) * smart.scaleX)
        let lh = max(1.0, Double(smart.pixelHeight) * smart.scaleY)
        let lx = smart.centerX - lw / 2
        let ly = smart.centerY - lh / 2
        let layerBounds = CGRect(x: lx, y: ly, width: lw, height: lh)

        let canvasRect = CGRect(origin: .zero, size: canvas)
        tlog("Expand geometry: canvas=\(Int(canvas.width))x\(Int(canvas.height)), layer=(\(Int(layerBounds.minX)),\(Int(layerBounds.minY)) \(Int(layerBounds.width))x\(Int(layerBounds.height)))")
        if layerBounds.contains(canvasRect.insetBy(dx: -1, dy: -1)) {
            throw GenerativeFillError.predictionFailed(
                "Active layer already fills the canvas — there are no empty bands to outpaint into.\n\n" +
                "To create empty bands:\n" +
                "  • Increase the canvas size (toolbar → canvas size menu, e.g. pick a wider preset), or\n" +
                "  • Scale the layer smaller using the transform handles on the canvas.\n\n" +
                "Then run AI → Generative Fill (⌘⇧G) again."
            )
        }
        // The layer can extend past the canvas (oversized image) — that's fine,
        // we'll just outpaint into whatever band areas remain inside the canvas.

        // 1) Context image. Inside the layer bounds we use the actual composite
        //    so the model has clear conditioning. Outside, we MIRROR the source
        //    into each empty band so the layer's edges naturally continue. The
        //    model i2i's the mirrored content into matching detail — much
        //    better than noise (which produces unrelated content) or solid
        //    edge-clamp (which locks into a flat color).
        guard let composed = LayerRenderer.composite(store: store) else {
            throw GenerativeFillError.predictionFailed("Could not composite document")
        }

        let cw = Int(canvas.width), ch = Int(canvas.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cw, height: ch,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw GenerativeFillError.predictionFailed("Could not allocate context") }
        ctx.interpolationQuality = .high

        let yFlipped = canvas.height - layerBounds.maxY
        let drawSourceRect = CGRect(x: layerBounds.minX, y: yFlipped,
                                     width: layerBounds.width, height: layerBounds.height)

        // ITERATIVE DIFFUSION FILL.
        //   pass 0: fill canvas with OPAQUE neutral gray, draw source on top.
        //           (Opaque seed is critical — gaussian-blurring transparent
        //           regions dilutes color via alpha, so the layer's edge
        //           colors never propagate. Opaque seed lets the blur spread
        //           the layer's edge colors smoothly outward each pass.)
        //   each pass: clamp + gaussian blur the canvas, then re-overdraw the sharp source.
        // Result: bands hold smooth gradients of the layer's edge colors, no
        // hard boundary at the seam, no flipped/duplicated structure.
        guard let initCtx = CGContext(data: nil, width: cw, height: ch,
                                       bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw GenerativeFillError.predictionFailed("Could not allocate diffusion context") }
        initCtx.interpolationQuality = .high
        initCtx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        initCtx.fill(canvasRect)
        initCtx.draw(source, in: drawSourceRect)
        var current: CGImage = initCtx.makeImage() ?? source

        let diffusionPasses = 8
        let perPassSigma: CGFloat = 50
        for _ in 0..<diffusionPasses {
            let blurredCI = CIImage(cgImage: current)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: perPassSigma)
                .cropped(to: canvasRect)
            guard let blurredCG = LayerRenderer.ciContext.createCGImage(blurredCI, from: canvasRect, format: .RGBA8, colorSpace: space) else { break }
            guard let nextCtx = CGContext(data: nil, width: cw, height: ch,
                                           bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { break }
            nextCtx.interpolationQuality = .high
            nextCtx.draw(blurredCG, in: canvasRect)
            nextCtx.draw(source, in: drawSourceRect)
            if let img = nextCtx.makeImage() { current = img }
        }
        ctx.draw(current, in: canvasRect)

        // Light noise overlay (10%) so the model has some texture to refine into detail.
        let noise = makeGaussianNoise(width: cw, height: ch)
        ctx.saveGState()
        ctx.setAlpha(0.10)
        ctx.draw(noise, in: canvasRect)
        ctx.restoreGState()

        // Clip to layer bounds, overdraw the SHARP composite (preserves the layer at full fidelity).
        let preserveCG = CGRect(x: layerBounds.minX,
                                y: canvas.height - layerBounds.maxY,
                                width: layerBounds.width,
                                height: layerBounds.height)
        ctx.saveGState()
        ctx.clip(to: preserveCG)
        ctx.draw(composed, in: canvasRect)
        ctx.restoreGState()
        guard let preparedImage = ctx.makeImage() else {
            throw GenerativeFillError.predictionFailed("Could not finalize prepared context")
        }

        // 2) Outpaint mask: white outside layerBounds (regions to outpaint),
        //    black inside the layer (preserve). The seam is feathered later by
        //    the gaussian blur in `clipToMask` at composite time — don't inset
        //    here, otherwise the inner edge of the image becomes "regenerate
        //    me" and the model paints over the original.
        guard let maskCtx = CGContext(data: nil, width: cw, height: ch,
                                       bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw GenerativeFillError.predictionFailed("Could not allocate mask context") }
        maskCtx.setFillColor(NSColor.white.cgColor)
        maskCtx.fill(CGRect(origin: .zero, size: canvas))
        let preserveRect = CGRect(
            x: layerBounds.minX,
            y: canvas.height - layerBounds.maxY,
            width: layerBounds.width,
            height: layerBounds.height
        )
        maskCtx.setFillColor(NSColor.black.cgColor)
        maskCtx.fill(preserveRect)
        guard let mask = maskCtx.makeImage() else {
            throw GenerativeFillError.predictionFailed("Could not finalize outpaint mask")
        }

        let coverage = (canvas.width * canvas.height - layerBounds.width * layerBounds.height) / (canvas.width * canvas.height)
        tlog("Expand mask: \(Int(coverage * 100))% white (regions to fill), preserve rect (CG-flipped y) = \(Int(preserveRect.minX)),\(Int(preserveRect.minY)) \(Int(preserveRect.width))x\(Int(preserveRect.height))")

        return ExpandInput(image: preparedImage, mask: mask, layerBounds: layerBounds)
    }

    /// Replace masked pixels in `original` with pixels from `generated`. Other
    /// pixels stay original. Soft-edged (gaussian blur on mask) for natural blend.
    private static func composite(original: CGImage, generated: CGImage, mask: CGImage) -> CGImage {
        let w = original.width, h = original.height
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        let src = CIImage(cgImage: original)
        // The generated image dimensions may differ; fit to source.
        var gen = CIImage(cgImage: generated)
        if gen.extent != extent {
            let sx = CGFloat(w) / gen.extent.width
            let sy = CGFloat(h) / gen.extent.height
            gen = gen.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        let m = CIImage(cgImage: mask)
            .applyingGaussianBlur(sigma: 6)
            .cropped(to: extent)
        let blended = gen.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: src,
            kCIInputMaskImageKey: m
        ])
        return LayerRenderer.ciContext.createCGImage(blended, from: extent) ?? original
    }
}
