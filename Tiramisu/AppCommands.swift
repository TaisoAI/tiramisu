import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppCommands: Commands {
    @Bindable var store: DocumentStore

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { store.performUndo() }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!store.canUndo)
            Button("Redo") { store.performRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo)
        }
        CommandGroup(replacing: .newItem) {
            Button("New") { newDocument() }
                .keyboardShortcut("n", modifiers: [.command])
            Divider()
            Button("Open…") { openDocument() }
                .keyboardShortcut("o", modifiers: [.command])
            RecentFilesMenu(store: store)
            Divider()
            Button("Place Image…") { placeImage() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Paste Image as New Layer") { pasteImageFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: [.command])
            Button("Save As…") { saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Export PNG…") { exportPNG() }
                .keyboardShortcut("e", modifiers: [.command])
            Button("Copy Composite to Clipboard") { copyCompositeToClipboard() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        CommandMenu("AI") {
            Button("Generative Fill…") { GenerativeFillUI.present(store: store) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Generative Fill Settings…") { GenerativeFillUI.presentSettings() }
        }
        CommandMenu("Select") {
            Button("Deselect") {
                store.clearSelection(); store.invalidate()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(store.selectionPath == nil)
            Divider()
            Menu("Refine Edge") {
                Button("Expand 1 px")  { refineSelection(by: 1) }
                Button("Expand 5 px")  { refineSelection(by: 5) }
                Button("Expand 10 px") { refineSelection(by: 10) }
                Divider()
                Button("Contract 1 px")  { refineSelection(by: -1) }
                Button("Contract 5 px")  { refineSelection(by: -5) }
                Button("Contract 10 px") { refineSelection(by: -10) }
            }
            .disabled(store.selectionPath == nil)
        }
        CommandMenu("Layer") {
            Button("New Paint Layer") { store.addLayer(PXLayer(name: "Paint", kind: .raster)) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Text Layer") { store.addLayer(PXLayer(name: "Text", kind: .text)) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Gradient Layer") { store.addLayer(PXLayer(name: "Gradient", kind: .gradient)) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("New Solid Color Layer") { store.addLayer(PXLayer(name: "Solid", kind: .solid)) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Duplicate Layer") { store.duplicateActive() }
                .keyboardShortcut("d", modifiers: [.command])
            Button("Rasterize Layer") {
                if let id = store.activeLayerID { store.rasterizeLayer(id) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Delete Layer") { store.removeActive() }
                .keyboardShortcut(.delete, modifiers: [.command])
            Divider()
            Menu("Arrange") {
                Button("Fit to Canvas")  { LayerArrange.fitToCanvas(store) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Fill Canvas")    { LayerArrange.fillCanvas(store) }
                    .keyboardShortcut("f", modifiers: [.command, .option, .shift])
                Button("Reset Scale (100%)") { LayerArrange.resetScale(store) }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button("Center on Canvas") { LayerArrange.align(store, to: .center) }
                Divider()
                Button("Align Left")   { LayerArrange.align(store, to: .middleLeft) }
                Button("Align Right")  { LayerArrange.align(store, to: .middleRight) }
                Button("Align Top")    { LayerArrange.align(store, to: .topCenter) }
                Button("Align Bottom") { LayerArrange.align(store, to: .bottomCenter) }
            }
            Divider()
            Button("Remove Background (AI)") { Task { await removeBackground() } }
                .keyboardShortcut("b", modifiers: [.command, .shift])
        }
    }

    /// Refine Edge — expand or contract the active selection by `radius`
    /// doc pixels via CIMorphology + contour re-extraction. No-op when
    /// there's no selection (the menu items are already disabled in that
    /// state, but defensive guard anyway).
    private func refineSelection(by radius: Double) {
        guard let path = store.selectionPath else { return }
        guard let next = SelectionTools.refineEdge(path,
                                                    radiusPx: radius,
                                                    canvasSize: store.canvasSize) else {
            tlog("refineEdge: returned nil for radius=\(radius)")
            return
        }
        store.checkpoint(radius >= 0 ? "Expand Selection" : "Contract Selection")
        store.setSelection(path: next)
        store.invalidate()
    }

    // MARK: - Document

    private func newDocument() {
        if !confirmDiscardChangesIfNeeded() { return }
        store.layers.removeAll()
        store.currentFileURL = nil
        store.isDirty = false
        store.invalidate()
    }

    private func openDocument() {
        if !confirmDiscardChangesIfNeeded() { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [tiramisuType, .json]
        panel.allowedFileTypes = ["tiramisu", "json"]   // belt & suspenders for older selectors
        panel.allowsOtherFileTypes = true
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Open Tiramisu Project"
        panel.message = "Choose a .tiramisu project file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileBookmarks.store(for: url)
        openFile(url: url)
    }

    fileprivate func openFile(url: URL) {
        // Prefer the bookmark-resolved URL if we have one — that's what carries
        // sandbox access after a restart for files on external volumes / iCloud.
        let target = FileBookmarks.resolve(path: url.path) ?? url
        do {
            let data = try FileBookmarks.withScope(target) { try Data(contentsOf: $0) }
            let snap = try JSONDecoder().decode(DocumentSnapshot.self, from: data)
            store.apply(snap)
            store.currentFileURL = target
            store.isDirty = false
            store.recordRecent(target)
            FileBookmarks.store(for: target)
            NSDocumentController.shared.noteNewRecentDocumentURL(target)
        } catch let DecodingError.keyNotFound(key, ctx) {
            presentError("Project is from an older build",
                         detail: "Missing key '\(key.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))\n\n\(ctx.debugDescription)")
        } catch let DecodingError.typeMismatch(type, ctx) {
            presentError("Project format mismatch",
                         detail: "Expected \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))\n\n\(ctx.debugDescription)")
        } catch let DecodingError.dataCorrupted(ctx) {
            presentError("Project file is corrupted",
                         detail: ctx.debugDescription)
        } catch {
            presentError("Could not open document", error: error)
        }
    }

    private func presentError(_ title: String, detail: String) {
        terr("\(title): \(detail)")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func save() {
        if let url = store.currentFileURL {
            writeProject(to: url)
        } else {
            saveAs()
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [tiramisuType]
        panel.nameFieldStringValue = store.currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled.tiramisu"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileBookmarks.store(for: url)
        writeProject(to: url)
        store.currentFileURL = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func writeProject(to url: URL) {
        let target = FileBookmarks.resolve(path: url.path) ?? url
        do {
            let snap = store.makeSnapshot()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snap)
            try FileBookmarks.withScope(target) { resolved in
                // .atomic writes a sibling temp file then renames; on some sandbox
                // + external-volume combos that fails. Fall back to a plain write
                // if the atomic path errors out.
                do {
                    try data.write(to: resolved, options: .atomic)
                } catch {
                    tlog("atomic write failed (\(error.localizedDescription)) — retrying non-atomic")
                    try data.write(to: resolved)
                }
            }
            store.isDirty = false
            store.recordRecent(target)
            FileBookmarks.store(for: target)
            NSDocumentController.shared.noteNewRecentDocumentURL(target)
        } catch {
            presentError("Could not save document", error: error)
        }
    }

    private func confirmDiscardChangesIfNeeded() -> Bool {
        guard store.isDirty, !store.layers.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes."
        alert.informativeText = "Continuing will discard them. Save first?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            return !store.isDirty
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    private func placeImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileBookmarks.store(for: url)
        // Place as a Smart Object so transforms stay non-destructive and AI
        // features (Expand, Remove BG, etc.) can read the original source bytes.
        _ = FileBookmarks.withScope(url) { resolved in
            store.placeSmartImage(from: resolved)
        }
    }

    private func pasteImageFromClipboard() {
        let pb = NSPasteboard.general

        // Try common image data flavors directly off the pasteboard.
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"),
            (NSPasteboard.PasteboardType("public.heic"), "heic"),
            (NSPasteboard.PasteboardType("public.jpeg"), "jpeg"),
            (NSPasteboard.PasteboardType("org.webmproject.webp"), "webp"),
            (.tiff, "tiff"),
        ]
        for (type, ext) in candidates {
            if let data = pb.data(forType: type), !data.isEmpty {
                if let L = store.placeSmartImage(data: data, format: ext) {
                    L.name = "Pasted Image"
                    tlog("Pasted image from clipboard (\(data.count) bytes, \(ext))")
                    return
                }
            }
        }

        // Fallback: a file URL on the pasteboard (e.g. copied from Finder).
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first,
           let data = try? Data(contentsOf: url), !data.isEmpty {
            let ext = url.pathExtension.lowercased().isEmpty ? "png" : url.pathExtension.lowercased()
            if let L = store.placeSmartImage(data: data, format: ext) {
                L.name = url.deletingPathExtension().lastPathComponent
                tlog("Pasted image from file URL clipboard (\(data.count) bytes, \(ext))")
                return
            }
        }

        tlog("Paste: no image data on clipboard (types: \(pb.types?.map(\.rawValue) ?? []))")
        NSSound.beep()
    }

    private func copyCompositeToClipboard() {
        guard let image = LayerRenderer.composite(store: store) else {
            NSSound.beep()
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            NSSound.beep(); return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        // Also offer it as TIFF for apps that prefer it.
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        tlog("Copied composite to clipboard (\(image.width)x\(image.height), \(png.count) bytes)")
    }

    private func exportPNG() {
        guard let image = LayerRenderer.composite(store: store) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = store.currentFileURL?.deletingPathExtension().lastPathComponent ?? "thumbnail"
        panel.nameFieldStringValue += ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            let a = NSAlert()
            a.messageText = "Could not encode PNG"
            a.informativeText = "The canvas couldn't be encoded as PNG. This usually means the image is in an unsupported color space."
            a.alertStyle = .warning
            a.runModal()
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            tlog("exported PNG: \(url.path) (\(data.count) bytes)")
        } catch {
            tlog("exportPNG failed: \(error.localizedDescription)")
            let a = NSAlert()
            a.messageText = "Couldn't save \(url.lastPathComponent)"
            a.informativeText = error.localizedDescription
            a.alertStyle = .warning
            a.runModal()
        }
    }

    private func removeBackground() async {
        guard let layer = store.activeLayer, layer.kind == .raster else {
            NSSound.beep(); tlog("Remove BG: no active raster layer"); return
        }
        // Source image: smart source first (keeps it a smart layer with alpha),
        // otherwise the layer's baked raster.
        let sourceImage: CGImage?
        if let smart = layer.smart {
            sourceImage = SmartObjectEngine.loadSource(smart)
        } else {
            sourceImage = layer.raster
        }
        guard let cg = sourceImage else {
            NSSound.beep(); tlog("Remove BG: layer has no decodable source")
            return
        }
        do {
            store.checkpoint("Remove Background")
            tlog("Remove BG: starting Vision segmentation on \(cg.width)x\(cg.height) image")
            // v0.4: non-destructive — produce a layer mask instead of baking
            // alpha into the source. Mask is stored at source pixel size and
            // applied in canvas coords by the renderer.
            let mask = try BackgroundRemover.mask(from: cg)
            tlog("Remove BG: mask \(mask.width)x\(mask.height)")
            layer.mask = mask
            store.invalidate()
        } catch {
            NSSound.beep()
            terr("Remove BG failed: \(error)")
        }
    }

    private func presentError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// UTI for Tiramisu project files — declared in Info.plist (UTExportedTypeDeclarations
// + CFBundleDocumentTypes). We fetch it here; `exportedAs:` is a no-op if already
// registered by the bundle, and provides a fallback if it isn't.
let tiramisuType: UTType = {
    if let t = UTType("world.hanley.tiramisu.project") { return t }
    return UTType(exportedAs: "world.hanley.tiramisu.project", conformingTo: .json)
}()

// MARK: - Help menu

/// Replaces the default macOS Help menu with Tiramisu-specific items:
/// links to docs, GitHub, bug reporting, and the Welcome dialog re-trigger.
struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Tiramisu Help") { openURL("https://tiramisu.hanley.world/getting-started.html") }
                .keyboardShortcut("?", modifiers: [.command])
            Button("Welcome to Tiramisu…") { WelcomeWindow.show(forced: true) }
            Divider()
            Button("View on GitHub") { openURL("https://github.com/hanley-tech/tiramisu") }
            Button("Report a Bug…") { openURL("https://github.com/hanley-tech/tiramisu/issues/new") }
            Divider()
            Button("Install Local FLUX-Fill…") { GenerativeFillUI.runLocalFluxBootstrap() }
            Divider()
            Button("Visit Website") { openURL("https://tiramisu.hanley.world") }
        }
    }

    private func openURL(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Debug menu

struct DebugCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandMenu("Debug") {
            Button("Show Console") { openWindow(id: "debug-console") }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Reveal Log File") { Log.shared.reveal() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Button(ControlServer.shared.isRunning
                   ? "Stop Control Server (\(Int(ControlServer.shared.port)))"
                   : "Start Control Server (127.0.0.1:7979)") {
                if ControlServer.shared.isRunning {
                    ControlServer.shared.stop()
                } else {
                    if let store = TiramisuAppDelegate.shared.liveStore {
                        ControlServer.shared.start(on: 7878, store: store)
                    }
                }
            }
        }
    }
}

// MARK: - Recent Files submenu

private struct RecentFileButton: View {
    let index: Int
    let url: URL
    @Bindable var store: DocumentStore
    let opener: (URL) -> Void

    var body: some View {
        if index < 9 {
            let char = Character("\(index + 1)")
            Button(url.lastPathComponent) { handle() }
                .keyboardShortcut(KeyEquivalent(char), modifiers: [.command])
        } else {
            Button(url.lastPathComponent) { handle() }
        }
    }
    private func handle() {
        if FileManager.default.fileExists(atPath: url.path) {
            opener(url)
        } else {
            store.removeRecent(url)
            NSSound.beep()
        }
    }
}

struct RecentFilesMenu: View {
    @Bindable var store: DocumentStore

    var body: some View {
        Menu("Open Recent") {
            if store.recentFiles.isEmpty {
                Text("No Recent Files").foregroundStyle(.secondary)
            } else {
                ForEach(Array(store.recentFiles.enumerated()), id: \.element) { index, url in
                    RecentFileButton(index: index, url: url, store: store, opener: openFileFromRecent)
                }
                Divider()
                Button("Clear Menu") { store.clearRecents() }
            }
        }
    }

    fileprivate func openFileFromRecent(url: URL) {
        let target = FileBookmarks.resolve(path: url.path) ?? url
        do {
            let data = try FileBookmarks.withScope(target) { try Data(contentsOf: $0) }
            let snap = try JSONDecoder().decode(DocumentSnapshot.self, from: data)
            store.apply(snap)
            store.currentFileURL = target
            store.isDirty = false
            store.recordRecent(target)
            FileBookmarks.store(for: target)
            NSDocumentController.shared.noteNewRecentDocumentURL(target)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not open document"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
