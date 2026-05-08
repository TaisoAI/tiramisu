import Foundation
import CoreGraphics
import AppKit
import Observation

enum LayerKind: String, Codable, Sendable { case raster, text, gradient, solid }

/// Tone-curve preset shapes. Each one resolves to a 5-point control set
/// for `CIToneCurve` at full intensity; the live render lerps between
/// linear (identity) and the preset's points by `curveIntensity`.
enum CurvePreset: String, Codable, Sendable, CaseIterable {
    case linear            // identity — no-op
    case gentleS           // mild contrast lift
    case strongS           // dramatic contrast lift
    case liftedShadows     // faded / film look
    case crushedShadows    // dramatic shadow detail

    var label: String {
        switch self {
        case .linear:         return "Linear"
        case .gentleS:        return "Gentle S"
        case .strongS:        return "Strong S"
        case .liftedShadows:  return "Lifted shadows"
        case .crushedShadows: return "Crushed shadows"
        }
    }

    /// The 5 control points (x is input luma 0…1, y is output) at full
    /// intensity. `linear` returns the identity curve.
    var points: (CGPoint, CGPoint, CGPoint, CGPoint, CGPoint) {
        switch self {
        case .linear:
            return (CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25),
                    CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 0.75),
                    CGPoint(x: 1, y: 1))
        case .gentleS:
            return (CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.20),
                    CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 0.80),
                    CGPoint(x: 1, y: 1))
        case .strongS:
            return (CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.13),
                    CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 0.87),
                    CGPoint(x: 1, y: 1))
        case .liftedShadows:
            return (CGPoint(x: 0, y: 0.10), CGPoint(x: 0.25, y: 0.30),
                    CGPoint(x: 0.5, y: 0.55), CGPoint(x: 0.75, y: 0.78),
                    CGPoint(x: 1, y: 1))
        case .crushedShadows:
            return (CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.10),
                    CGPoint(x: 0.5, y: 0.45), CGPoint(x: 0.75, y: 0.80),
                    CGPoint(x: 1, y: 0.95))
        }
    }
}

/// Per-range HSL adjustments, Lightroom-style. Eight color ranges
/// (red/orange/yellow/green/aqua/blue/purple/magenta), each with a hue
/// shift, saturation scale, and luminance scale. All three sliders are
/// -1...1; 0 is identity.
struct HSLAdjustments: Codable, Sendable, Equatable {
    var redHue: Double = 0;     var redSat: Double = 0;     var redLum: Double = 0
    var orangeHue: Double = 0;  var orangeSat: Double = 0;  var orangeLum: Double = 0
    var yellowHue: Double = 0;  var yellowSat: Double = 0;  var yellowLum: Double = 0
    var greenHue: Double = 0;   var greenSat: Double = 0;   var greenLum: Double = 0
    var aquaHue: Double = 0;    var aquaSat: Double = 0;    var aquaLum: Double = 0
    var blueHue: Double = 0;    var blueSat: Double = 0;    var blueLum: Double = 0
    var purpleHue: Double = 0;  var purpleSat: Double = 0;  var purpleLum: Double = 0
    var magentaHue: Double = 0; var magentaSat: Double = 0; var magentaLum: Double = 0

    var isIdentity: Bool {
        redHue == 0 && redSat == 0 && redLum == 0 &&
        orangeHue == 0 && orangeSat == 0 && orangeLum == 0 &&
        yellowHue == 0 && yellowSat == 0 && yellowLum == 0 &&
        greenHue == 0 && greenSat == 0 && greenLum == 0 &&
        aquaHue == 0 && aquaSat == 0 && aquaLum == 0 &&
        blueHue == 0 && blueSat == 0 && blueLum == 0 &&
        purpleHue == 0 && purpleSat == 0 && purpleLum == 0 &&
        magentaHue == 0 && magentaSat == 0 && magentaLum == 0
    }

    /// Per-range deltas in (hue, sat, lum) order, indexed by the same hue-center
    /// order the renderer's mixer uses (0°, 30°, 60°, 120°, 180°, 240°, 270°, 300°).
    var asDeltaTable: [(h: Double, s: Double, l: Double)] {
        [
            (redHue,     redSat,     redLum),
            (orangeHue,  orangeSat,  orangeLum),
            (yellowHue,  yellowSat,  yellowLum),
            (greenHue,   greenSat,   greenLum),
            (aquaHue,    aquaSat,    aquaLum),
            (blueHue,    blueSat,    blueLum),
            (purpleHue,  purpleSat,  purpleLum),
            (magentaHue, magentaSat, magentaLum),
        ]
    }
}

struct Adjustments: Codable, Sendable, Equatable {
    var brightness: Double = 0   // -1...1
    var contrast: Double = 0     // -1...1
    var exposure: Double = 0     // -2...2 EV
    var saturation: Double = 0   // -1...1
    var warmth: Double = 0       // -1...1
    var shadows: Double = 0      // -1...1
    var highlights: Double = 0   // -1...1
    /// "Smart" saturation that protects already-saturated pixels and skin tones —
    /// boosts low-saturation regions more than high-saturation ones. Lightroom-style.
    var vibrance: Double = 0     // -1...1
    /// Tone-curve preset. Combined with `curveIntensity` the live render lerps
    /// from linear (identity) to the preset's full curve. Lets us ship
    /// photographer-grade tonal control today; an interactive draggable
    /// graph editor lands in v0.4.
    var curve: CurvePreset = .linear
    var curveIntensity: Double = 1   // 0...1
    /// Per-color HSL adjustments. Empty (all-zero) by default — no-op.
    var hsl: HSLAdjustments = HSLAdjustments()

    enum CodingKeys: String, CodingKey {
        case brightness, contrast, exposure, saturation, warmth, shadows, highlights, vibrance
        case curve, curveIntensity, hsl
    }
    init() {}
    init(brightness: Double = 0, contrast: Double = 0, exposure: Double = 0,
         saturation: Double = 0, warmth: Double = 0, shadows: Double = 0,
         highlights: Double = 0, vibrance: Double = 0,
         curve: CurvePreset = .linear, curveIntensity: Double = 1,
         hsl: HSLAdjustments = HSLAdjustments()) {
        self.brightness = brightness; self.contrast = contrast; self.exposure = exposure
        self.saturation = saturation; self.warmth = warmth
        self.shadows = shadows; self.highlights = highlights; self.vibrance = vibrance
        self.curve = curve; self.curveIntensity = curveIntensity
        self.hsl = hsl
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        self.contrast   = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        self.exposure   = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        self.saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        self.warmth     = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        self.shadows    = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        self.highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        self.vibrance   = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        self.curve = try c.decodeIfPresent(CurvePreset.self, forKey: .curve) ?? .linear
        self.curveIntensity = try c.decodeIfPresent(Double.self, forKey: .curveIntensity) ?? 1
        self.hsl = try c.decodeIfPresent(HSLAdjustments.self, forKey: .hsl) ?? HSLAdjustments()
    }
}

struct Filters: Codable, Sendable, Equatable {
    var blur: Double = 0         // 0...50
    var noise: Double = 0        // 0...1
    var noiseMono: Bool = true
    var sharpen: Double = 0      // 0...2
    var pixelate: Double = 0     // 0...40
    var hueShift: Double = 0     // -180...180
    /// Radial darkening at the canvas edges. 0 = no vignette, 1 = strong.
    var vignette: Double = 0     // 0...1
    /// Soft-edge falloff radius (0 = hard edge, 1 = very gradual).
    var vignetteFalloff: Double = 0.6  // 0...1
    /// Film-style grain — anisotropic noise with adjustable size. Distinct from
    /// the flat `noise` field (which is per-pixel salt-and-pepper).
    var grain: Double = 0        // 0...1
    /// Grain particle size in pixels (1 = pixel-fine, larger = chunkier).
    var grainSize: Double = 1.5  // 0.5...4

    enum CodingKeys: String, CodingKey {
        case blur, noise, noiseMono, sharpen, pixelate, hueShift
        case vignette, vignetteFalloff, grain, grainSize
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        self.noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? 0
        self.noiseMono = try c.decodeIfPresent(Bool.self, forKey: .noiseMono) ?? true
        self.sharpen = try c.decodeIfPresent(Double.self, forKey: .sharpen) ?? 0
        self.pixelate = try c.decodeIfPresent(Double.self, forKey: .pixelate) ?? 0
        self.hueShift = try c.decodeIfPresent(Double.self, forKey: .hueShift) ?? 0
        self.vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        self.vignetteFalloff = try c.decodeIfPresent(Double.self, forKey: .vignetteFalloff) ?? 0.6
        self.grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? 0
        self.grainSize = try c.decodeIfPresent(Double.self, forKey: .grainSize) ?? 1.5
    }
}

struct Relight: Codable, Sendable, Equatable {
    var enabled: Bool = false
    var position: CGPoint = .init(x: 0.35, y: 0.35)
    var intensity: Double = 0.8
    var radius: Double = 0.55
    var color: ColorRGB = ColorRGB(r: 1.0, g: 0.91, b: 0.69)
    var ambient: Double = -0.2
}

struct SkinRetouch: Codable, Sendable, Equatable {
    var enabled: Bool = false
    var smooth: Double = 0.45
    var evenTone: Double = 0.30
    var deage: Double = 0.20
    var glow: Double = 0.15
}

struct LayerStyles: Codable, Sendable, Equatable {
    var dropShadow = DropShadow()
    var outerGlow = OuterGlow()
    var stroke = Stroke()
    var gradientFill = GradientFill()
}
struct DropShadow: Codable, Sendable, Equatable {
    var enabled = false
    var color: ColorRGB = .black
    var opacity: Double = 0.7
    var distance: Double = 8
    var angle: Double = 135
    var blur: Double = 16
}
struct OuterGlow: Codable, Sendable, Equatable {
    var enabled = false
    var color: ColorRGB = ColorRGB(r: 1, g: 0.85, b: 0.35)
    var opacity: Double = 0.8
    var size: Double = 30
    var spread: Double = 2
}
struct Stroke: Codable, Sendable, Equatable {
    var enabled = false
    var color: ColorRGB = .black
    var size: Double = 6
    var opacity: Double = 1
}
struct GradientFill: Codable, Sendable, Equatable {
    var enabled = false
    var c1: ColorRGB = ColorRGB(r: 1, g: 0.89, b: 0.35)
    var c2: ColorRGB = ColorRGB(r: 1, g: 0.65, b: 0.32)
    var angle: Double = 90
    var opacity: Double = 1
}

struct ColorRGB: Codable, Sendable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1
    static let black = ColorRGB(r: 0, g: 0, b: 0)
    static let white = ColorRGB(r: 1, g: 1, b: 1)
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { nsColor.cgColor }
    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? ns
        self.r = Double(c.redComponent); self.g = Double(c.greenComponent); self.b = Double(c.blueComponent); self.a = Double(c.alphaComponent)
    }
}

enum BlendMode: String, Codable, CaseIterable, Sendable {
    case normal, multiply, screen, overlay, softLight = "soft-light", hardLight = "hard-light"
    case colorDodge = "color-dodge", colorBurn = "color-burn", lighten, darken
    case difference, exclusion, hue, saturation, color, luminosity
    var cgBlend: CGBlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .softLight: return .softLight
        case .hardLight: return .hardLight
        case .colorDodge: return .colorDodge
        case .colorBurn: return .colorBurn
        case .lighten: return .lighten
        case .darken: return .darken
        case .difference: return .difference
        case .exclusion: return .exclusion
        case .hue: return .hue
        case .saturation: return .saturation
        case .color: return .color
        case .luminosity: return .luminosity
        }
    }
}

struct TextContent: Codable, Sendable, Equatable {
    var string: String = "EPIC\nTITLE"
    var fontName: String = "System"    // "System" | "System Rounded" | "System Mono" | "System Serif" | any installed font family
    var fontSize: Double = 220
    var weight: Double = 800           // 100…900
    var italic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    var uppercase: Bool = false        // visual-only transform
    var alignment: String = "center"   // left | center | right
    var lineHeight: Double = 1.05
    var tracking: Double = 0
    var color: ColorRGB = .white
    var anchorX: Double = 0.5
    var anchorY: Double = 0.5

    /// Optional rich-text data (RTF archive). When present, overrides the plain
    /// `string` and provides per-range colors / bold / italic / underline.
    var rtfData: Data?

    // Cached text bounds from the last render (doc coords). Used by the move
    // tool to hit-test + draw handles.
    var lastRenderedBounds: CGRect = .zero

    enum CodingKeys: String, CodingKey {
        case string, fontName, fontSize, weight, italic, underline, strikethrough, uppercase
        case alignment, lineHeight, tracking, color, anchorX, anchorY, rtfData, lastRenderedBounds
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.string = try c.decodeIfPresent(String.self, forKey: .string) ?? "EPIC\nTITLE"
        self.fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "System"
        self.fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 220
        self.weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 800
        self.italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        self.underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        self.strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        self.uppercase = try c.decodeIfPresent(Bool.self, forKey: .uppercase) ?? false
        self.alignment = try c.decodeIfPresent(String.self, forKey: .alignment) ?? "center"
        self.lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.05
        self.tracking = try c.decodeIfPresent(Double.self, forKey: .tracking) ?? 0
        self.color = try c.decodeIfPresent(ColorRGB.self, forKey: .color) ?? .white
        self.anchorX = try c.decodeIfPresent(Double.self, forKey: .anchorX) ?? 0.5
        self.anchorY = try c.decodeIfPresent(Double.self, forKey: .anchorY) ?? 0.5
        self.rtfData = try c.decodeIfPresent(Data.self, forKey: .rtfData)
        self.lastRenderedBounds = try c.decodeIfPresent(CGRect.self, forKey: .lastRenderedBounds) ?? .zero
    }
}

struct GradientContent: Codable, Sendable, Equatable {
    var kind: String = "linear"  // linear | radial
    var c1: ColorRGB = ColorRGB(r: 1.0, g: 0.42, b: 0.53)
    var s1: Double = 0
    var c2: ColorRGB = ColorRGB(r: 1.0, g: 0.77, b: 0.44)
    var s2: Double = 1
    var angle: Double = 45
    var center: CGPoint = .init(x: 0.5, y: 0.5)
    var radius: Double = 0.7
}

struct SolidContent: Codable, Sendable, Equatable {
    var color: ColorRGB = ColorRGB(r: 1.0, g: 0.45, b: 0.25)
}

/// A Photoshop-style Smart Object: keeps the original image (by URL + embedded
/// bytes as fallback) and a non-destructive placement transform. Double-click
/// opens the source in the OS default editor; file-system changes auto-reload.
struct SmartSource: Codable, Sendable, Equatable {
    var sourceURLBookmark: Data?
    var sourcePath: String?
    var sourceBytes: Data?
    var sourceFormat: String = "png"
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var centerX: Double = 0
    var centerY: Double = 0
    var scaleX: Double = 1
    var scaleY: Double = 1
    var rotationDeg: Double = 0
    var flipH: Bool = false
    var flipV: Bool = false
    var edgeOffset: Double = 0
    var edgeFeather: Double = 0
    var edgeThreshold: Double = 0

    enum CodingKeys: String, CodingKey {
        case sourceURLBookmark, sourcePath, sourceBytes, sourceFormat
        case pixelWidth, pixelHeight, centerX, centerY
        case scaleX, scaleY, rotationDeg, flipH, flipV
        case edgeOffset, edgeFeather, edgeThreshold
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceURLBookmark = try c.decodeIfPresent(Data.self, forKey: .sourceURLBookmark)
        self.sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        self.sourceBytes = try c.decodeIfPresent(Data.self, forKey: .sourceBytes)
        self.sourceFormat = try c.decodeIfPresent(String.self, forKey: .sourceFormat) ?? "png"
        self.pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 0
        self.pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 0
        self.centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0
        self.centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0
        self.scaleX = try c.decodeIfPresent(Double.self, forKey: .scaleX) ?? 1
        self.scaleY = try c.decodeIfPresent(Double.self, forKey: .scaleY) ?? 1
        self.rotationDeg = try c.decodeIfPresent(Double.self, forKey: .rotationDeg) ?? 0
        self.flipH = try c.decodeIfPresent(Bool.self, forKey: .flipH) ?? false
        self.flipV = try c.decodeIfPresent(Bool.self, forKey: .flipV) ?? false
        self.edgeOffset = try c.decodeIfPresent(Double.self, forKey: .edgeOffset) ?? 0
        self.edgeFeather = try c.decodeIfPresent(Double.self, forKey: .edgeFeather) ?? 0
        self.edgeThreshold = try c.decodeIfPresent(Double.self, forKey: .edgeThreshold) ?? 0
    }
    // Memberwise-ish init used by DocumentStore.placeSmartImage.
    init(sourcePath: String? = nil,
         sourceBytes: Data? = nil,
         sourceFormat: String = "png",
         pixelWidth: Int,
         pixelHeight: Int,
         centerX: Double,
         centerY: Double,
         scaleX: Double = 1,
         scaleY: Double = 1) {
        self.sourcePath = sourcePath
        self.sourceBytes = sourceBytes
        self.sourceFormat = sourceFormat
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.centerX = centerX
        self.centerY = centerY
        self.scaleX = scaleX
        self.scaleY = scaleY
    }
}

@Observable
final class PXLayer: Identifiable {
    let id: UUID
    var name: String
    var kind: LayerKind
    var visible: Bool = true
    var opacity: Double = 1
    var blend: BlendMode = .normal
    var offset: CGSize = .zero

    // raster image buffer (nil for other kinds). Stored at document resolution.
    var raster: CGImage?

    // type-specific content
    var text: TextContent = TextContent()
    var gradient: GradientContent = GradientContent()
    var solid: SolidContent = SolidContent()
    var smart: SmartSource?     // non-nil → this raster layer is a Smart Object; always rendered from source.

    // per-layer processing
    var adjust = Adjustments()
    var filters = Filters()
    var relight = Relight()
    var skin = SkinRetouch()
    var styles = LayerStyles()
    var studioRelight = StudioRelight()

    init(id: UUID = UUID(), name: String, kind: LayerKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}
