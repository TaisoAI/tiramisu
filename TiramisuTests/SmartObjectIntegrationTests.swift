import XCTest
import SnapshotTesting
import CoreGraphics
import AppKit
@testable import Tiramisu

/// Integration test for the "creator imports a photo" workflow:
/// build a synthetic CGImage in memory → place it as a Smart Object →
/// composite the canvas → save the document → reopen it → assert the
/// smart-source bytes still match the original.
///
/// Smart objects keep the original image bytes in `layer.smart.sourceBytes`
/// so transforms remain non-destructive. Any bug in encode/decode path,
/// document Codable, or the placement pipeline shows up here.
@MainActor
final class SmartObjectIntegrationTests: XCTestCase {

    func testPlaceTransformSaveReopenPreservesSmartSource() throws {
        // 1. Build a synthetic 320×180 raster: orange-to-purple gradient with
        //    a bright dot in the middle so we can verify pixels later.
        let synthetic = makeSyntheticImage(width: 320, height: 180)
        let pngData = encodePNG(synthetic)
        XCTAssertGreaterThan(pngData.count, 200, "Synthetic PNG suspiciously empty")

        // 2. Place it as a Smart Object on a 1280×720 canvas.
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 1280, height: 720)
        store.backgroundColor = ColorRGB(r: 0.05, g: 0.05, b: 0.10)
        store.layers = []

        guard let placed = store.placeSmartImage(data: pngData, format: "png") else {
            return XCTFail("placeSmartImage returned nil for valid PNG data")
        }
        XCTAssertEqual(placed.kind, .raster, "Smart objects must be raster-kind layers")
        XCTAssertNotNil(placed.smart, "Placed layer must have a SmartSource")
        XCTAssertEqual(placed.smart?.sourceFormat, "png")
        XCTAssertEqual(placed.smart?.sourceBytes?.count, pngData.count,
                       "SmartSource must preserve the original byte count")

        // 3. Mutate transforms (typical: scale + center moves) — should not
        //    touch the underlying bytes.
        placed.smart?.scaleX = 1.5
        placed.smart?.scaleY = 1.5
        placed.smart?.centerX = 700
        placed.smart?.centerY = 400
        XCTAssertEqual(placed.smart?.sourceBytes?.count, pngData.count,
                       "Transforming a smart object must not re-encode source bytes")

        // 4. Composite — should not blow up.
        guard LayerRenderer.composite(store: store) != nil else {
            return XCTFail("Composite returned nil for store with smart-object layer")
        }

        // 5. Save to disk + reopen via the same path AppCommands.writeProject uses.
        let snap = store.makeSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(snap)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiramisu-smart-\(UUID().uuidString).tiramisu")
        try jsonData.write(to: tmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reloadedData = try Data(contentsOf: tmp)
        let reloadedSnap = try JSONDecoder().decode(DocumentSnapshot.self, from: reloadedData)
        let restored = DocumentStore()
        restored.apply(reloadedSnap)

        // 6. Smart source bytes must survive the disk round-trip exactly.
        XCTAssertEqual(restored.layers.count, 1)
        let restoredLayer = restored.layers[0]
        guard let restoredSmart = restoredLayer.smart else {
            return XCTFail("Reloaded layer lost its SmartSource")
        }
        XCTAssertEqual(restoredSmart.sourceBytes?.count, pngData.count)
        XCTAssertEqual(restoredSmart.sourceBytes, pngData,
                       "Smart-object source bytes diverged across save/reopen — non-destructive editing is broken")
        XCTAssertEqual(restoredSmart.sourceFormat, "png")
        // Transform survived too
        XCTAssertEqual(restoredSmart.scaleX, 1.5)
        XCTAssertEqual(restoredSmart.centerX, 700)

        // 7. Reloaded store renders identically to the original.
        guard LayerRenderer.composite(store: restored) != nil else {
            return XCTFail("Reloaded store failed to composite")
        }
    }

    // MARK: - Helpers

    private func makeSyntheticImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Diagonal gradient orange → purple
        let colors = [CGColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1),
                      CGColor(red: 0.4, green: 0.15, blue: 0.6, alpha: 1)] as CFArray
        let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: width, y: height),
                               options: [])
        // Bright dot in the middle for visual fingerprinting
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: width/2 - 12, y: height/2 - 12, width: 24, height: 24))
        return ctx.makeImage()!
    }

    private func encodePNG(_ image: CGImage) -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])!
    }
}
