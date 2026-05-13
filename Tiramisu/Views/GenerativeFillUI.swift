import SwiftUI
import AppKit

@MainActor
enum GenerativeFillUI {

    // MARK: - Local FLUX-Fill bootstrap

    /// Launches the Local FLUX-Fill setup script in Terminal. The script lives
    /// either bundled in the app's Resources (preferred for distributed builds)
    /// or in `scripts/bootstrap.sh` of the source repo (Debug builds).
    /// We copy the script to a stable user-writeable location and chmod +x
    /// before asking Terminal to run it, so HF login prompts and stdout work.
    static func runLocalFluxBootstrap() {
        let installer = NSAlert()
        installer.messageText = "Install Local FLUX-Fill?"
        installer.informativeText = """
        This will open Terminal and run the setup script:

          • install uv (Python toolchain) if missing
          • install mflux (FLUX inference for Apple Silicon)
          • prompt for your Hugging Face login
          • download the FLUX-Fill model (~24 GB)

        Idempotent — safe to re-run. You can quit Terminal at any time.
        """
        installer.addButton(withTitle: "Open Terminal & Install")
        installer.addButton(withTitle: "Cancel")
        guard installer.runModal() == .alertFirstButtonReturn else { return }

        guard let scriptURL = locateBootstrapScript() else {
            let a = NSAlert()
            a.messageText = "bootstrap.sh not found"
            a.informativeText = """
            The Local FLUX-Fill setup script could not be found inside the app bundle or the source repo.

            Workaround: clone the source repo and run ./scripts/bootstrap.sh manually:
              git clone https://github.com/TaisoAI/tiramisu.git
              cd tiramisu && ./scripts/bootstrap.sh
            """
            a.alertStyle = .warning
            a.runModal()
            return
        }

        // Copy to ~/.tiramisu/bootstrap.sh so it's a stable, executable location
        // even when the source path was a sandboxed Resources/ inside the app bundle.
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tiramisu", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir,
                                                  withIntermediateDirectories: true)
        let stableURL = cacheDir.appendingPathComponent("bootstrap.sh")
        try? FileManager.default.removeItem(at: stableURL)
        do {
            try FileManager.default.copyItem(at: scriptURL, to: stableURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: stableURL.path)
        } catch {
            let a = NSAlert()
            a.messageText = "Could not stage bootstrap.sh"
            a.informativeText = error.localizedDescription
            a.alertStyle = .warning
            a.runModal()
            return
        }

        // Drive Terminal via AppleScript: open a new tab and exec the script.
        let escaped = stableURL.path.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\\"\(escaped)\\""
        end tell
        """
        if let script = NSAppleScript(source: appleScript) {
            var err: NSDictionary?
            script.executeAndReturnError(&err)
            if let err {
                tlog("AppleScript run-bootstrap failed: \(err)")
                let a = NSAlert()
                a.messageText = "Could not open Terminal"
                a.informativeText = "Open Terminal yourself and run:\n\n  \(stableURL.path)"
                a.runModal()
            }
        }
    }

    private static func locateBootstrapScript() -> URL? {
        // 1. Inside the app bundle (preferred for distributed builds).
        if let bundled = Bundle.main.url(forResource: "bootstrap", withExtension: "sh") {
            return bundled
        }
        // 2. Source-repo fallback for Debug builds: walk up from the executable
        //    looking for `scripts/bootstrap.sh`. Works when running from
        //    DerivedData or from ~/Applications/Tiramisu.app (post-build hook).
        let exec = Bundle.main.bundleURL
        for depth in 0..<6 {
            var candidate = exec
            for _ in 0..<depth { candidate = candidate.deletingLastPathComponent() }
            let probe = candidate.appendingPathComponent("scripts/bootstrap.sh")
            if FileManager.default.isReadableFile(atPath: probe.path) { return probe }
        }
        return nil
    }

    // MARK: - Generative Fill modal

    static func present(store: DocumentStore) {
        let alert = NSAlert()
        alert.messageText = "Generative Fill"
        let hasSelection = store.selectionRect != nil
        let suggestExpand = activeLayerHasEmptyBands(store: store)
        alert.informativeText = {
            if suggestExpand { return "Active layer doesn't fill the canvas — Expand mode is preselected. Side bands will be outpainted." }
            if hasSelection { return "Mode + prompt to fill the marquee selection." }
            return "No marquee — entire canvas will be the fill region."
        }()

        // Build a compact stack: backend picker, mode picker, prompt.
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        // Backend / model picker
        let backendLabel = NSTextField(labelWithString: "Model")
        let backendPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        let fluxTitle = LocalFluxFillService.isInstalled
            ? "Local FLUX-Fill  ·  on-device"
            : "Local FLUX-Fill  (mflux not installed)"
        backendPopup.addItem(withTitle: "Replicate  ·  FLUX-Fill  (cloud)")
        backendPopup.addItem(withTitle: fluxTitle)
        let backendIndex: Int
        switch GenerativeFillSettings.backend {
        case .replicate:    backendIndex = 0
        case .localFlux:    backendIndex = 1
        case .openaicompat: backendIndex = 0  // fallback to Replicate
        }
        backendPopup.selectItem(at: backendIndex)
        stack.addArrangedSubview(backendLabel)
        stack.addArrangedSubview(backendPopup)

        let modeLabel = NSTextField(labelWithString: "Mode")
        let modePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        modePopup.addItem(withTitle: "Generate — fill with prompted content")
        modePopup.addItem(withTitle: "Replace — substitute what's there")
        modePopup.addItem(withTitle: "Remove — erase, fill with surroundings")
        modePopup.addItem(withTitle: "Expand — outpaint empty canvas around the layer")
        if suggestExpand { modePopup.selectItem(at: GenerativeFillMode.expand.rawValue) }
        stack.addArrangedSubview(modeLabel)
        stack.addArrangedSubview(modePopup)

        let field = NSTextField(string: "")
        field.placeholderString = "e.g., 'extend the person's left arm naturally'"
        field.frame.size.width = 420
        stack.addArrangedSubview(NSTextField(labelWithString: "Prompt (optional for Remove / Expand)"))
        stack.addArrangedSubview(field)

        stack.frame.size = NSSize(width: 420, height: 162)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Generate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Persist the chosen backend for next time.
        switch backendPopup.indexOfSelectedItem {
        case 1:  GenerativeFillSettings.backend = .localFlux
        default: GenerativeFillSettings.backend = .replicate
        }

        let modeRaw = modePopup.indexOfSelectedItem
        let mode = GenerativeFillMode(rawValue: modeRaw) ?? .generate
        var prompt = field.stringValue
        switch mode {
        case .remove:
            if prompt.isEmpty { prompt = "natural background continuation, seamless, no objects, photorealistic" }
        case .expand:
            // Anti-subject language up front. Without it, FLUX-Fill (and
            // Replicate flux-fill-dev) happily invents people, faces, and
            // objects in the empty bands even when given edge-padded
            // priors. The "background only" + "empty space" phrasing
            // consistently keeps the model focused on continuing texture.
            if prompt.isEmpty { prompt = "seamless continuation of the existing photo, matching texture, color and lighting, photorealistic background only, empty space, no people, no faces, no figures, no subjects, no objects" }
        default: break
        }

        let service: GenerativeFillService
        switch GenerativeFillSettings.backend {
        case .localFlux:
            guard LocalFluxFillService.isInstalled else {
                let a = NSAlert()
                a.messageText = "Local FLUX-Fill not installed"
                a.informativeText = LocalFluxFillService.setupInstructions
                a.addButton(withTitle: "Install Local FLUX-Fill…")
                a.addButton(withTitle: "Switch to Replicate (cloud)")
                a.addButton(withTitle: "Cancel")
                let r = a.runModal()
                if r == .alertFirstButtonReturn {
                    runLocalFluxBootstrap()
                } else if r == .alertSecondButtonReturn {
                    GenerativeFillSettings.backend = .replicate
                    presentSettings()
                }
                return
            }
            // No cache override — let the subprocess inherit the user's HF_HOME
            // env var, or fall back to the default (~/.cache/huggingface).
            service = LocalFluxFillService(modelHFCacheDir: nil)
        case .replicate:
            if GenerativeFillSettings.apiKey.isEmpty {
                presentSettings()
                return
            }
            service = ReplicateFillService(apiKey: GenerativeFillSettings.apiKey,
                                            modelVersion: GenerativeFillSettings.model)
        case .openaicompat:
            let provider = OpenAICompatibleProvider()
            guard provider.isConfigured else {
                let a = NSAlert()
                a.messageText = "OpenAI-compatible provider not configured"
                a.informativeText = "Add a base URL and API key in Settings → AI Providers."
                a.addButton(withTitle: "Open Settings")
                a.addButton(withTitle: "Cancel")
                if a.runModal() == .alertFirstButtonReturn { presentSettings() }
                return
            }
            service = OpenAICompatibleFillService(
                baseURL: provider.baseURL, apiKey: provider.apiKey,
                model: provider.model, authStyle: provider.authStyle)
        }

        let win = ProgressWindow.show(title: "Generative Fill", detail: "Starting…")
        win.setIndeterminate(true)
        Task { @MainActor in
            do {
                try await GenerativeFillCoordinator.fill(store: store, mode: mode, prompt: prompt, service: service) { msg in
                    win.update(detail: msg, fraction: 0)
                }
                win.close()
            } catch {
                win.close()
                let a = NSAlert(); a.messageText = "Generative Fill failed"
                a.informativeText = error.localizedDescription
                a.alertStyle = .warning; a.runModal()
            }
        }
    }

    /// True if the active layer is a smart-object raster that doesn't already
    /// cover the full canvas — i.e. Expand mode would actually do something.
    private static func activeLayerHasEmptyBands(store: DocumentStore) -> Bool {
        guard let layer = store.activeLayer, let smart = layer.smart else { return false }
        let lw = Double(smart.pixelWidth) * smart.scaleX
        let lh = Double(smart.pixelHeight) * smart.scaleY
        let lx = smart.centerX - lw / 2
        let ly = smart.centerY - lh / 2
        let cw = store.canvasSize.width
        let ch = store.canvasSize.height
        let leftBand = lx > 1
        let rightBand = (lx + lw) < (cw - 1)
        let topBand = ly > 1
        let bottomBand = (ly + lh) < (ch - 1)
        return leftBand || rightBand || topBand || bottomBand
    }

    static func presentSettings() {
        let alert = NSAlert()
        alert.messageText = "Generative Fill Settings"
        alert.informativeText = "Pick a backend. Replicate runs in the cloud; Local FLUX-Fill runs on your Mac via mflux."

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        // Backend picker — two options only
        let backendLabel = NSTextField(labelWithString: "Backend")
        let backendPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        backendPopup.addItem(withTitle: "Replicate (cloud, FLUX-Fill, top quality)")
        let fluxLabel: String = {
            if LocalFluxFillService.isInstalled {
                return "Local FLUX-Fill (offline, mflux ✓ detected — best local quality)"
            }
            return "Local FLUX-Fill (offline, mflux NOT installed — see Help)"
        }()
        backendPopup.addItem(withTitle: fluxLabel)
        switch GenerativeFillSettings.backend {
        case .replicate:      backendPopup.selectItem(at: 0)
        case .localFlux:      backendPopup.selectItem(at: 1)
        case .openaicompat:   break
        }
        stack.addArrangedSubview(backendLabel)
        stack.addArrangedSubview(backendPopup)

        let keyLabel = NSTextField(labelWithString: "Replicate API Key")
        let keyField = NSSecureTextField(string: GenerativeFillSettings.apiKey)
        keyField.placeholderString = "r8_..."
        keyField.frame.size.width = 420
        let modelLabel = NSTextField(labelWithString: "Replicate Model (owner/name)")
        let modelField = NSTextField(string: GenerativeFillSettings.model)
        modelField.frame.size.width = 420
        stack.addArrangedSubview(keyLabel)
        stack.addArrangedSubview(keyField)
        stack.addArrangedSubview(modelLabel)
        stack.addArrangedSubview(modelField)

        stack.frame.size = NSSize(width: 420, height: 200)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        if !LocalFluxFillService.isInstalled {
            alert.addButton(withTitle: "Install Local FLUX-Fill…")
        }
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            switch backendPopup.indexOfSelectedItem {
            case 0: GenerativeFillSettings.backend = .replicate
            case 1: GenerativeFillSettings.backend = .localFlux
            default: break
            }
            GenerativeFillSettings.apiKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            GenerativeFillSettings.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .alertSecondButtonReturn where !LocalFluxFillService.isInstalled:
            runLocalFluxBootstrap()
        default:
            break
        }
    }
}

/// Tiny non-blocking progress window with a determinate bar + status line.
@MainActor
final class ProgressWindow {
    private let window: NSWindow
    private let bar: NSProgressIndicator
    private let detailField: NSTextField
    private let percentField: NSTextField
    private var phaseStart: Date = Date()
    private var clockTimer: Timer?
    private var phaseLabel: String = ""

    static func show(title: String, detail: String) -> ProgressWindow {
        let w = ProgressWindow(title: title, detail: detail)
        w.window.makeKeyAndOrderFront(nil)
        return w
    }

    private init(title: String, detail: String) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 80))

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 44, width: 420, height: 16))
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        bar.doubleValue = 0
        bar.style = .bar
        content.addSubview(bar)
        self.bar = bar

        let detailField = NSTextField(labelWithString: detail)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.frame = NSRect(x: 20, y: 18, width: 360, height: 16)
        content.addSubview(detailField)
        self.detailField = detailField

        let percentField = NSTextField(labelWithString: "0%")
        percentField.font = .systemFont(ofSize: 11, weight: .medium)
        percentField.alignment = .right
        percentField.frame = NSRect(x: 380, y: 18, width: 60, height: 16)
        content.addSubview(percentField)
        self.percentField = percentField

        self.window = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = content
        window.title = title
        window.center()
        window.isReleasedWhenClosed = false
        // Float above other windows (incl. our own MainWindow) so it can't
        // get hidden behind the canvas while a long generation is in flight.
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    func update(detail: String, fraction: Double) {
        // Reset elapsed clock if the phase label changed.
        if detail != phaseLabel {
            phaseLabel = detail
            phaseStart = Date()
            startClockIfNeeded()
        }
        refreshDetail()
        if fraction > 0 {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
            percentField.stringValue = "\(Int(fraction * 100))%"
            stopClock()
        }
    }

    func setIndeterminate(_ value: Bool) {
        bar.isIndeterminate = value
        if value { bar.startAnimation(nil); startClockIfNeeded() }
        else { bar.stopAnimation(nil); stopClock() }
        percentField.stringValue = value ? "" : "0%"
    }

    func close() {
        stopClock()
        window.orderOut(nil)
    }

    // MARK: - elapsed-time clock

    private func startClockIfNeeded() {
        stopClock()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDetail() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func refreshDetail() {
        let elapsed = Date().timeIntervalSince(phaseStart)
        let pretty: String = {
            if elapsed < 60 { return String(format: "%.0fs", elapsed) }
            let m = Int(elapsed) / 60, s = Int(elapsed) % 60
            return "\(m)m \(s)s"
        }()
        detailField.stringValue = phaseLabel.isEmpty ? pretty : "\(phaseLabel) — \(pretty)"
    }
}
