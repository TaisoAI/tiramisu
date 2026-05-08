import XCTest
import SnapshotTesting
import CoreGraphics
import AppKit
@testable import Tiramisu

/// Visual gallery of every preset in the `AdjustPreset.library`. Each test
/// loads the same source photo, applies a preset's `Adjustments`, and
/// snapshots the rendered output. The collection serves two purposes:
///   1. Pipeline regression — drift in any color-correction filter is
///      visually obvious in the diff.
///   2. Marketing — the gallery on quality.html doubles as proof of
///      what each named look ("Punchy", "Cinematic", …) actually does.
@MainActor
final class AdjustPresetSnapshotTests: XCTestCase {

    func testOriginal()  throws { try renderPreset(id: "original")  }
    func testPunchy()    throws { try renderPreset(id: "punchy")    }
    func testCinematic() throws { try renderPreset(id: "cinematic") }
    func testPastel()    throws { try renderPreset(id: "pastel")    }
    func testFaded()     throws { try renderPreset(id: "faded")     }
    func testWarm()      throws { try renderPreset(id: "warm")      }
    func testCool()      throws { try renderPreset(id: "cool")      }
    func testBlackAndWhite() throws { try renderPreset(id: "bw")    }
    func testAutoEnhance() throws {
        // Auto-Enhance is a separate Adjustments target (not in the
        // preset library), but lives in the same conceptual gallery.
        try renderAdjust(name: "auto-enhance", adjustments: AdjustPreset.auto)
    }

    func testVibrancePositive() throws {
        // Vibrance protects already-saturated pixels — boosts low-saturation
        // areas more. The diff vs. flat saturation is in the muted regions.
        try renderAdjust(name: "vibrance-positive",
                         adjustments: Adjustments(vibrance: 0.7))
    }

    func testVibranceNegative() throws {
        try renderAdjust(name: "vibrance-negative",
                         adjustments: Adjustments(vibrance: -0.7))
    }

    // MARK: - Helpers

    private func renderPreset(id: String) throws {
        guard let preset = AdjustPreset.library.first(where: { $0.id == id }) else {
            return XCTFail("Preset id '\(id)' not in AdjustPreset.library")
        }
        try renderAdjust(name: id, adjustments: preset.target)
    }

    private func renderAdjust(name: String, adjustments: Adjustments) throws {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 480, height: 320)
        store.backgroundColor = ColorRGB(r: 0.10, g: 0.10, b: 0.12)
        store.layers = []

        let cafe = try fixture(named: "cafe", ext: "jpg")
        guard let photo = store.placeSmartImage(data: cafe, format: "jpg") else {
            return XCTFail("placeSmartImage failed for cafe fixture")
        }
        photo.adjust = adjustments
        store.invalidate()

        let cg = LayerRenderer.composite(store: store)!
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        assertSnapshot(of: img, as: .image(precision: 0.96), named: name)
    }

    private func fixture(named name: String, ext: String) throws -> Data {
        let bundle = Bundle(for: AdjustPresetSnapshotTests.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw NSError(domain: "AdjustPresetSnapshotTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Fixture \(name).\(ext) is not in the test bundle."
            ])
        }
        return try Data(contentsOf: url)
    }
}
