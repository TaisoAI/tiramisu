import SwiftUI
import AppKit

/// First-run welcome dialog. Shows on initial launch (and re-shows from
/// Help → Welcome to Tiramisu…). Stores a "don't show again" preference
/// in UserDefaults under `world.hanley.tiramisu.welcomeShown`.
@MainActor
enum WelcomeWindow {
    private static let prefsKey = "world.hanley.tiramisu.welcomeShown"

    /// Show the welcome dialog if the user hasn't dismissed it before.
    /// Pass `forced: true` to always show it (e.g. from the Help menu).
    static func showIfNeeded() {
        if UserDefaults.standard.bool(forKey: prefsKey) { return }
        show(forced: false)
    }

    static func show(forced: Bool) {
        let alert = NSAlert()
        alert.messageText = "Welcome to Tiramisu."
        alert.informativeText = """
        Tiramisu has layers. Image editing has layers.

        A free, open-source, AI-native image editor for macOS — made for the creators shipping daily across YouTube, IG, TikTok, X, LinkedIn, and the rest. No subscription. No Pro tier. No telemetry.

        Pick a starting point — you can change everything later.
        """

        // App icon
        if let appIcon = NSApp.applicationIconImage {
            alert.icon = appIcon
        }

        // "Don't show again" checkbox lives on the accessory view
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        stack.orientation = .horizontal
        stack.alignment = .centerY
        let dontShow = NSButton(checkboxWithTitle: "Don't show this on startup",
                                target: nil, action: nil)
        // If they're invoking from Help menu (forced), default the checkbox
        // unchecked. Otherwise check it — they probably want to dismiss the
        // first-run flow once they've seen it.
        dontShow.state = forced ? .off : .on
        stack.addArrangedSubview(dontShow)
        alert.accessoryView = stack

        alert.addButton(withTitle: "Get Started")
        alert.addButton(withTitle: "Set up Local AI…")
        alert.addButton(withTitle: "Visit Website")

        let response = alert.runModal()

        // Store the preference based on the checkbox.
        if dontShow.state == .on {
            UserDefaults.standard.set(true, forKey: prefsKey)
        }

        switch response {
        case .alertSecondButtonReturn:
            GenerativeFillUI.runLocalFluxBootstrap()
        case .alertThirdButtonReturn:
            if let url = URL(string: "https://tiramisu.hanley.world") {
                NSWorkspace.shared.open(url)
            }
        default:
            break // Get Started — just dismiss
        }
    }

    /// Wipe the preference (development helper — call from Debug menu if needed).
    static func resetPreference() {
        UserDefaults.standard.removeObject(forKey: prefsKey)
    }
}
