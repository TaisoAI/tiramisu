import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import Metal

/// All compositing goes through a Metal-backed CIContext for 4K responsiveness.
enum LayerRenderer {
    nonisolated(unsafe) static let ciContext: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: [
                .cacheIntermediates: true,
                .useSoftwareRenderer: false,
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any
            ])
        }
        return CIContext(options: [.cacheIntermediates: true])
    }()

    /// Per-layer CI cache keyed by a fingerprint of the layer's processing-relevant
    /// properties. Moving a smart layer by dx/dy only invalidates THAT layer, not
    /// others — which is the main perf win during drags.
    nonisolated(unsafe) private static var layerCache: [UUID: (fingerprint: Int, image: CIImage)] = [:]

    /// Composites all visible layers into a single CGImage at the document's resolution.
    @MainActor
    static func composite(store: DocumentStore) -> CGImage? {
        let size = store.canvasSize
        let extent = CGRect(origin: .zero, size: size)

        var accum: CIImage = solid(color: store.backgroundColor, extent: extent)

        for layer in store.layers where layer.visible {
            let fp = layerFingerprint(layer, canvasSize: size)
            let layerImg: CIImage
            if let cached = layerCache[layer.id], cached.fingerprint == fp {
                layerImg = cached.image
            } else if let rendered = render(layer: layer, canvasSize: size) {
                layerCache[layer.id] = (fp, rendered)
                layerImg = rendered
            } else {
                tlog("composite: skip layer '\(layer.name)' — render returned nil")
                continue
            }

            // For text layers, the rasterization is centered; apply the user's
            // anchor as a cheap translation here so dragging doesn't invalidate
            // the cached render.
            var tx = CGFloat(layer.offset.width)
            var ty = -CGFloat(layer.offset.height)
            if layer.kind == .text {
                tx += (CGFloat(layer.text.anchorX) - 0.5) * size.width
                ty -= (CGFloat(layer.text.anchorY) - 0.5) * size.height
            }
            let placed = layerImg
                .transformed(by: CGAffineTransform(translationX: tx, y: ty))
                .applyingOpacity(layer.opacity)
            accum = compositeBlend(top: placed, bottom: accum, mode: layer.blend)
        }
        // Trim the cache to current layer IDs so it doesn't grow forever.
        let liveIDs = Set(store.layers.map(\.id))
        layerCache = layerCache.filter { liveIDs.contains($0.key) }

        return ciContext.createCGImage(accum, from: extent)
    }

    /// Cheap hash of everything that would affect a layer's computed CI image.
    /// Excludes offset (added at composite time) and opacity/blend (applied at composite).
    private static func layerFingerprint(_ L: PXLayer, canvasSize: CGSize) -> Int {
        var h = Hasher()
        h.combine(L.kind)
        h.combine(Int(canvasSize.width)); h.combine(Int(canvasSize.height))
        // Per-type source
        switch L.kind {
        case .raster:
            if let s = L.smart {
                h.combine(s.sourcePath ?? "")
                h.combine(s.sourceBytes?.count ?? 0)
                h.combine(s.centerX); h.combine(s.centerY)
                h.combine(s.scaleX); h.combine(s.scaleY)
                h.combine(s.rotationDeg); h.combine(s.flipH); h.combine(s.flipV)
                h.combine(s.edgeOffset); h.combine(s.edgeFeather); h.combine(s.edgeThreshold)
            } else if let cg = L.raster {
                h.combine(ObjectIdentifier(cg))
            }
        case .text:
            h.combine(L.text.string); h.combine(L.text.fontName); h.combine(L.text.fontSize)
            h.combine(L.text.weight); h.combine(L.text.italic); h.combine(L.text.underline)
            h.combine(L.text.strikethrough); h.combine(L.text.uppercase)
            h.combine(L.text.alignment); h.combine(L.text.lineHeight); h.combine(L.text.tracking)
            h.combine(L.text.color.r); h.combine(L.text.color.g); h.combine(L.text.color.b)
            // Include the attributed text data so per-range color/bold/italic edits
            // invalidate the cached render. RTF for text is small (usually a few
            // KB), so hashing the full blob is cheap and catches any attribute
            // change — header stays identical when only run attributes flip.
            if let d = L.text.rtfData { h.combine(d) }
            // anchor excluded — it's applied as a translation at composite time so
            // dragging text doesn't invalidate the cache.
        case .gradient:
            let g = L.gradient
            h.combine(g.kind); h.combine(g.angle)
            h.combine(g.c1.r); h.combine(g.c1.g); h.combine(g.c1.b)
            h.combine(g.c2.r); h.combine(g.c2.g); h.combine(g.c2.b)
            h.combine(g.s1); h.combine(g.s2); h.combine(g.radius)
            h.combine(g.center.x); h.combine(g.center.y)
        case .solid:
            h.combine(L.solid.color.r); h.combine(L.solid.color.g); h.combine(L.solid.color.b)
        }
        // Filters / adjustments / relight / skin / styles
        let A = L.adjust; h.combine(A.brightness); h.combine(A.contrast); h.combine(A.exposure)
        h.combine(A.saturation); h.combine(A.warmth); h.combine(A.shadows); h.combine(A.highlights)
        h.combine(A.vibrance); h.combine(A.curve); h.combine(A.curveIntensity)
        for d in A.hsl.asDeltaTable { h.combine(d.h); h.combine(d.s); h.combine(d.l) }
        let F = L.filters; h.combine(F.blur); h.combine(F.noise); h.combine(F.noiseMono)
        h.combine(F.sharpen); h.combine(F.pixelate); h.combine(F.hueShift)
        h.combine(F.vignette); h.combine(F.vignetteFalloff); h.combine(F.grain); h.combine(F.grainSize)
        let R = L.relight; h.combine(R.enabled); h.combine(R.position.x); h.combine(R.position.y)
        h.combine(R.intensity); h.combine(R.radius); h.combine(R.ambient)
        h.combine(R.color.r); h.combine(R.color.g); h.combine(R.color.b)
        let K = L.skin; h.combine(K.enabled); h.combine(K.smooth); h.combine(K.evenTone)
        h.combine(K.deage); h.combine(K.glow)
        let S = L.styles
        h.combine(S.dropShadow.enabled); h.combine(S.dropShadow.angle); h.combine(S.dropShadow.distance)
        h.combine(S.dropShadow.blur); h.combine(S.dropShadow.opacity)
        h.combine(S.outerGlow.enabled); h.combine(S.outerGlow.size); h.combine(S.outerGlow.opacity)
        h.combine(S.stroke.enabled); h.combine(S.stroke.size); h.combine(S.stroke.opacity)
        h.combine(S.gradientFill.enabled); h.combine(S.gradientFill.angle); h.combine(S.gradientFill.opacity)
        return h.finalize()
    }

    static func fit(_ image: CGImage, into canvasSize: CGSize) -> CGImage? {
        let targetW = canvasSize.width, targetH = canvasSize.height
        let srcW = CGFloat(image.width), srcH = CGFloat(image.height)
        let scale = min(targetW / srcW, targetH / srcH)
        let dw = srcW * scale, dh = srcH * scale
        let dx = (targetW - dw) / 2, dy = (targetH - dh) / 2

        guard let ctx = CGContext(data: nil, width: Int(targetW), height: Int(targetH),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: dx, y: dy, width: dw, height: dh))
        return ctx.makeImage()
    }

    // MARK: - Per-layer rendering

    private static func render(layer: PXLayer, canvasSize: CGSize) -> CIImage? {
        let extent = CGRect(origin: .zero, size: canvasSize)

        // 1. Base content
        var img: CIImage
        switch layer.kind {
        case .raster:
            if let smart = layer.smart,
               let cg = SmartObjectEngine.rasterize(smart, canvas: canvasSize) {
                img = CIImage(cgImage: cg).cropped(to: extent)
            } else if let cg = layer.raster {
                img = CIImage(cgImage: cg).cropped(to: extent)
            } else {
                return nil
            }
        case .text:
            guard let cg = renderTextLayer(layer, size: canvasSize) else { return nil }
            img = CIImage(cgImage: cg).cropped(to: extent)
        case .gradient:
            img = renderGradientLayer(layer, size: canvasSize)
        case .solid:
            img = solid(color: layer.solid.color, extent: extent)
        }

        // 2. Filters (blur → pixelate → adjustments → sharpen → noise → hue)
        if layer.filters.blur > 0.01 {
            img = img.applyingGaussianBlur(sigma: layer.filters.blur).cropped(to: extent)
        }
        if layer.filters.pixelate > 1 {
            let f = CIFilter.pixellate()
            f.inputImage = img
            f.scale = Float(layer.filters.pixelate)
            f.center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            if let out = f.outputImage { img = out.cropped(to: extent) }
        }

        // 3. Adjustments
        img = applyAdjustments(img, adj: layer.adjust)

        if layer.filters.sharpen > 0.01 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = img
            f.sharpness = Float(layer.filters.sharpen)
            if let out = f.outputImage { img = out.cropped(to: extent) }
        }

        if layer.filters.noise > 0.001 {
            img = addNoise(img, amount: layer.filters.noise, mono: layer.filters.noiseMono, extent: extent)
        }

        if abs(layer.filters.hueShift) > 0.1 {
            let f = CIFilter.hueAdjust()
            f.inputImage = img
            f.angle = Float(layer.filters.hueShift * .pi / 180)
            if let out = f.outputImage { img = out.cropped(to: extent) }
        }

        // Vignette — radial darkening at the edges. CIVignetteEffect centers
        // on the canvas; intensity scales 0...1, falloff scales 0...1.
        // Mask the result to the input layer's alpha so vignette only darkens
        // pixels the layer actually drew (otherwise it'd show through to the
        // background through transparent regions of the layer).
        if layer.filters.vignette > 0.001 {
            let f = CIFilter.vignetteEffect()
            f.inputImage = img
            f.center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            f.radius = Float(min(canvasSize.width, canvasSize.height) * 0.5 * layer.filters.vignetteFalloff + min(canvasSize.width, canvasSize.height) * 0.25)
            f.intensity = Float(layer.filters.vignette)
            if let out = f.outputImage {
                img = out.applyingFilter("CISourceInCompositing", parameters: [
                    "inputBackgroundImage": img
                ]).cropped(to: extent)
            }
        }

        // Grain — anisotropic noise overlay distinct from the flat `noise`
        // field. Scales the random source to grainSize before compositing,
        // so larger values produce chunkier "film grain" particles.
        if layer.filters.grain > 0.001 {
            img = addGrain(img, amount: layer.filters.grain, size: layer.filters.grainSize, extent: extent)
        }

        // 4. Skin retouch
        if layer.skin.enabled { img = SkinProcessor.apply(img, settings: layer.skin, extent: extent) }

        // 5. Relight
        if layer.relight.enabled { img = Relighter.apply(img, settings: layer.relight, extent: extent) }

        // 6. Gradient fill (clipped to base alpha)
        if layer.styles.gradientFill.enabled {
            let gf = layer.styles.gradientFill
            let lin = linearGradient(c1: gf.c1, c2: gf.c2, angle: gf.angle, extent: extent)
                .applyingOpacity(gf.opacity)
            img = lin.applyingFilter("CISourceInCompositing", parameters: ["inputBackgroundImage": img])
        }

        // 7. Stroke: dilate alpha and tint
        if layer.styles.stroke.enabled && layer.styles.stroke.size > 0 {
            let s = layer.styles.stroke
            let mask = img.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: s.size]).cropped(to: extent)
            let tint = solid(color: s.color, extent: extent).applyingOpacity(s.opacity)
            let stroke = tint.applyingFilter("CISourceInCompositing", parameters: ["inputBackgroundImage": mask])
            img = img.composited(over: stroke).cropped(to: extent)
        }

        // 8. Outer glow (shadow blur with matching color at zero offset)
        if layer.styles.outerGlow.enabled {
            let g = layer.styles.outerGlow
            let tint = solid(color: g.color, extent: extent).applyingOpacity(g.opacity)
            let maskExpanded = img.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(1, g.spread)])
            let glowMask = maskExpanded.applyingGaussianBlur(sigma: g.size).cropped(to: extent)
            let glow = tint.applyingFilter("CISourceInCompositing", parameters: ["inputBackgroundImage": glowMask])
            img = img.composited(over: glow).cropped(to: extent)
        }

        // 9. Drop shadow
        if layer.styles.dropShadow.enabled {
            let sh = layer.styles.dropShadow
            let rad = sh.angle * .pi / 180
            let dx = cos(rad) * sh.distance, dy = sin(rad) * sh.distance
            let tint = solid(color: sh.color, extent: extent).applyingOpacity(sh.opacity)
            let shadowMask = img.applyingGaussianBlur(sigma: sh.blur)
                .transformed(by: CGAffineTransform(translationX: dx, y: -dy))
                .cropped(to: extent)
            let shadow = tint.applyingFilter("CISourceInCompositing", parameters: ["inputBackgroundImage": shadowMask])
            img = img.composited(over: shadow).cropped(to: extent)
        }

        return img
    }

    // MARK: - Helpers

    static func solid(color: ColorRGB, extent: CGRect) -> CIImage {
        let ci = CIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
        return CIImage(color: ci).cropped(to: extent)
    }

    static func applyAdjustments(_ img: CIImage, adj: Adjustments) -> CIImage {
        var out = img
        if adj.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = out
            f.ev = Float(adj.exposure * 2)
            out = f.outputImage ?? out
        }
        if adj.brightness != 0 || adj.contrast != 0 || adj.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = out
            f.brightness = Float(adj.brightness * 0.5)
            f.contrast = Float(1 + adj.contrast)
            f.saturation = Float(1 + adj.saturation)
            out = f.outputImage ?? out
        }
        if adj.warmth != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = out
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - CGFloat(adj.warmth) * 2000, y: 0)
            out = f.outputImage ?? out
        }
        if adj.shadows != 0 || adj.highlights != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = out
            f.shadowAmount = Float(adj.shadows)
            f.highlightAmount = Float(1 - max(0, min(1, -adj.highlights * 0.5 + 1)))
            out = f.outputImage ?? out
        }
        // Vibrance — Lightroom-style smart saturation. Boosts low-saturation
        // pixels more than already-saturated ones; protects skin tones.
        // CIVibrance accepts -1...1 directly.
        if adj.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = out
            f.amount = Float(adj.vibrance)
            out = f.outputImage ?? out
        }
        // Per-color HSL — Lightroom-style 8-band targeted hue/sat/lum control.
        // Implemented as a 3D LUT applied via CIColorCube; the LUT is generated
        // on CPU and the heavy lift is one GPU-side cube lookup. Identity case
        // (all 24 sliders at zero) skips the work.
        if !adj.hsl.isIdentity {
            out = applyHSL(out, hsl: adj.hsl)
        }
        // Tone curve — preset shape lerped from linear by `curveIntensity`.
        // CIToneCurve takes 5 control points; we interpolate each point's Y
        // toward the preset's Y by intensity. At intensity=0 the curve is
        // identity (no-op); at 1 it's the full preset.
        if adj.curve != .linear && adj.curveIntensity > 0.001 {
            let pts = adj.curve.points
            let t = CGFloat(adj.curveIntensity)
            let f = CIFilter.toneCurve()
            f.inputImage = out
            f.point0 = CGPoint(x: pts.0.x, y: pts.0.x + (pts.0.y - pts.0.x) * t)
            f.point1 = CGPoint(x: pts.1.x, y: pts.1.x + (pts.1.y - pts.1.x) * t)
            f.point2 = CGPoint(x: pts.2.x, y: pts.2.x + (pts.2.y - pts.2.x) * t)
            f.point3 = CGPoint(x: pts.3.x, y: pts.3.x + (pts.3.y - pts.3.x) * t)
            f.point4 = CGPoint(x: pts.4.x, y: pts.4.x + (pts.4.y - pts.4.x) * t)
            out = f.outputImage ?? out
        }
        return out
    }

    // MARK: - HSL LUT

    /// Hue centers in degrees for the 8 color ranges, in the same order as
    /// `HSLAdjustments.asDeltaTable`. Matches Lightroom's hue band layout.
    private static let hslHueCenters: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]

    /// Cache one LUT (raw cube data) per unique HSL parameter set. Slider
    /// drags don't allocate beyond the first unique snapshot value, and the
    /// cache caps itself so repeated tweaks don't grow it unbounded.
    nonisolated(unsafe) private static var hslLUTCache: [Int: Data] = [:]
    private static let hslLUTDimension: Int = 32

    static func applyHSL(_ img: CIImage, hsl: HSLAdjustments) -> CIImage {
        let key = hslHash(hsl)
        let data: Data
        if let cached = hslLUTCache[key] {
            data = cached
        } else {
            data = makeHSLCubeData(hsl, dim: hslLUTDimension)
            if hslLUTCache.count > 32 { hslLUTCache.removeAll(keepingCapacity: true) }
            hslLUTCache[key] = data
        }
        // CIColorCubeWithColorSpace ensures the LUT (which we computed in sRGB
        // HSV space) is applied to sRGB-encoded RGB values, even though the
        // CIContext working space is extendedLinearSRGB.
        let f = CIFilter(name: "CIColorCubeWithColorSpace")!
        f.setValue(img, forKey: kCIInputImageKey)
        f.setValue(hslLUTDimension, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            f.setValue(srgb, forKey: "inputColorSpace")
        }
        return f.outputImage ?? img
    }

    private static func hslHash(_ hsl: HSLAdjustments) -> Int {
        var h = Hasher()
        for d in hsl.asDeltaTable { h.combine(d.h); h.combine(d.s); h.combine(d.l) }
        return h.finalize()
    }

    /// Builds a 32×32×32 RGBA float LUT that, for each cell, applies per-band
    /// hue/sat/lum offsets weighted by the cell's hue position relative to
    /// the 8 standard color bands (red/orange/yellow/green/aqua/blue/purple/
    /// magenta). Each pixel is influenced by its two adjacent band centers
    /// (linear interpolation in hue), so weights always sum to 1 and the
    /// transitions are smooth.
    private static func makeHSLCubeData(_ hsl: HSLAdjustments, dim: Int) -> Data {
        let table = hsl.asDeltaTable
        let centers = hslHueCenters
        let n = centers.count

        let count = dim * dim * dim * 4
        var bytes = [Float](repeating: 0, count: count)

        // CIColorCube expects sRGB cube. We unpremultiply per spec; alpha=1.
        for b in 0..<dim {
            let bf = Float(b) / Float(dim - 1)
            for g in 0..<dim {
                let gf = Float(g) / Float(dim - 1)
                for r in 0..<dim {
                    let rf = Float(r) / Float(dim - 1)
                    var (h, s, v) = rgbToHSV(r: rf, g: gf, b: bf)

                    // For an unsaturated pixel, hue is undefined and per-band
                    // adjustments shouldn't apply. Scale the effect by saturation
                    // so neutrals are preserved.
                    let satWeight = s

                    if satWeight > 0.0001 {
                        // Find which two adjacent band centers bracket the hue.
                        let hDeg = Double(h * 360)
                        var idxA = 0
                        var idxB = 0
                        var t: Double = 0
                        for i in 0..<n {
                            let cA = centers[i]
                            let cB = centers[(i + 1) % n]
                            let span = (cB - cA + 360).truncatingRemainder(dividingBy: 360)
                            // distance from cA to hDeg, going forward through the wheel
                            let dist = (hDeg - cA + 360).truncatingRemainder(dividingBy: 360)
                            if dist < span || (dist == 0 && i == 0) {
                                idxA = i
                                idxB = (i + 1) % n
                                t = span > 0 ? dist / span : 0
                                break
                            }
                        }
                        let wA = 1 - t
                        let wB = t
                        let dA = table[idxA]
                        let dB = table[idxB]
                        // Hue shift: map slider [-1...1] to ±60° rotation.
                        // Wide enough that pushing a slider to its extreme
                        // visibly moves the band into an adjacent one (e.g.,
                        // greens to yellow), matching Lightroom's feel.
                        let dH = (wA * dA.h + wB * dB.h) * 60.0
                        // Saturation: slider [-1...1] is multiplicative scale ±1.
                        // Negative drives toward gray; positive boosts.
                        let dS = wA * dA.s + wB * dB.s
                        // Luminance: slider [-1...1] scales V proportionally.
                        let dL = wA * dA.l + wB * dB.l

                        // Apply weighted by saturation so neutrals don't drift.
                        h = Float(((Double(h * 360) + dH * Double(satWeight)) + 360)
                                    .truncatingRemainder(dividingBy: 360) / 360.0)
                        let sScaled = Double(s) * (1 + dS * Double(satWeight))
                        s = Float(max(0, min(1, sScaled)))
                        let vScaled = Double(v) * (1 + dL * Double(satWeight))
                        v = Float(max(0, min(1, vScaled)))
                    }

                    let (rOut, gOut, bOut) = hsvToRGB(h: h, s: s, v: v)
                    let i = (b * dim * dim + g * dim + r) * 4
                    bytes[i + 0] = rOut
                    bytes[i + 1] = gOut
                    bytes[i + 2] = bOut
                    bytes[i + 3] = 1
                }
            }
        }

        return bytes.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func rgbToHSV(r: Float, g: Float, b: Float) -> (h: Float, s: Float, v: Float) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        let v = maxC
        let s = maxC > 0 ? delta / maxC : 0
        var h: Float = 0
        if delta > 0 {
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = (b - r) / delta + 2
            } else {
                h = (r - g) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, s, v)
    }

    private static func hsvToRGB(h: Float, s: Float, v: Float) -> (r: Float, g: Float, b: Float) {
        if s <= 0 { return (v, v, v) }
        let h6 = (h - floor(h)) * 6
        let i = Int(floor(h6))
        let f = h6 - Float(i)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    static func linearGradient(c1: ColorRGB, c2: ColorRGB, angle: Double, extent: CGRect) -> CIImage {
        let rad = angle * .pi / 180
        let len = max(extent.width, extent.height)
        let cx = extent.midX, cy = extent.midY
        let f = CIFilter.linearGradient()
        f.point0 = CGPoint(x: cx - cos(rad) * len / 2, y: cy - sin(rad) * len / 2)
        f.point1 = CGPoint(x: cx + cos(rad) * len / 2, y: cy + sin(rad) * len / 2)
        f.color0 = CIColor(red: c1.r, green: c1.g, blue: c1.b, alpha: c1.a)
        f.color1 = CIColor(red: c2.r, green: c2.g, blue: c2.b, alpha: c2.a)
        return (f.outputImage ?? CIImage.empty()).cropped(to: extent)
    }

    /// Film-style grain overlay — generates a random luma field, scales it to
    /// `size` (so larger values produce chunkier particles), monochromes it,
    /// then composites with multiply blend so the grain *modulates* the image
    /// instead of additively overlaying. Distinct from `addNoise`, which
    /// composites RGBA noise directly.
    static func addGrain(_ img: CIImage, amount: Double, size: Double, extent: CGRect) -> CIImage {
        let random = CIFilter.randomGenerator()
        guard var grain = random.outputImage else { return img }
        // Scale the noise field so each grain particle is `size` pixels wide.
        // Anchor the scale at the canvas center — naïve `scaleX: size, y: size`
        // anchors at CI's lower-left origin, which makes the grain pattern look
        // visually "stretched from the corner" at larger sizes.
        if size > 1.01 {
            let cx = extent.midX
            let cy = extent.midY
            let t = CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(scaleX: size, y: size))
                .concatenating(CGAffineTransform(translationX: cx, y: cy))
            grain = grain.transformed(by: t)
        }
        // Desaturate to monochrome luma — film grain is ~achromatic.
        let mono = CIFilter.colorMatrix()
        mono.inputImage = grain
        mono.rVector = CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0)
        mono.gVector = CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0)
        mono.bVector = CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        var lumaGrain = mono.outputImage ?? grain
        // Re-center around mid-grey so multiply doesn't only darken.
        let bias = CIFilter.colorMatrix()
        bias.inputImage = lumaGrain
        bias.biasVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 0)
        // Mix grain ↔ flat 50% grey by `amount` so 0 = no effect, 1 = full grain.
        let opacityMatrix = CIFilter.colorMatrix()
        opacityMatrix.inputImage = lumaGrain
        let mid = 1 - amount
        opacityMatrix.rVector = CIVector(x: amount, y: 0, z: 0, w: 0)
        opacityMatrix.gVector = CIVector(x: 0, y: amount, z: 0, w: 0)
        opacityMatrix.bVector = CIVector(x: 0, y: 0, z: amount, w: 0)
        opacityMatrix.biasVector = CIVector(x: mid * 0.5, y: mid * 0.5, z: mid * 0.5, w: 1)
        lumaGrain = opacityMatrix.outputImage?.cropped(to: extent) ?? lumaGrain.cropped(to: extent)
        // Multiply blend so highlights stay bright and shadows pick up grain.
        let blend = CIFilter.multiplyBlendMode()
        blend.inputImage = lumaGrain
        blend.backgroundImage = img
        let grained = blend.outputImage ?? img
        // Mask the grained result to the input layer's alpha so transparent
        // regions of the layer don't get filled with grey-noise (which would
        // bleed across the whole canvas and obscure layers below).
        return grained.applyingFilter("CISourceInCompositing", parameters: [
            "inputBackgroundImage": img
        ]).cropped(to: extent)
    }

    static func addNoise(_ img: CIImage, amount: Double, mono: Bool, extent: CGRect) -> CIImage {
        let random = CIFilter.randomGenerator()
        guard var noise = random.outputImage?.cropped(to: extent) else { return img }
        if mono {
            let mono = CIFilter.colorMatrix()
            mono.inputImage = noise
            mono.rVector = CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0)
            mono.gVector = CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0)
            mono.bVector = CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0)
            mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            noise = mono.outputImage ?? noise
        }
        let blend = CIFilter.colorMatrix()
        blend.inputImage = noise
        blend.aVector = CIVector(x: 0, y: 0, z: 0, w: amount)
        let noiseLayer = blend.outputImage?.cropped(to: extent) ?? noise
        let composited = noiseLayer.composited(over: img)
        // Mask to the source layer's alpha so the noise overlay doesn't extend
        // past the layer's actual content into transparent regions (which would
        // bleed the noise across the canvas, obscuring layers below).
        return composited.applyingFilter("CISourceInCompositing", parameters: [
            "inputBackgroundImage": img
        ]).cropped(to: extent)
    }

    private static func compositeBlend(top: CIImage, bottom: CIImage, mode: BlendMode) -> CIImage {
        let name: String
        switch mode {
        case .normal: return top.composited(over: bottom)
        case .multiply: name = "CIMultiplyBlendMode"
        case .screen: name = "CIScreenBlendMode"
        case .overlay: name = "CIOverlayBlendMode"
        case .softLight: name = "CISoftLightBlendMode"
        case .hardLight: name = "CIHardLightBlendMode"
        case .colorDodge: name = "CIColorDodgeBlendMode"
        case .colorBurn: name = "CIColorBurnBlendMode"
        case .lighten: name = "CILightenBlendMode"
        case .darken: name = "CIDarkenBlendMode"
        case .difference: name = "CIDifferenceBlendMode"
        case .exclusion: name = "CIExclusionBlendMode"
        case .hue: name = "CIHueBlendMode"
        case .saturation: name = "CISaturationBlendMode"
        case .color: name = "CIColorBlendMode"
        case .luminosity: name = "CILuminosityBlendMode"
        }
        let f = CIFilter(name: name)!
        f.setValue(top, forKey: kCIInputImageKey)
        f.setValue(bottom, forKey: kCIInputBackgroundImageKey)
        return f.outputImage ?? top.composited(over: bottom)
    }

    // MARK: - Text & gradient rasterization

    private static func renderTextLayer(_ layer: PXLayer, size: CGSize) -> CGImage? {
        let t = layer.text
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx

        let font = TextFontResolver.font(for: t)
        let paragraph = NSMutableParagraphStyle()
        switch t.alignment {
        case "left": paragraph.alignment = .left
        case "right": paragraph.alignment = .right
        default: paragraph.alignment = .center
        }
        paragraph.lineHeightMultiple = CGFloat(t.lineHeight)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: t.color.nsColor,
            .paragraphStyle: paragraph,
            .kern: CGFloat(t.tracking),
        ]
        if t.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if t.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }

        // Build the attributed string. Prefer the rich RTF when present —
        // per-range colors / bold / italic / underline authored via RichTextKit.
        // Fall back to the plain string + legacy markup.
        let mut: NSMutableAttributedString
        if let rtf = t.rtfData,
           let parsed = try? NSMutableAttributedString(
                data: rtf,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil) {
            // Merge layer defaults with per-run overrides from the RichTextKit
            // editor. Size + family ALWAYS come from the layer (the RTF stores
            // the editor's UI font, which is tiny and would render at 14pt if
            // we respected it). Bold/italic/color/underline/strike are taken
            // per-run so per-word styling works.
            let full = NSRange(location: 0, length: parsed.length)
            parsed.enumerateAttributes(in: full, options: []) { runAttrs, range, _ in
                var runBoldFromFont = false
                var runItalicFromFont = false
                if let runFont = runAttrs[.font] as? NSFont {
                    let traits = runFont.fontDescriptor.symbolicTraits
                    if traits.contains(.bold) { runBoldFromFont = true }
                    if traits.contains(.italic) { runItalicFromFont = true }
                }
                var runContent = t
                if runBoldFromFont { runContent.weight = max(runContent.weight, 700) }
                if runItalicFromFont { runContent.italic = true }
                let runFont = TextFontResolver.font(for: runContent)

                parsed.addAttribute(.font, value: runFont, range: range)
                parsed.addAttribute(.paragraphStyle, value: paragraph, range: range)
                parsed.addAttribute(.kern, value: CGFloat(t.tracking), range: range)
                if runAttrs[.foregroundColor] == nil {
                    parsed.addAttribute(.foregroundColor, value: t.color.nsColor, range: range)
                }
                if t.underline && runAttrs[.underlineStyle] == nil {
                    parsed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
                if t.strikethrough && runAttrs[.strikethroughStyle] == nil {
                    parsed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }
            if t.uppercase {
                let s = parsed.string.uppercased()
                let upper = NSMutableAttributedString(string: s)
                parsed.enumerateAttributes(in: full, options: []) { runAttrs, range, _ in
                    if NSMaxRange(range) <= (s as NSString).length {
                        upper.setAttributes(runAttrs, range: range)
                    }
                }
                mut = upper
            } else {
                mut = parsed
            }
        } else {
            // Legacy markup path.
            let parsed = TextMarkup.parse(t.uppercase ? t.string.uppercased() : t.string)
            mut = NSMutableAttributedString(string: parsed.stripped, attributes: attrs)
            for span in parsed.spans {
                mut.addAttribute(.foregroundColor, value: span.color, range: span.range)
            }
        }
        let attributed = mut as NSAttributedString

        // Measure the block using a generous constraint so line-wrapping matches natural width.
        let bounding = attributed.boundingRect(with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])

        // Render the text centered at the canvas center. The actual on-canvas
        // position is applied as a TRANSLATION at composite time, so moving the
        // text doesn't invalidate this expensive rasterization.
        let canonicalAnchor = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let blockW = max(1, bounding.width)
        let blockH = max(1, bounding.height)
        let drawRect = CGRect(x: canonicalAnchor.x - blockW / 2,
                              y: canonicalAnchor.y - blockH / 2,
                              width: blockW,
                              height: blockH)
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

        // Cache bounds assuming anchor = (0.5, 0.5). The move tool adjusts by
        // current anchor at hit-test time. Stored in top-down doc coords.
        let docMinY = size.height - (drawRect.origin.y + blockH)
        layer.text.lastRenderedBounds = CGRect(x: drawRect.origin.x,
                                               y: docMinY,
                                               width: blockW,
                                               height: blockH)

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func renderGradientLayer(_ layer: PXLayer, size: CGSize) -> CIImage {
        let g = layer.gradient
        let extent = CGRect(origin: .zero, size: size)
        if g.kind == "radial" {
            let f = CIFilter.radialGradient()
            f.center = CGPoint(x: g.center.x * size.width, y: g.center.y * size.height)
            f.radius0 = 0
            f.radius1 = Float(max(1, g.radius * max(size.width, size.height)))
            f.color0 = CIColor(red: g.c1.r, green: g.c1.g, blue: g.c1.b, alpha: g.c1.a)
            f.color1 = CIColor(red: g.c2.r, green: g.c2.g, blue: g.c2.b, alpha: g.c2.a)
            return (f.outputImage ?? CIImage.empty()).cropped(to: extent)
        }
        return linearGradient(c1: g.c1, c2: g.c2, angle: g.angle, extent: extent)
    }
}

// MARK: - CIImage opacity helper

extension CIImage {
    func applyingOpacity(_ o: Double) -> CIImage {
        guard o < 0.9999 else { return self }
        let f = CIFilter.colorMatrix()
        f.inputImage = self
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(o))
        return f.outputImage ?? self
    }
}
