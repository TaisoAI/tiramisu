import Testing
import Foundation
@testable import Tiramisu

@MainActor
@Suite("Document edit cycle — open → edit → save → reopen → edit again")
struct DocumentEditCycleTests {

    /// Realistic creator session: build a doc, save it, "reopen" by loading
    /// from disk into a fresh store, make further edits, save again, reopen
    /// once more. Asserts the final on-disk state matches what should be
    /// there after both edit cycles.
    ///
    /// This is the test that catches "the file format silently degrades
    /// after multiple save cycles" — the kind of bug that wouldn't fire
    /// in a single-shot disk round-trip test but accumulates over a
    /// real editing session.
    @Test("File format survives two save→reopen→edit→save cycles")
    func twoEditCyclesPreserveAllState() throws {
        // Cycle 1: Build initial doc with 1 layer, save.
        let session1 = DocumentStore()
        session1.canvasSize = CGSize(width: 1280, height: 720)
        session1.backgroundColor = ColorRGB(r: 0.06, g: 0.08, b: 0.12)
        session1.layers = []
        let bg = PXLayer(name: "Background", kind: .gradient)
        bg.gradient.angle = 90
        session1.addLayer(bg)

        let path1 = try writeProject(session1)
        defer { try? FileManager.default.removeItem(at: path1) }

        let initialSize = try fileSize(path1)
        #expect(initialSize > 100, "Saved project file is empty")

        // Cycle 2: Load from disk, add 2 more layers, change canvas size,
        // mutate non-default fields, save.
        let session2 = try reopen(path1)
        #expect(session2.layers.count == 1, "Reopen lost the original layer")

        session2.canvasSize = CGSize(width: 1920, height: 1080)
        let title = PXLayer(name: "Hero Title", kind: .text)
        title.text.string = "EPIC\nSESSION"
        title.text.fontSize = 220
        title.opacity = 0.85
        title.blend = .multiply
        title.styles.dropShadow.enabled = true
        title.styles.dropShadow.distance = 14
        session2.addLayer(title)

        let badge = PXLayer(name: "Badge", kind: .solid)
        badge.solid = SolidContent(color: ColorRGB(r: 0.95, g: 0.20, b: 0.25))
        session2.addLayer(badge)

        let path2 = try writeProject(session2)
        defer { try? FileManager.default.removeItem(at: path2) }

        // Cycle 3: Final reopen — assert everything from both edit cycles
        // is present and exact.
        let session3 = try reopen(path2)

        #expect(session3.layers.count == 3,
                "After 2 edit cycles, expected 3 layers, got \(session3.layers.count)")
        #expect(session3.canvasSize == CGSize(width: 1920, height: 1080),
                "Canvas resize across save did not survive")

        // Layer 0 — the original background.
        #expect(session3.layers[0].name == "Background")
        #expect(session3.layers[0].kind == .gradient)
        #expect(session3.layers[0].gradient.angle == 90)

        // Layer 1 — the title added in cycle 2.
        let restoredTitle = session3.layers[1]
        #expect(restoredTitle.name == "Hero Title")
        #expect(restoredTitle.kind == .text)
        #expect(restoredTitle.text.string == "EPIC\nSESSION")
        #expect(restoredTitle.text.fontSize == 220)
        #expect(abs(restoredTitle.opacity - 0.85) < 0.001)
        #expect(restoredTitle.blend == .multiply)
        #expect(restoredTitle.styles.dropShadow.enabled == true)
        #expect(restoredTitle.styles.dropShadow.distance == 14)

        // Layer 2 — the badge.
        let restoredBadge = session3.layers[2]
        #expect(restoredBadge.name == "Badge")
        #expect(restoredBadge.kind == .solid)
        #expect(abs(restoredBadge.solid.color.r - 0.95) < 0.001)

        // Reopened doc is clean (not dirty).
        #expect(!session3.isDirty,
                "Freshly reopened document should not be flagged dirty")

        // File grew between cycles (more layers + more state).
        let finalSize = try fileSize(path2)
        #expect(finalSize > initialSize,
                "Cycle 2's file (\(finalSize) bytes) should be larger than cycle 1's (\(initialSize) bytes)")
    }

    // MARK: - Helpers (mirror AppCommands.writeProject / loadFile path)

    private func writeProject(_ store: DocumentStore) throws -> URL {
        let snap = store.makeSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snap)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiramisu-cycle-\(UUID().uuidString).tiramisu")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func reopen(_ url: URL) throws -> DocumentStore {
        let data = try Data(contentsOf: url)
        let snap = try JSONDecoder().decode(DocumentSnapshot.self, from: data)
        let store = DocumentStore()
        store.apply(snap)
        return store
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }
}
