import Foundation
import CoreGraphics

/// Programmatic measurement helper for HSL band-isolation tests. Given a
/// rendered CGImage, classifies each pixel into its single nearest hue band
/// (by minimum circular distance to the band center) and returns per-band
/// mean saturation, mean luminance (V), mean hue, and pixel count.
///
/// Used by `HSLBandIsolationTests` to assert that band-targeted slider
/// moves only affect their target band — the kind of semantic regression
/// that snapshot diffing can't catch.
enum HSLBandMetrics {
    enum HueBand: Int, CaseIterable {
        case red = 0, orange, yellow, green, aqua, blue, purple, magenta

        var label: String {
            switch self {
            case .red: return "red"; case .orange: return "orange"; case .yellow: return "yellow"
            case .green: return "green"; case .aqua: return "aqua"; case .blue: return "blue"
            case .purple: return "purple"; case .magenta: return "magenta"
            }
        }

        var hueDeg: Double {
            switch self {
            case .red: return 0; case .orange: return 30; case .yellow: return 60
            case .green: return 120; case .aqua: return 180; case .blue: return 240
            case .purple: return 270; case .magenta: return 300
            }
        }
    }

    struct BandStats: Equatable {
        var meanSat: Double = 0
        var meanLum: Double = 0
        var meanHue: Double = 0   // degrees
        var pixelCount: Int = 0
    }

    /// Sample every Nth pixel; classify each non-gray pixel into its
    /// nearest band. Pixels with `s < minSat` are excluded as ambiguous.
    static func metrics(of cg: CGImage,
                        sampleStride: Int = 4,
                        minSat: Double = 0.10) -> [HueBand: BandStats] {
        let w = cg.width, h = cg.height
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return [:] }
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let ctx = CGContext(data: &data, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return [:]
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let bandCount = HueBand.allCases.count
        var sumSat  = [Double](repeating: 0, count: bandCount)
        var sumLum  = [Double](repeating: 0, count: bandCount)
        var sumCos  = [Double](repeating: 0, count: bandCount)
        var sumSin  = [Double](repeating: 0, count: bandCount)
        var counts  = [Int](repeating: 0, count: bandCount)

        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let i = (y * bytesPerRow) + (x * 4)
                let alpha = Double(data[i + 3]) / 255.0
                if alpha < 0.5 { x += sampleStride; continue }
                let r = Double(data[i + 0]) / 255.0
                let g = Double(data[i + 1]) / 255.0
                let b = Double(data[i + 2]) / 255.0
                let (hueNorm, sat, val) = rgbToHSV(r: r, g: g, b: b)
                if sat < minSat { x += sampleStride; continue }

                let hueDeg = hueNorm * 360
                // Nearest band by circular hue distance.
                var bestIdx = 0
                var bestDist = Double.infinity
                for (idx, band) in HueBand.allCases.enumerated() {
                    var d = abs(band.hueDeg - hueDeg)
                    if d > 180 { d = 360 - d }
                    if d < bestDist { bestDist = d; bestIdx = idx }
                }

                sumSat[bestIdx] += sat
                sumLum[bestIdx] += val
                let rad = hueDeg * .pi / 180
                sumCos[bestIdx] += cos(rad)
                sumSin[bestIdx] += sin(rad)
                counts[bestIdx] += 1

                x += sampleStride
            }
            y += sampleStride
        }

        var result: [HueBand: BandStats] = [:]
        for (idx, band) in HueBand.allCases.enumerated() {
            let n = counts[idx]
            guard n > 0 else { continue }
            let nf = Double(n)
            // Mean hue from the average unit-vector — handles wraparound
            // correctly (averaging 350° and 10° should give 0°, not 180°).
            let mh = atan2(sumSin[idx] / nf, sumCos[idx] / nf) * 180 / .pi
            let normalizedHue = (mh + 360).truncatingRemainder(dividingBy: 360)
            result[band] = BandStats(
                meanSat: sumSat[idx] / nf,
                meanLum: sumLum[idx] / nf,
                meanHue: normalizedHue,
                pixelCount: n
            )
        }
        return result
    }

    /// Smallest signed circular distance from `a` to `b` in degrees, in
    /// the range (-180, 180]. Positive means b is "ahead" of a on the wheel.
    static func circularHueDelta(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    private static func rgbToHSV(r: Double, g: Double, b: Double)
        -> (h: Double, s: Double, v: Double) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        let v = maxC
        let s = maxC > 0 ? delta / maxC : 0
        var h: Double = 0
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
}
