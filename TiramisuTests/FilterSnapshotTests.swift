import XCTest
import SnapshotTesting
import CoreGraphics
import AppKit
@testable import Tiramisu

/// Visual regression for each per-layer filter exposed in the Adjust panel.
/// Pinning these locks down the CIFilter chain in `LayerRenderer.applyFilters`
/// — the most likely place for silent rendering drift across macOS minor
/// versions.
@MainActor
final class FilterSnapshotTests: XCTestCase {

    func testBlur() throws {
        try renderFilter(name: "blur") { f in f.blur = 18 }
    }

    func testSharpen() throws {
        try renderFilter(name: "sharpen") { f in f.sharpen = 1.5 }
    }

    func testNoiseColor() throws {
        try renderFilter(name: "noise-color") { f in f.noise = 0.6; f.noiseMono = false }
    }

    func testNoiseMono() throws {
        try renderFilter(name: "noise-mono") { f in f.noise = 0.6; f.noiseMono = true }
    }

    func testPixelate() throws {
        try renderFilter(name: "pixelate") { f in f.pixelate = 24 }
    }

    func testHueShiftWarm() throws {
        // +60° drives the photo toward orange/red.
        try renderFilter(name: "hue-shift-warm") { f in f.hueShift = 60 }
    }

    func testHueShiftCool() throws {
        // -90° drives toward blue/green.
        try renderFilter(name: "hue-shift-cool") { f in f.hueShift = -90 }
    }

    func testVignetteSubtle() throws {
        try renderFilter(name: "vignette-subtle") { f in
            f.vignette = 0.6
            f.vignetteFalloff = 0.6
        }
    }

    func testVignetteHard() throws {
        try renderFilter(name: "vignette-hard") { f in
            f.vignette = 1.0
            f.vignetteFalloff = 0.2
        }
    }

    func testGrainFine() throws {
        try renderFilter(name: "grain-fine") { f in
            f.grain = 0.5
            f.grainSize = 1.0
        }
    }

    func testGrainCoarse() throws {
        try renderFilter(name: "grain-coarse") { f in
            f.grain = 0.7
            f.grainSize = 3.0
        }
    }

    // MARK: - Helpers

    private func renderFilter(name: String, configure: (inout Filters) -> Void) throws {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 480, height: 320)
        store.backgroundColor = ColorRGB(r: 0.10, g: 0.10, b: 0.12)
        store.layers = []

        let cafe = try fixture(named: "cafe", ext: "jpg")
        guard let photo = store.placeSmartImage(data: cafe, format: "jpg") else {
            return XCTFail("placeSmartImage failed for cafe fixture")
        }
        var filters = photo.filters
        configure(&filters)
        photo.filters = filters
        store.invalidate()

        let cg = LayerRenderer.composite(store: store)!
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        // CIFilter math drifts slightly across macOS point releases; same
        // precision floor as the LayerStyle snapshots.
        assertSnapshot(of: img, as: .image(precision: 0.96), named: name)
    }

    private func fixture(named name: String, ext: String) throws -> Data {
        let bundle = Bundle(for: FilterSnapshotTests.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw NSError(domain: "FilterSnapshotTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Fixture \(name).\(ext) is not in the test bundle."
            ])
        }
        return try Data(contentsOf: url)
    }
}
