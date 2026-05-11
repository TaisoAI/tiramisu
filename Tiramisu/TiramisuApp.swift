import SwiftUI
import AppKit

@main
struct TiramisuApp: App {
    @State private var store = DocumentStore()
    @NSApplicationDelegateAdaptor(TiramisuAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Tiramisu") {
            MainWindow()
                .environment(store)
                .frame(minWidth: 1280, minHeight: 800)
                .task {
                    appDelegate.attach(store: store)
                    let isUITest = ProcessInfo.processInfo.arguments.contains("--ui-test")
                    if store.controlServerEnabled && !isUITest {
                        ControlServer.shared.start(on: store.controlServerPort, store: store)
                    }
                    if !isUITest {
                        // Session restoration: if the previous session ended
                        // with a saved .tira file open, reload it. If the
                        // file moved/was deleted, fall back to the welcome
                        // flow. Suppresses the Welcome window when a doc
                        // restores cleanly.
                        if let url = DocumentStore.pendingRestoreURL() {
                            TiramisuApp.loadFile(url: url, into: store)
                        } else {
                            WelcomeWindow.showIfNeeded()
                        }
                    }
                }
                .onOpenURL { url in
                    TiramisuApp.loadFile(url: url, into: store)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            AppCommands(store: store)
            HelpCommands()
            DebugCommands()
        }

        Window("Debug Console", id: "debug-console") {
            DebugConsoleView()
        }
        .defaultSize(width: 920, height: 440)

        // Standard macOS Settings window (⌘,). v0.6 ships one pane:
        // AI Providers. v0.6.1 will add Routing + Privacy.
        Settings {
            TabView {
                AIProvidersSettings()
                    .tabItem { Label("AI Providers", systemImage: "sparkles") }
            }
            .frame(minWidth: 580, minHeight: 460)
        }
    }

    @MainActor
    static func loadFile(url: URL, into store: DocumentStore) {
        let ext = url.pathExtension.lowercased()
        let target = FileBookmarks.resolve(path: url.path) ?? url
        if ext == "tira" || ext == "tiramisu" || ext == "json" {
            do {
                let data = try FileBookmarks.withScope(target) { try Data(contentsOf: $0) }
                let snap = try JSONDecoder().decode(DocumentSnapshot.self, from: data)
                store.apply(snap)
                store.currentFileURL = target
                store.isDirty = false
                store.recordRecent(target)
                FileBookmarks.store(for: target)
                NSDocumentController.shared.noteNewRecentDocumentURL(target)
                tlog("opened project: \(target.path)")
            } catch {
                tlog("open failed: \(error)")
                let alert = NSAlert()
                alert.messageText = "Could not open \(target.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        } else {
            _ = FileBookmarks.withScope(target) { store.placeSmartImage(from: $0) }
            tlog("placed image from: \(target.path)")
        }
    }
}

@MainActor
final class TiramisuAppDelegate: NSObject, NSApplicationDelegate {
    static let shared = TiramisuAppDelegate()
    private weak var store: DocumentStore?
    var liveStore: DocumentStore? { store }
    private var pending: [URL] = []

    func attach(store: DocumentStore) {
        self.store = store
        let buffered = pending
        pending.removeAll()
        for u in buffered { TiramisuApp.loadFile(url: u, into: store) }
    }

    nonisolated func application(_ application: NSApplication, open urls: [URL]) {
        // AppKit delivers this on the main thread already; hop to MainActor for Swift 6 compliance.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let store = self.store {
                for u in urls { TiramisuApp.loadFile(url: u, into: store) }
            } else {
                self.pending.append(contentsOf: urls)
            }
        }
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // In UI-test mode, let closing the last window quit the app so the
        // XCUITest runner can terminate cleanly without the user-visible
        // "are you sure?" save prompts that block teardown otherwise.
        ProcessInfo.processInfo.arguments.contains("--ui-test")
    }
}
