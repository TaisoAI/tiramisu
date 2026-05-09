import Foundation
import CoreGraphics
import AppKit

/// Stamp-based brush engine. Owns a canvas-resolution bitmap context for the
/// duration of one paint stroke, draws soft-edged round dabs along the input
/// path at uniform spacing, and writes the result back to the layer's
/// `raster` CGImage as the user drags. Pencil mode draws normally; eraser
/// mode uses `destinationOut` to subtract alpha. Honors the document's
/// `selectionRect` as a clip path so strokes can't escape a selection.
@MainActor
final class PaintStroke {
    private let layer: PXLayer
    private let canvasSize: CGSize
    /// The layer's pixels at stroke start. Captured once and never modified;
    /// the live preview is `baseImage` composited with the (cumulative)
    /// stroke buffer at the user's opacity ceiling.
    private let baseImage: CGImage?
    /// Scratch context where stamps accumulate with alpha = `flow`. Starts
    /// transparent; one drag tick adds more stamps. On commit we composite
    /// this buffer onto baseImage scaled by `opacity` — that's what gives
    /// flow vs. opacity their distinct Photoshop semantics (flow = build-up
    /// rate within a stroke; opacity = the stroke's max alpha cap).
    private let strokeCtx: CGContext
    private let isEraser: Bool
    private let strokeColor: CGColor
    private let size: CGFloat
    private let hardness: CGFloat
    private let opacity: CGFloat
    private let flow: CGFloat
    /// Exponential-filter coefficient: 0 = no smoothing (stamp at every raw
    /// point), approaches 1 = very heavy smoothing. Above ~0.95 the brush
    /// visibly lags the cursor; we cap at 0.97 in the binding so it can't
    /// stop tracking entirely.
    private let smoothing: CGFloat
    private let clipPath: CGPath?

    private var lastDocPoint: CGPoint?       // last *smoothed* point we stamped from
    private var smoothed: CGPoint?           // running smoothed position
    private var lastRawPoint: CGPoint?       // for end-of-stroke catch-up
    private var leftover: CGFloat = 0

    init?(layer: PXLayer,
          canvasSize: CGSize,
          isEraser: Bool,
          color: ColorRGB,
          settings: BrushSettings,
          selectionPath: CGPath?) {
        guard layer.kind == .raster else { return nil }

        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        guard w > 0, h > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let strokeCtx = CGContext(data: nil, width: w, height: h,
                                        bitsPerComponent: 8, bytesPerRow: 0,
                                        space: cs,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        strokeCtx.interpolationQuality = .high

        self.layer = layer
        self.canvasSize = canvasSize
        self.baseImage = layer.raster
        self.strokeCtx = strokeCtx
        self.isEraser = isEraser
        self.strokeColor = color.cgColor
        self.size = max(1, CGFloat(settings.size))
        // BrushSettings.feather is 0…1 where 1 is "very soft". Internally we
        // work in hardness terms (1 = solid disc, 0 = pure gradient).
        self.hardness = max(0, min(1, CGFloat(1.0 - settings.feather)))
        self.opacity = max(0, min(1, CGFloat(settings.opacity)))
        self.flow = max(0.01, min(1, CGFloat(settings.flow)))
        self.smoothing = max(0, min(0.97, CGFloat(settings.smoothing)))

        if let path = selectionPath {
            // Selection lives in doc top-down coords; CGContext is bottom-up.
            // Mirror the path's Y axis around canvasH/2 so it lands in the
            // same visual position when drawn into the bottom-up context.
            var t = CGAffineTransform(scaleX: 1, y: -1)
                .concatenating(CGAffineTransform(translationX: 0, y: canvasSize.height))
            self.clipPath = path.copy(using: &t) ?? path
        } else {
            self.clipPath = nil
        }
    }

    /// Add a pointer sample (doc top-down coords). Drops one stamp on the
    /// first call, then evenly-spaced stamps along the segment from the last
    /// stamped point to the smoothed version of this one. With smoothing > 0
    /// the brush trails the cursor with an exponential-filter lag.
    func addPoint(_ p: CGPoint) {
        lastRawPoint = p
        let target: CGPoint
        if let s = smoothed {
            // Standard 1-pole low-pass: new = old + α(raw - old).
            // smoothing = 0 → α = 1 (track raw immediately).
            // smoothing = 0.9 → α = 0.1 (10% step toward raw each tick).
            let alpha = 1.0 - smoothing
            target = CGPoint(x: s.x + alpha * (p.x - s.x),
                             y: s.y + alpha * (p.y - s.y))
        } else {
            target = p
        }
        smoothed = target
        stampLine(to: target)
    }

    /// Called when the user releases the mouse. With smoothing the filtered
    /// position trails the actual cursor; we feed the last raw sample through
    /// the filter several times so the stroke catches up and ends where the
    /// user actually let go. Without this the brush would visibly stop short.
    func endStroke() {
        guard smoothing > 0.001, let raw = lastRawPoint, let s = smoothed else { return }
        var cur = s
        let alpha = 1.0 - smoothing
        // 24 iterations brings the filter to within ~0.5px even at smoothing=0.97.
        for _ in 0..<24 {
            cur = CGPoint(x: cur.x + alpha * (raw.x - cur.x),
                          y: cur.y + alpha * (raw.y - cur.y))
            stampLine(to: cur)
            if hypot(cur.x - raw.x, cur.y - raw.y) < 0.5 { break }
        }
        smoothed = cur
    }

    /// Internal: stamp uniformly-spaced dabs along the segment from
    /// `lastDocPoint` (last stamped position) to `to`.
    private func stampLine(to: CGPoint) {
        guard let last = lastDocPoint else {
            stamp(at: to)
            lastDocPoint = to
            return
        }
        let dx = to.x - last.x, dy = to.y - last.y
        let segLen = hypot(dx, dy)
        if segLen < 0.001 { return }
        // Spacing = 10% of brush size; dense enough that adjacent stamps
        // overlap heavily and the stroke reads as a continuous line.
        let step = max(0.5, size * 0.10)
        var travelled = -leftover
        while travelled + step <= segLen {
            travelled += step
            let t = travelled / segLen
            stamp(at: CGPoint(x: last.x + dx * t, y: last.y + dy * t))
        }
        leftover = max(0, segLen - travelled)
        lastDocPoint = to
    }

    /// Snapshot the cumulative stroke onto the layer. Composites the stroke
    /// buffer over the captured baseImage with global alpha = `opacity`, so
    /// the user's opacity slider is a real ceiling no matter how many
    /// overlapping stamps the drag laid down.
    func commitToLayer() {
        let w = strokeCtx.width, h = strokeCtx.height
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let outCtx = CGContext(data: nil, width: w, height: h,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: cs,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return
        }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)

        if let base = baseImage {
            outCtx.draw(base, in: rect)
        }
        if let strokeImg = strokeCtx.makeImage() {
            outCtx.saveGState()
            outCtx.setAlpha(opacity)
            outCtx.setBlendMode(isEraser ? .destinationOut : .normal)
            outCtx.draw(strokeImg, in: rect)
            outCtx.restoreGState()
        }
        if let img = outCtx.makeImage() {
            layer.raster = img
        }
    }

    private func stamp(at docP: CGPoint) {
        let cx = docP.x
        let cy = canvasSize.height - docP.y
        let r = size * 0.5
        let bbox = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)

        strokeCtx.saveGState()
        if let p = clipPath {
            strokeCtx.addPath(p)
            strokeCtx.clip()
        }

        // Stamps always accumulate with the user's `flow` value into the
        // stroke buffer — opacity is applied once at commit time so it
        // behaves as a ceiling, not a per-stamp multiplier. Eraser uses the
        // same accumulation model; destination-out happens at commit.
        let stampColor = isEraser
            ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            : strokeColor
        drawSoftDisc(in: bbox,
                     alpha: flow,
                     hardness: hardness,
                     color: stampColor,
                     into: strokeCtx)
        strokeCtx.restoreGState()
    }

    private func drawSoftDisc(in bbox: CGRect, alpha: CGFloat, hardness: CGFloat, color: CGColor, into ctx: CGContext) {
        // Hard brush — single solid fill, fast path.
        if hardness >= 0.99 {
            ctx.setFillColor(color.copy(alpha: alpha) ?? color)
            ctx.fillEllipse(in: bbox)
            return
        }

        // Soft brush — radial gradient from full alpha at the core to zero at
        // the rim. Inner solid radius = r * hardness, outer radius = r.
        let cs = CGColorSpaceCreateDeviceRGB()
        let comps = color.components ?? [0, 0, 0, 1]
        guard comps.count >= 3 else { return }
        let cr = comps[0], cg = comps[1], cb = comps[2]
        let stops: [CGFloat] = [
            cr, cg, cb, alpha,
            cr, cg, cb, 0
        ]
        let locations: [CGFloat] = [hardness, 1.0]
        guard let gradient = CGGradient(
            colorSpace: cs,
            colorComponents: stops,
            locations: locations,
            count: 2
        ) else {
            ctx.setFillColor(color.copy(alpha: alpha) ?? color)
            ctx.fillEllipse(in: bbox)
            return
        }
        let cx = bbox.midX, cy = bbox.midY
        let r = bbox.width * 0.5

        ctx.saveGState()
        ctx.addEllipse(in: bbox)
        ctx.clip()
        ctx.drawRadialGradient(gradient,
                               startCenter: CGPoint(x: cx, y: cy),
                               startRadius: 0,
                               endCenter: CGPoint(x: cx, y: cy),
                               endRadius: r,
                               options: [])
        ctx.restoreGState()
    }
}
