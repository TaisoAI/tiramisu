import Testing
import Foundation
@testable import Tiramisu

@MainActor
@Suite("Undo/redo integration — realistic editing histories")
struct UndoRedoIntegrationTests {

    /// A realistic creator session: add three layers, mutate one, undo
    /// past the mutations, redo partway, verify the store ends up at the
    /// expected state. This exercises the undo stack across more than two
    /// operations — the surface where coalescing bugs and stack-corruption
    /// regressions actually live.
    @Test("Realistic edit sequence undoes + redoes to expected states")
    func multiStepUndoRedo() {
        let store = DocumentStore()
        store.layers = []

        // Build initial state: 3 layers + a property change.
        let bg = PXLayer(name: "Background", kind: .gradient)
        let title = PXLayer(name: "Title", kind: .text)
        let badge = PXLayer(name: "Badge", kind: .solid)
        store.addLayer(bg)        // op 1
        store.addLayer(title)     // op 2
        store.addLayer(badge)     // op 3
        // Property change goes through checkpoint() the way AppCommands
        // do it for slider drags; the test mirrors that explicitly.
        store.checkpoint("Set Badge Opacity")
        badge.opacity = 0.4       // op 4

        #expect(store.layers.map(\.name) == ["Background", "Title", "Badge"])
        // (badge ref still valid here — no apply() has run yet)
        #expect(store.layers[2].opacity == 0.4)
        #expect(store.canUndo)
        #expect(!store.canRedo)

        // Undo all 4 operations — store should be empty + clean.
        store.performUndo()       // undo op 4: opacity → 1.0
        #expect(store.layers[2].opacity == 1.0,
                "Undoing the opacity change should restore default opacity")

        store.performUndo()       // undo op 3: remove badge
        #expect(store.layers.map(\.name) == ["Background", "Title"])

        store.performUndo()       // undo op 2: remove title
        #expect(store.layers.map(\.name) == ["Background"])

        store.performUndo()       // undo op 1: remove background
        #expect(store.layers.isEmpty)
        #expect(!store.canUndo, "All operations undone — undo stack should be empty")
        #expect(store.canRedo, "Redo stack should now have all 4 operations")

        // Redo the first 2 — back to [Background, Title], no badge yet.
        store.performRedo()       // redo op 1
        store.performRedo()       // redo op 2
        #expect(store.layers.map(\.name) == ["Background", "Title"])

        // New op while mid-redo wipes the redo stack (standard editor behavior).
        let extra = PXLayer(name: "Extra", kind: .raster)
        store.addLayer(extra)
        #expect(store.layers.map(\.name) == ["Background", "Title", "Extra"])
        #expect(!store.canRedo,
                "Adding a new layer while there's an outstanding redo stack must clear it")
    }

    /// Checkpoint coalescing with the same coalesce key should fold
    /// repeated operations into a single undo step. AppCommands uses this
    /// for slider drags so a hundred opacity-change events across one
    /// gesture undo as a single op.
    ///
    /// Important detail: `store.apply(_:)` rebuilds `store.layers` from
    /// the snapshot, replacing each PXLayer instance with a fresh one.
    /// So after an undo, holding a local `let layer = ...` reference is
    /// stale — that PXLayer is no longer in the store's layers array.
    /// Always re-read through `store.layers[...]` after a perform-undo/redo.
    @Test("Repeated checkpoints with same coalesce key share one undo step")
    func coalescedSliderDragUndoesAsOneStep() {
        let store = DocumentStore()
        store.layers = []
        let layer = PXLayer(name: "Hero", kind: .text)
        store.addLayer(layer)

        let undosBeforeDrag = store.undoStack.count

        // Simulate a slider drag emitting 5 checkpoints with the same key.
        for opacity in [0.9, 0.8, 0.7, 0.6, 0.5] {
            store.checkpoint("Slider opacity", coalesceWith: "opacity-drag")
            layer.opacity = opacity
        }

        #expect(store.undoStack.count == undosBeforeDrag + 1,
                "Five coalesced checkpoints must collapse to one undo entry, got \(store.undoStack.count - undosBeforeDrag)")

        // Ending coalescing then changing again creates a fresh step.
        store.endCoalescing()
        store.checkpoint("Final tweak")
        layer.opacity = 0.42
        #expect(store.undoStack.count == undosBeforeDrag + 2)

        // Single undo should jump back past the post-drag tweak in one step.
        // After apply(), store.layers contains fresh PXLayer instances —
        // re-read through the store, not via the now-stale `layer`.
        store.performUndo()
        let restored = store.layers.first!
        #expect(restored.opacity == 0.5,
                "Undoing the post-drag tweak should leave the layer at the drag's final value, got \(restored.opacity)")

        // One more undo should jump back past the entire coalesced drag.
        store.performUndo()
        let restored2 = store.layers.first!
        #expect(restored2.opacity == 1.0,
                "Undoing the coalesced drag should restore default opacity")
    }
}
