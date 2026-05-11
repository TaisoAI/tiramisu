import SwiftUI
import AppKit
import CoreGraphics

/// Sheet presented for the AI → Reimagine Whole Image command. Shows
/// the live canvas snapshot, a provider/model selector with a
/// color-coded cost line (driven by the provider's `costModel` and the
/// `QuotaTracker`), the user's prompt, and a Reimagine button.
///
/// Each successful generation lands a new layer above the active one;
/// the sheet stays open so the user can re-roll. Cancel dismisses.
struct ReimagineSheet: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: String = ""
    @State private var selectedProviderID: String = GeminiProvider.idValue
    @State private var geminiModelID: String = GeminiProvider.defaultModelID
    @State private var geminiAvailableModels: [GeminiImageService.DiscoveredModel] = []
    @State private var snapshotImage: NSImage?
    @State private var rolling: Bool = false
    @State private var lastError: String?
    @State private var sequenceIndex: Int = 1
    @State private var copyFeedback: Bool = false
    /// Live log lines from the in-flight Reimagine. Cleared on each new
    /// run. The terminal panel reads from this. Persisting across runs
    /// would conflate history; we have the cloud-audit.log for that.
    @State private var logLines: [String] = []
    /// The in-flight generation task. Stored so Cancel can cancel it.
    @State private var runTask: Task<Void, Never>?
    /// Per-prompt Local FLUX options. Seeded from UserDefaults (Settings
    /// acts as the persistent default); user can override per-generation.
    @State private var fluxStrength: Double = Double(LocalFluxProvider().selectedStrength)
    @State private var fluxSteps: Int = LocalFluxProvider().selectedSteps
    /// When the current Reimagine call started. nil when idle.
    @State private var rollStarted: Date?
    /// Updated once per second while rolling so the elapsed-seconds
    /// display refreshes without us recomputing every frame.
    @State private var elapsedTick: Date = Date()
    /// Drives the spinner pulse + the elapsed-time text.
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var candidates: [any AIImageProvider] {
        AIProviders.candidates(for: .reimagine).filter { $0.isConfigured || $0.id == GeminiProvider.idValue }
    }

    private var activeProvider: any AIImageProvider {
        candidates.first(where: { $0.id == selectedProviderID }) ?? GeminiProvider()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                snapshotPanel
                    .frame(width: 280, height: 220)
                controlsPanel
            }
            .padding(20)

            // Terminal-style live log panel. Always visible because
            // "see how the sausage is made" is the v0.6 trust pitch.
            // Auto-scrolls to the latest line. Clears on each new run.
            terminalPanel
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            Divider()

            HStack {
                Text("Estimates based on published rates · check provider dashboard for actual usage")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    runTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(rolling ? "Reimagining… \(elapsedDisplay)" : "Reimagine") {
                    runTask = Task { await runReimagine() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || rolling || !activeProvider.isConfigured)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
        }
        // Sheet is sized to host the terminal panel comfortably.
        // Resizable upward — user can drag the window taller if they
        // want a longer log scrollback during a slow run.
        .frame(minWidth: 820, minHeight: 640, idealHeight: 680)
        .onAppear {
            snapshotImage = composeSnapshotNSImage()
            geminiModelID = GeminiProvider().selectedModelID
            // Reuse the same dynamic-model fetch the Settings pane uses,
            // so the dropdown reflects what the user's API key can
            // actually call rather than a hard-coded enum.
            if !GeminiProvider().apiKey.isEmpty {
                Task {
                    if let list = try? await GeminiProvider().availableModels() {
                        await MainActor.run {
                            geminiAvailableModels = list
                        }
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var snapshotPanel: some View {
        VStack(spacing: 6) {
            ZStack {
                // Material backdrop so transparent canvas regions show
                // the Liquid Glass treatment instead of a flat gray box.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                if let img = snapshotImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .opacity(rolling ? 0.35 : 1.0)
                } else {
                    Text("(empty canvas)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Spinner + live timer overlay while generating. Gemini's
                // generateContent isn't streaming, so there's no server-side
                // progress event — best we can do is elapsed-seconds + a
                // hint that recalibrates the user's expectation as time
                // passes.
                if rolling {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text(elapsedDisplay)
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text(progressHint)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.black.opacity(0.55))
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.separator.opacity(0.5), lineWidth: 0.5)
            )
            Text("\(Int(store.canvasSize.width)) × \(Int(store.canvasSize.height))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onReceive(timer) { now in
            if rolling { elapsedTick = now }
        }
    }

    /// Seconds elapsed since the current Reimagine started, formatted as
    /// "12s" or "1:23" depending on length.
    private var elapsedDisplay: String {
        guard let start = rollStarted else { return "0s" }
        let secs = Int(elapsedTick.timeIntervalSince(start))
        if secs < 60 { return "\(secs)s" }
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    private var progressHint: String {
        guard let start = rollStarted else { return "" }
        let secs = elapsedTick.timeIntervalSince(start)
        let isLocal = activeProvider.id == LocalFluxProvider.idValue || activeProvider.id == LocalQwenProvider.idValue
        if isLocal {
            switch secs {
            case ..<60:   return "Loading model weights…"
            case 60..<180: return "Generating — ~\(fluxSteps * 37)s total for \(fluxSteps) steps"
            case 180..<420: return "Still running — local generation can take 5–8 min"
            default:      return "Taking a while — feel free to cancel and lower Steps"
            }
        }
        switch secs {
        case ..<15:   return "Typical: 10–30s"
        case 15..<45: return "Generating…"
        case 45..<90: return "Taking longer than usual — still trying"
        case 90..<180: return "Slow server response — Gemini can take 90s+ on busy moments"
        case 180..<270: return "Very slow — still waiting"
        default:      return "Feel free to cancel and retry"
        }
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            providerRow
            modelRow
            if activeProvider.id == LocalFluxProvider.idValue {
                fluxOptionsRow
            }
            costLine
            Text("Prompt")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            TextEditor(text: $prompt)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.separator.opacity(0.5), lineWidth: 0.5)
                )
                .frame(minHeight: 80)
            if let lastError {
                errorBanner(lastError)
                    .padding(.top, 4)
            }
        }
    }

    private var providerRow: some View {
        HStack {
            Text("Provider")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Picker("", selection: $selectedProviderID) {
                ForEach(candidates, id: \.id) { p in
                    Text(p.displayName).tag(p.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            if !activeProvider.isConfigured {
                Text("(not configured)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        if activeProvider.id == GeminiProvider.idValue {
            HStack {
                Text("Model")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                if geminiAvailableModels.isEmpty {
                    Text(geminiModelID)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("(refresh in Settings → AI Providers)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $geminiModelID) {
                        ForEach(geminiAvailableModels) { m in
                            // Mark free-tier eligibility so the user
                            // doesn't accidentally pick a paid-only
                            // variant (3-pro-image, 3.1-flash-image,
                            // 2.5-flash-preview-image all return
                            // `limit: 0` on free-tier accounts).
                            Text((m.displayName.isEmpty ? m.id : m.displayName) + (m.isFreeTier ? "  ✓ free" : "  $ paid")).tag(m.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var fluxOptionsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Strength")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Slider(value: $fluxStrength, in: 0.1...1.0, step: 0.05)
                    .onChange(of: fluxStrength) { _, v in LocalFluxProvider.setStrength(Float(v)) }
                Text(String(format: "%.2f", fluxStrength))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Text("Steps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: $fluxSteps) {
                    Text("4  (fast)").tag(4)
                    Text("8  (balanced)").tag(8)
                    Text("12 (quality)").tag(12)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: fluxSteps) { _, v in LocalFluxProvider.setSteps(v) }
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.separator.opacity(0.5), lineWidth: 0.5))
    }

    private var costLine: some View {
        HStack(spacing: 6) {
            let label = costLabel
            Text(label.symbol)
            Text(label.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(label.color)
        }
        .padding(.top, 2)
    }

    /// Error display: high-contrast text on a red capsule, capped at 4
    /// lines with tail truncation so a giant Gemini quota dump doesn't
    /// blow out the sheet height. Full text is one click away via Copy.
    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
                copyFeedback = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run { copyFeedback = false }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc")
                    Text(copyFeedback ? "Copied" : "Copy")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Copy error to clipboard")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.88))
        )
    }

    // MARK: - Terminal panel

    private var terminalPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if logLines.isEmpty {
                        Text("Console output will appear here during generation…")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(white: 0.45))
                            .id("placeholder")
                    } else {
                        ForEach(logLines.indices, id: \.self) { i in
                            Text(logLines[i])
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color(red: 0.35, green: 1.0, blue: 0.35))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: logLines.count) { _, _ in
                if let last = logLines.indices.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minHeight: 160, maxHeight: 260)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(white: 0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Cost line

    private struct CostLabel { let symbol: String; let text: String; let color: Color }

    private var costLabel: CostLabel {
        let model = activeProvider.id == GeminiProvider.idValue ? geminiModelID : ""
        let cm = activeProvider.costModel(for: .reimagine, model: model)
        switch cm {
        case .alwaysFree:
            return CostLabel(symbol: "💻", text: "Free (runs on your Mac)", color: .secondary)
        case .freeQuotaThenPaid(let perDay, let usd):
            let used = QuotaTracker.shared.count(providerID: activeProvider.id, modelID: model)
            let pct = Double(used) / Double(max(perDay, 1))
            if used >= perDay {
                return CostLabel(symbol: "🔴", text: "Free quota exhausted — next call ~$\(String(format: "%.2f", usd)) if billing is enabled", color: .red)
            } else if pct >= 0.8 {
                return CostLabel(symbol: "🟡", text: "Free (\(used)/\(perDay) — almost out)", color: .orange)
            } else {
                return CostLabel(symbol: "🟢", text: "Free (\(used)/\(perDay) used today)", color: .green)
            }
        case .payPerCall(let usd):
            return CostLabel(symbol: "💵", text: "Paid (~$\(String(format: "%.2f", usd)) per call)", color: .secondary)
        case .unknown:
            return CostLabel(symbol: "❓", text: "Cost: unknown — check your provider dashboard", color: .secondary)
        }
    }

    // MARK: - Run

    private func runReimagine() async {
        rolling = true
        rollStarted = Date()
        elapsedTick = Date()
        lastError = nil
        logLines = []
        defer {
            rolling = false
            rollStarted = nil
        }

        // Persist the user's model selection so next launch defaults to it.
        if activeProvider.id == GeminiProvider.idValue {
            GeminiProvider.setModelID(geminiModelID)
        }
        do {
            try await ReimagineService.run(
                store: store,
                provider: activeProvider,
                prompt: prompt,
                sequenceIndex: sequenceIndex,
                progress: { line in
                    Task { @MainActor in logLines.append(line) }
                }
            )
            sequenceIndex += 1
            // Refresh snapshot so the next re-roll sees the updated canvas.
            snapshotImage = composeSnapshotNSImage()
        } catch ReimagineService.ReimagineError.providerFailed(let pe) {
            lastError = userMessage(for: pe)
        } catch is CancellationError {
            // User hit Cancel — suppress error banner.
        } catch {
            lastError = "Reimagine failed: \(error.localizedDescription)"
        }
    }

    private func userMessage(for error: ProviderError) -> String {
        switch error {
        case .notConfigured:
            return "Provider not configured. Add an API key in Settings → AI Providers."
        case .invalidKey:
            return "Invalid API key. Check Settings → AI Providers."
        case .quotaExceeded(let detail):
            // Parse the exact model ID out of Google's error so we can
            // give precise guidance instead of generic "pick a 2.5 model"
            // (which can match the paid-only `gemini-2.5-flash-preview-image`).
            let modelInError = extractGeminiModelID(from: detail)
            let isLimit0 = detail.contains("limit: 0")

            if isLimit0 {
                // Two distinct cases:
                //   A) The free model (`gemini-2.5-flash-image`) itself
                //      returned limit:0 → account doesn't have free tier
                //      provisioned at all. User must enable billing or
                //      use a different key.
                //   B) A paid-only model returned limit:0 → user picked
                //      a non-free variant; switch to gemini-2.5-flash-image.
                if modelInError == "gemini-2.5-flash-image" {
                    return """
                    Your Google account doesn't have free-tier image generation provisioned.

                    The exact free-tier model `gemini-2.5-flash-image` returned limit:0 — that means \
                    your project doesn't have free-tier access to Gemini image generation at all. \
                    Possible reasons:

                    • Regional restriction (some regions don't get free image gen)
                    • "Generative Language API" not enabled on the project
                    • Project created without free-tier opt-in

                    Fix: visit https://aistudio.google.com/ → Get API key → ensure billing is \
                    enabled, OR try a different API key from a project that has free tier enabled.
                    """
                } else {
                    let actualModel = modelInError ?? "the selected model"
                    return """
                    `\(actualModel)` is paid-only on your account.

                    The only Gemini image model with a free tier is exactly `gemini-2.5-flash-image` \
                    (Nano Banana, 500/day). Variants with `-preview`, `-pro`, or `3.x` are paid-only.

                    Fix: Settings → AI Providers (⌘,) → Model dropdown → pick the row labeled `✓ free`.
                    """
                }
            }
            // Standard rate-limit / quota: pass Google's text through so
            // the user can see if it's per-minute (10 RPM free) or per-day.
            return "Quota / rate limit: \(detail)"
        case .invalidInput(let detail):
            return "Image rejected: \(detail)"
        case .contentPolicy:
            return "The provider blocked this prompt for content policy reasons."
        case .network(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .decodeFailure(let what):
            return "Couldn't read response: \(what)"
        case .unknown(let what):
            return what
        }
    }

    /// Pull `<model-id>` out of Google's quota error string. The 429
    /// body looks like:
    ///   `... limit: 0, model: gemini-2.5-flash-preview-image ...`
    /// We want the exact ID so the user knows whether they picked a paid
    /// variant or hit limit:0 on the genuinely-free model.
    private func extractGeminiModelID(from text: String) -> String? {
        // Greedy match the line that starts with "model: " and grab the
        // identifier before the next whitespace, comma, or newline.
        guard let range = text.range(of: #"model:\s*([a-zA-Z0-9._-]+)"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(text[range])
        // Strip the literal prefix.
        return matched
            .replacingOccurrences(of: "model:", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Snapshot

    private func composeSnapshotNSImage() -> NSImage? {
        guard let cg = LayerRenderer.composite(store: store) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
