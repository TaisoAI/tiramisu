import AppKit
import SwiftUI

/// Presents `ReimagineSheet` as a borderless utility-style window. Stays
/// open across re-rolls so the user can iterate without re-summoning.
/// Same shape as `GenerativeFillUI.presentSettings()`.
@MainActor
enum ReimagineSheetPresenter {
    private static var window: NSWindow?

    static func present(store: DocumentStore) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSHostingController(rootView: ReimagineSheet().environment(store))
        let win = NSWindow(contentViewController: host)
        win.title = "Reimagine"
        win.styleMask = [.titled, .closable, .resizable]
        win.isReleasedWhenClosed = false
        win.center()

        // Track close so the next ⌘⇧R rebuilds rather than reopens a stale instance.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { _ in
            window = nil
        }

        window = win
        win.makeKeyAndOrderFront(nil)
    }
}
