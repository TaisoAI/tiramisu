import SwiftUI
import AppKit

/// Transparent NSView mounted behind the canvas to capture two-finger
/// trackpad pan events (which SwiftUI gestures don't see) and forward
/// them as viewport pan deltas.
///
/// Mouse-wheel scroll (`hasPreciseScrollingDeltas == false`) is ignored
/// here so a mouse user keeps the click-and-drag pan tool's behavior.
/// Pinch zoom keeps using `MagnifyGesture` over in CanvasView; this
/// view only handles the pan axis.
struct CanvasScrollCatcher: NSViewRepresentable {

    /// Called with the raw `scrollingDelta{X,Y}` from each event. The
    /// signs already reflect the user's "natural scrolling" preference
    /// at the OS level — apply them directly to the viewport pan.
    let onPan: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollCatchView {
        let v = ScrollCatchView()
        v.onPan = onPan
        return v
    }

    func updateNSView(_ nsView: ScrollCatchView, context: Context) {
        nsView.onPan = onPan
    }

    final class ScrollCatchView: NSView {
        var onPan: ((CGFloat, CGFloat) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func scrollWheel(with event: NSEvent) {
            // Only act on trackpad gestures (precise deltas). Mouse wheel
            // events are passed up the responder chain so other handlers
            // can take them.
            guard event.hasPreciseScrollingDeltas else {
                super.scrollWheel(with: event)
                return
            }
            // ⌘+two-finger-scroll could be wired to zoom in a future revision —
            // for now we only do pan. Pinch zoom already works via MagnifyGesture.
            onPan?(event.scrollingDeltaX, event.scrollingDeltaY)
        }
    }
}
