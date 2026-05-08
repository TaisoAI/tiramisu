import Foundation
import Network
import AppKit

/// Tiny HTTP server bound to 127.0.0.1 that exposes the document for
/// programmatic control (primarily for AI test harnesses). Zero auth — do
/// not expose beyond localhost.
///
/// Endpoints:
///   GET  /state         → JSON snapshot of document + layer tree
///   GET  /canvas.png    → PNG of the current composite
///   GET  /window        → JSON with the main window's CGWindowID + frame, so a CLI
///                         caller can `screencapture -l <id> out.png`. (We don't
///                         capture pixels in-process: screen-recording TCC perms are
///                         per-app and a subprocess of Tiramisu inherits *its*
///                         perms, not Terminal's. Capturing from the calling
///                         shell sidesteps the prompt entirely.)
///   GET  /log/tail      → plain-text tail of the log (last 200 lines)
///   POST /action        → JSON body with {"type":"…", …}
///       types:
///         - "newDocument"
///         - "addLayer"      { "kind": "raster|text|gradient|solid" }
///         - "selectLayer"   { "id": "<uuid>" }
///         - "selectLayerByName" { "name": "Hero text" }
///         - "removeActive"
///         - "setText"       { "id": "<uuid>", "value": "..." }
///         - "setTextColor"  { "id": "<uuid>", "hex": "ff0000" }       // whole layer
///         - "setLayerOpacity" { "id":"...", "opacity": 0.5 }
///         - "toggleVisible" { "id": "..." }
///         - "moveLayer"     { "id":"...", "x":0,"y":0 }               // absolute offset
///         - "setCanvas"     { "width": 1920, "height": 1080 }
///         - "setBackground" { "hex": "0d1220" }
///         - "savePath"      { "path": "/tmp/test.tiramisu" }
///         - "loadPath"      { "path": "/tmp/test.tiramisu" }
///         - "exportPNG"     { "path": "/tmp/out.png" }
///         - "setInspectorTab" { "tab": "properties|adjust|effects" }
///         - "setSection"    { "title": "Lighting", "open": true }
///         - "clickAt"       { "x": 320, "y": 480 }                     // window-content coords (top-left origin)
///         - "keystroke"     { "keys": "cmd+s" }                        // mods: cmd|opt|shift|ctrl, key: char or "return"/"escape"/"tab"/"space"
@MainActor
final class ControlServer {
    static let shared = ControlServer()
    private var listener: NWListener?
    private var store: DocumentStore?
    private(set) var isRunning = false
    private(set) var port: UInt16 = 0

    func start(on port: Int, store: DocumentStore) {
        if isRunning { stop() }
        self.store = store
        do {
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            let listener = try NWListener(using: params,
                                          on: NWEndpoint.Port(integerLiteral: UInt16(port)))
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                Task { @MainActor in self?.receive(on: conn) }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.port = UInt16(port)
            self.isRunning = true
            tlog("ControlServer: listening on 127.0.0.1:\(port)")
        } catch {
            terr("ControlServer start failed: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        tlog("ControlServer: stopped")
    }

    // MARK: - Connection handling

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { conn.cancel(); return }
            Task { @MainActor in
                let response = self.handle(request: data)
                conn.send(content: response, completion: .contentProcessed({ _ in conn.cancel() }))
            }
        }
    }

    private func handle(request: Data) -> Data {
        guard let head = String(data: request.prefix(4096), encoding: .utf8),
              let firstLine = head.split(separator: "\r\n").first else {
            return httpResponse(status: 400, body: "Bad request")
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return httpResponse(status: 400, body: "Bad request") }
        let method = String(parts[0])
        let pathRaw = String(parts[1])
        let path = pathRaw.split(separator: "?").first.map(String.init) ?? pathRaw

        switch (method, path) {
        case ("GET", "/state"):         return handleState()
        case ("GET", "/canvas.png"):    return handleCanvasPNG()
        case ("GET", "/window"):        return handleWindowInfo()
        case ("GET", "/log/tail"):      return handleLogTail()
        case ("GET", "/"):              return httpResponse(status: 200, body: "Tiramisu Control Server. See /state, /canvas.png, /window, /action")
        case ("POST", "/action"):       return handleAction(request: request)
        default:
            return httpResponse(status: 404, body: "Not found: \(method) \(path)")
        }
    }

    // MARK: - Handlers

    private func handleState() -> Data {
        guard let store else { return httpResponse(status: 503, body: "No store") }
        let snap: [String: Any] = [
            "canvas": ["width": Int(store.canvasSize.width), "height": Int(store.canvasSize.height)],
            "background": hex(store.backgroundColor),
            "activeLayerID": store.activeLayerID?.uuidString ?? NSNull(),
            "isDirty": store.isDirty,
            "currentFile": store.currentFileURL?.path ?? NSNull(),
            "layers": store.layers.map { L -> [String: Any] in
                [
                    "id": L.id.uuidString,
                    "name": L.name,
                    "kind": L.kind.rawValue,
                    "visible": L.visible,
                    "opacity": L.opacity,
                    "blend": L.blend.rawValue,
                    "offsetX": L.offset.width,
                    "offsetY": L.offset.height,
                    "textString": L.kind == .text ? L.text.string : NSNull()
                ]
            }
        ]
        return jsonResponse(snap)
    }

    private func handleCanvasPNG() -> Data {
        guard let store else { return httpResponse(status: 503, body: "No store") }
        guard let cg = LayerRenderer.composite(store: store) else {
            return httpResponse(status: 500, body: "Composite failed")
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return httpResponse(status: 500, body: "Encode failed")
        }
        return httpResponse(status: 200, contentType: "image/png", bodyData: png)
    }

    /// Return the main window's CGWindowID + frame. Callers can then use
    ///     screencapture -x -l <windowID> out.png
    /// to grab a UI screenshot — Terminal already has Screen Recording
    /// permission, so this avoids the per-app TCC dance.
    private func handleWindowInfo() -> Data {
        guard let window = mainWindow() else {
            let dump = NSApp.windows.map {
                ["windowID": $0.windowNumber, "visible": $0.isVisible, "title": $0.title] as [String: Any]
            }
            return jsonResponse(["error": "No main window", "all": dump])
        }
        let f = window.frame
        return jsonResponse([
            "windowID": window.windowNumber,
            "title": window.title,
            "frame": ["x": f.minX, "y": f.minY, "width": f.width, "height": f.height],
            "captureHint": "screencapture -x -l \(window.windowNumber) out.png"
        ])
    }

    private func mainWindow() -> NSWindow? {
        // Prefer the main window; otherwise the first visible non-panel.
        if let w = NSApp.mainWindow, !(w is NSPanel) { return w }
        return NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
    }

    private func handleLogTail() -> Data {
        let entries = Log.console.entries.suffix(200)
        let text = entries.map { "\(ISO8601DateFormatter().string(from: $0.date)) [\($0.level)] \($0.message)" }.joined(separator: "\n")
        return httpResponse(status: 200, contentType: "text/plain", body: text)
    }

    private func handleAction(request: Data) -> Data {
        guard let store else { return httpResponse(status: 503, body: "No store") }
        // Parse body — very naive split on \r\n\r\n
        let sep = Data([0x0d, 0x0a, 0x0d, 0x0a])
        guard let range = request.range(of: sep) else { return httpResponse(status: 400, body: "No body") }
        let body = request.subdata(in: range.upperBound..<request.endIndex)
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let type = obj["type"] as? String else {
            return httpResponse(status: 400, body: "Bad JSON")
        }

        func layer(_ id: String) -> PXLayer? {
            store.layers.first(where: { $0.id.uuidString == id })
        }

        switch type {
        case "newDocument":
            store.layers.removeAll(); store.currentFileURL = nil; store.isDirty = false; store.invalidate()
        case "addLayer":
            let kind = (obj["kind"] as? String).flatMap(LayerKind.init(rawValue:)) ?? .raster
            let L = PXLayer(name: kind.rawValue.capitalized, kind: kind)
            store.addLayer(L)
            return jsonResponse(["ok": true, "id": L.id.uuidString])
        case "selectLayer":
            if let id = obj["id"] as? String { store.activeLayerID = UUID(uuidString: id) }
        case "selectLayerByName":
            guard let name = obj["name"] as? String else {
                return httpResponse(status: 400, body: "Missing 'name'")
            }
            guard let L = store.layers.first(where: { $0.name == name }) else {
                return httpResponse(status: 404, body: "No layer named '\(name)'")
            }
            store.activeLayerID = L.id
            return jsonResponse(["ok": true, "id": L.id.uuidString])
        case "removeActive":
            store.removeActive()
        case "setText":
            if let id = obj["id"] as? String, let v = obj["value"] as? String, let L = layer(id), L.kind == .text {
                L.text.string = v
                L.text.rtfData = nil
                store.invalidate()
            }
        case "setTextColor":
            if let id = obj["id"] as? String, let hex = obj["hex"] as? String,
               let L = layer(id), L.kind == .text, let nsc = NSColor.fromHex(hex) {
                L.text.color = ColorRGB(nsc)
                L.text.rtfData = nil
                store.invalidate()
            }
        case "setLayerOpacity":
            if let id = obj["id"] as? String, let o = obj["opacity"] as? Double, let L = layer(id) {
                L.opacity = o; store.invalidate()
            }
        case "toggleVisible":
            if let id = obj["id"] as? String, let L = layer(id) { L.visible.toggle(); store.invalidate() }
        case "moveLayer":
            if let id = obj["id"] as? String, let L = layer(id) {
                L.offset = CGSize(width: obj["x"] as? Double ?? 0, height: obj["y"] as? Double ?? 0)
                store.invalidate()
            }
        case "setCanvas":
            if let w = obj["width"] as? Double, let h = obj["height"] as? Double {
                store.canvasSize = CGSize(width: w, height: h); store.invalidate()
            }
        case "setBackground":
            if let hex = obj["hex"] as? String, let nsc = NSColor.fromHex(hex) {
                store.backgroundColor = ColorRGB(nsc); store.invalidate()
            }
        case "savePath":
            if let path = obj["path"] as? String {
                let url = URL(fileURLWithPath: path)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(store.makeSnapshot()) {
                    try? data.write(to: url, options: .atomic)
                    store.currentFileURL = url; store.isDirty = false
                }
            }
        case "loadPath":
            if let path = obj["path"] as? String,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let snap = try? JSONDecoder().decode(DocumentSnapshot.self, from: data) {
                store.apply(snap)
                store.currentFileURL = URL(fileURLWithPath: path)
            }
        case "exportPNG":
            if let path = obj["path"] as? String,
               let cg = LayerRenderer.composite(store: store) {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
        case "placeImagePath":
            // Load a PNG/JPEG from disk and place as a Smart Object scaled to fit the canvas.
            // Uses the smart-image data path so AI features (Expand etc.) can see source bytes.
            if let path = obj["path"] as? String {
                let url = URL(fileURLWithPath: path)
                if let layer = store.placeSmartImage(from: url) {
                    return jsonResponse(["ok": true, "id": layer.id.uuidString])
                }
                return httpResponse(status: 500, body: "Could not place image at \(path)")
            }
            return httpResponse(status: 400, body: "Missing 'path'")
        case "runExpand":
            // Run the Expand pipeline against the current store using the active
            // generative-fill backend (Replicate or Local FLUX-Fill). Synchronous from
            // the caller's perspective: blocks the HTTP response until done.
            let prompt = (obj["prompt"] as? String) ?? "seamless continuation of the existing photo, matching texture, color and lighting, photorealistic"
            let service: GenerativeFillService
            switch GenerativeFillSettings.backend {
            case .localFlux:
                guard LocalFluxFillService.isInstalled else {
                    return httpResponse(status: 412, body: "Local FLUX-Fill not installed (mflux missing)")
                }
                // No cache override — let the user's HF_HOME env var win, or default.
                service = LocalFluxFillService(modelHFCacheDir: nil)
            case .replicate:
                if GenerativeFillSettings.apiKey.isEmpty {
                    return httpResponse(status: 412, body: "Replicate API key not configured")
                }
                service = ReplicateFillService(apiKey: GenerativeFillSettings.apiKey,
                                                modelVersion: GenerativeFillSettings.model)
            }
            let group = DispatchGroup()
            group.enter()
            var threwError: String?
            Task { @MainActor in
                do {
                    try await GenerativeFillCoordinator.fill(store: store, mode: .expand, prompt: prompt, service: service)
                } catch {
                    threwError = error.localizedDescription
                }
                group.leave()
            }
            group.wait()
            if let threwError {
                return httpResponse(status: 500, body: "Expand failed: \(threwError)")
            }
            return jsonResponse(["ok": true])
        case "showWelcome":
            WelcomeWindow.show(forced: true)
        case "setZoom":
            guard let z = obj["zoom"] as? Double else {
                return httpResponse(status: 400, body: "Need 'zoom' (Double, 0.05–8)")
            }
            store.viewportZoom = max(0.05, min(8, z))
            store.viewportZoomBase = store.viewportZoom
            store.invalidate()
        case "alignLayer":
            // Mirrors the Move-tool alignment buttons. Useful for headless testing
            // of LayerArrange without synthesizing UI clicks.
            guard let anchorRaw = obj["anchor"] as? String else {
                return httpResponse(status: 400, body: "Need 'anchor'")
            }
            let map: [String: LayerArrange.Anchor] = [
                "topLeft": .topLeft, "topCenter": .topCenter, "topRight": .topRight,
                "middleLeft": .middleLeft, "center": .center, "middleRight": .middleRight,
                "bottomLeft": .bottomLeft, "bottomCenter": .bottomCenter, "bottomRight": .bottomRight
            ]
            guard let a = map[anchorRaw] else {
                return httpResponse(status: 400, body: "Unknown anchor '\(anchorRaw)' — use topLeft|topCenter|topRight|middleLeft|center|middleRight|bottomLeft|bottomCenter|bottomRight")
            }
            LayerArrange.align(store, to: a)
        case "setInspectorTab":
            // The InspectorView reads its tab from @AppStorage("ui.inspector.tab"),
            // so writing the same key flips the UI immediately via SwiftUI's KVO bridge.
            guard let tab = obj["tab"] as? String,
                  ["properties", "adjust", "effects"].contains(tab) else {
                return httpResponse(status: 400, body: "tab must be properties|adjust|effects")
            }
            UserDefaults.standard.set(tab, forKey: "ui.inspector.tab")
        case "setSection":
            // InspectorSection persists open-state under
            // "world.hanley.tiramisu.section.<title>" — same key the SwiftUI view binds to.
            guard let title = obj["title"] as? String,
                  let open = obj["open"] as? Bool else {
                return httpResponse(status: 400, body: "Need 'title' (string) and 'open' (bool)")
            }
            UserDefaults.standard.set(open, forKey: "world.hanley.tiramisu.section.\(title)")
        case "clickAt":
            // Synthetic mouse click at window-content-relative coords (top-left origin,
            // matching how /window.png is captured). Translates to global screen coords
            // and posts a CGEvent — works against the app's own UI without prompting
            // for accessibility permission as long as the events target our process.
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double else {
                return httpResponse(status: 400, body: "Need 'x' and 'y'")
            }
            guard let window = mainWindow(), let view = window.contentView else {
                return httpResponse(status: 503, body: "No main window")
            }
            // Convert: window-content (top-left, points) → AppKit window (bottom-left)
            //         → screen coords (CGEvent uses screen with origin at top-left).
            let viewPoint = NSPoint(x: x, y: view.bounds.height - y)
            let windowPoint = view.convert(viewPoint, to: nil)
            let screenPoint = window.convertPoint(toScreen: windowPoint)
            // CGEvent's screen origin is top-left; NSScreen is bottom-left — flip.
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            let cgPoint = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                mouseCursorPosition: cgPoint, mouseButton: .left)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                              mouseCursorPosition: cgPoint, mouseButton: .left)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        case "keystroke":
            guard let keys = obj["keys"] as? String else {
                return httpResponse(status: 400, body: "Need 'keys' (e.g. 'cmd+s', 'return', 'a')")
            }
            guard postKeystroke(keys) else {
                return httpResponse(status: 400, body: "Could not parse keystroke '\(keys)'")
            }
        default:
            return httpResponse(status: 400, body: "Unknown action type: \(type)")
        }
        return jsonResponse(["ok": true])
    }

    /// Parse "cmd+shift+a" / "return" / "tab" into a CGEvent and post it. Modifier
    /// keys: cmd | opt | alt | shift | ctrl. Special keys: return | enter | escape | tab | space | delete.
    private func postKeystroke(_ spec: String) -> Bool {
        let parts = spec.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last else { return false }
        var flags: CGEventFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command":      flags.insert(.maskCommand)
            case "opt", "alt", "option": flags.insert(.maskAlternate)
            case "shift":               flags.insert(.maskShift)
            case "ctrl", "control":     flags.insert(.maskControl)
            default: return false
            }
        }
        let key: CGKeyCode
        switch last {
        case "return", "enter": key = 0x24
        case "escape", "esc":   key = 0x35
        case "tab":             key = 0x30
        case "space":           key = 0x31
        case "delete":          key = 0x33
        case "left":            key = 0x7B
        case "right":           key = 0x7C
        case "down":            key = 0x7D
        case "up":              key = 0x7E
        default:
            // Single-character keys: a-z, 0-9. Use a static table.
            guard last.count == 1, let k = Self.charKeyCode[Character(last)] else { return false }
            key = k
        }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return true
    }

    /// Apple-standard ANSI virtual key codes for the basic alphanumerics. Enough for
    /// agent automation (`cmd+s`, `cmd+z`, `return`, etc.); not a full keyboard map.
    private static let charKeyCode: [Character: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25,
        "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E
    ]

    // MARK: - HTTP plumbing

    private func jsonResponse(_ obj: Any) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        return httpResponse(status: 200, contentType: "application/json", bodyData: data)
    }

    private func httpResponse(status: Int, contentType: String = "text/plain; charset=utf-8",
                               body: String = "") -> Data {
        httpResponse(status: status, contentType: contentType, bodyData: Data(body.utf8))
    }

    private func httpResponse(status: Int, contentType: String = "text/plain; charset=utf-8",
                               bodyData: Data) -> Data {
        let reason: String = [200: "OK", 400: "Bad Request", 404: "Not Found",
                              500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(bodyData)
        return data
    }

    private func hex(_ c: ColorRGB) -> String {
        String(format: "#%02x%02x%02x",
               Int((c.r * 255).rounded()),
               Int((c.g * 255).rounded()),
               Int((c.b * 255).rounded()))
    }
}
