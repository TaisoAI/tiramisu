import XCTest
import SnapshotTesting
import CoreGraphics
import AppKit
@testable import Tiramisu

/// "Kitchen sink" rendering test — every supported feature on at once.
/// If any individual feature regresses, this composite renders differently
/// from its golden and the test fails. Higher signal than 16 individual
/// tests because feature *interactions* (e.g. drop shadow + outer glow on
/// the same layer, opacity + blend mode in combination) are exercised
/// directly.
@MainActor
final class MaxComplexityRenderTests: XCTestCase {

    func testEveryFeatureOnAtOnceRenders() throws {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 800, height: 600)
        store.backgroundColor = ColorRGB(r: 0.04, g: 0.05, b: 0.10)
        store.layers = []

        // Layer 1 — solid bg color (also tested in isolation, here for the stack).
        let solid = PXLayer(name: "solid bg", kind: .solid)
        solid.solid = SolidContent(color: ColorRGB(r: 0.10, g: 0.12, b: 0.18))
        store.layers.append(solid)

        // Layer 2 — gradient overlay with reduced opacity + screen blend.
        let gradient = PXLayer(name: "gradient", kind: .gradient)
        gradient.gradient.kind = "linear"
        gradient.gradient.angle = 135
        gradient.gradient.c1 = ColorRGB(r: 0.85, g: 0.20, b: 0.50)
        gradient.gradient.c2 = ColorRGB(r: 0.20, g: 0.10, b: 0.45)
        gradient.opacity = 0.7
        gradient.blend = .screen
        store.layers.append(gradient)

        // Layer 3 — Text with EVERY style enabled simultaneously.
        let title = PXLayer(name: "kitchen sink", kind: .text)
        title.text.string = "ALL\nON"
        title.text.fontName = "System"
        title.text.fontSize = 200
        title.text.weight = 800
        title.text.alignment = "center"
        title.text.color = .white
        title.styles.dropShadow.enabled = true
        title.styles.dropShadow.color = .black
        title.styles.dropShadow.opacity = 0.7
        title.styles.dropShadow.distance = 12
        title.styles.dropShadow.angle = 135
        title.styles.dropShadow.blur = 20
        title.styles.outerGlow.enabled = true
        title.styles.outerGlow.color = ColorRGB(r: 1.0, g: 0.85, b: 0.35)
        title.styles.outerGlow.opacity = 0.85
        title.styles.outerGlow.size = 40
        title.styles.stroke.enabled = true
        title.styles.stroke.color = .black
        title.styles.stroke.size = 6
        title.styles.stroke.opacity = 1.0
        // Adjustments + filters on the same layer
        title.adjust.brightness = 0.05
        title.adjust.contrast = 0.10
        title.adjust.saturation = -0.05
        title.filters.blur = 0.0  // intentionally 0 — proves no-op renderer path
        store.layers.append(title)

        // Layer 4 — gradient layer with opacity + multiply blend on top
        // (compositing-against-everything-below stress test).
        let multiply = PXLayer(name: "vignette", kind: .gradient)
        multiply.gradient.kind = "linear"
        multiply.gradient.angle = 90
        multiply.gradient.c1 = ColorRGB(r: 1, g: 1, b: 1, a: 1)
        multiply.gradient.c2 = ColorRGB(r: 0.4, g: 0.4, b: 0.4, a: 1)
        multiply.opacity = 0.5
        multiply.blend = .multiply
        store.layers.append(multiply)

        // Composite the canvas.
        guard let cg = LayerRenderer.composite(store: store) else {
            return XCTFail("Kitchen-sink composite returned nil")
        }
        XCTAssertEqual(cg.width, 800)
        XCTAssertEqual(cg.height, 600)

        // PNG round-trip — proves the composite's color space is exportable.
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: cg.width, height: cg.height)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG encode failed for kitchen-sink composite")
        }
        XCTAssertGreaterThan(pngData.count, 5_000,
                             "Kitchen-sink PNG suspiciously tiny — renderer may be producing empty pixels")

        // Snapshot golden — feature-interaction regressions show up as a diff.
        // Looser precision because text antialiasing + CIFilter blur both
        // drift slightly across macOS minor versions.
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: 800, height: 600))
        assertSnapshot(of: nsImage, as: .image(precision: 0.95))
    }
}
