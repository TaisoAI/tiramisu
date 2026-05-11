import SwiftUI
import AppKit

/// Settings pane: AI Providers. Lists every known provider with status,
/// API key field, model selector, and a Test button. New providers added
/// to `AIProviders.all` show up here automatically.
struct AIProvidersSettings: View {
    // Editable state lives here so SecureField/TextField keep focus while
    // typing. We mirror to UserDefaults on every change rather than
    // re-rendering the whole tree per keystroke (an earlier version used
    // a refresh-tick + .id() and the SecureField lost focus after each
    // character — classic SwiftUI footgun).
    @State private var geminiKey: String = ""
    @State private var geminiModelID: String = GeminiProvider.defaultModelID
    @State private var geminiAvailableModels: [GeminiImageService.DiscoveredModel] = []
    @State private var geminiModelsLoading: Bool = false
    @State private var replicateKey: String = ""

    @State private var geminiTestResult: String?
    @State private var geminiTestOK: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add cloud or local AI providers. Tiramisu uses your keys for your generations — they don't pass through our servers. Local providers run entirely on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                geminiSection
                localQwenSection
                replicateSection
                localFluxSection

                Spacer(minLength: 12)
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            // Initialize state from UserDefaults once on appear.
            geminiKey = GeminiProvider().apiKey
            geminiModelID = GeminiProvider().selectedModelID
            replicateKey = GenerativeFillSettings.apiKey
            qwenMode = LocalQwenProvider().selectedMode
            qwenQuant = LocalQwenProvider().selectedQuantization
            // If a key is already configured, refresh the live model list
            // so the picker isn't blank on first open.
            if !geminiKey.isEmpty {
                Task { await refreshGeminiModels() }
            }
        }
    }

    /// Hit Gemini's ListModels endpoint with the current API key. Caches
    /// the result in @State so the picker can render even when the user
    /// closes/reopens the Settings window without an internet call.
    private func refreshGeminiModels() async {
        guard !geminiKey.isEmpty else { return }
        geminiModelsLoading = true
        defer { geminiModelsLoading = false }
        do {
            let list = try await GeminiProvider().availableModels()
            await MainActor.run {
                geminiAvailableModels = list
                // If the currently-selected model isn't in the list, fall
                // back to the first one returned (typically Flash Image).
                if !list.contains(where: { $0.id == geminiModelID }), let first = list.first {
                    geminiModelID = first.id
                    GeminiProvider.setModelID(first.id)
                }
            }
        } catch {
            // Silent failure; user can see the test result for diagnostic info.
        }
    }

    // MARK: - Gemini

    private var geminiSection: some View {
        providerCard(
            displayName: "Google Gemini",
            configured: !geminiKey.isEmpty,
            helpURL: GeminiProvider().helpURL,
            capabilities: "reimagine"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SecureField("Gemini API key", text: $geminiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: geminiKey) { _, new in
                            GeminiProvider.setAPIKey(new)
                            // Invalidate test result when the key changes.
                            geminiTestResult = nil
                            // Refresh the model list using the new key.
                            Task { await refreshGeminiModels() }
                        }
                    Button("Test") { Task { await testGemini() } }
                        .disabled(geminiKey.isEmpty)
                }
                HStack {
                    Text("Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if geminiAvailableModels.isEmpty {
                        // No fetched list yet — show the persisted ID as
                        // plain text + a "Refresh" button so the user
                        // knows what's coming.
                        Text(geminiModelID)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: $geminiModelID) {
                            ForEach(geminiAvailableModels) { m in
                                Text((m.displayName.isEmpty ? m.id : m.displayName) + (m.isFreeTier ? "  ✓ free" : "  $ paid")).tag(m.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: geminiModelID) { _, new in
                            GeminiProvider.setModelID(new)
                        }
                    }
                    Button {
                        Task { await refreshGeminiModels() }
                    } label: {
                        Image(systemName: geminiModelsLoading ? "hourglass" : "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Fetch available image-generation models from your API key")
                    .disabled(geminiKey.isEmpty || geminiModelsLoading)
                }
                Text(geminiAvailableModels.isEmpty
                    ? (geminiKey.isEmpty ? "Add a key to populate the model list" : "Press refresh to fetch available models")
                    : "\(geminiAvailableModels.count) image-capable model(s) discovered")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let geminiTestResult {
                    Text(geminiTestResult)
                        .font(.caption)
                        .foregroundStyle(geminiTestOK ? .green : .red)
                }
            }
        }
    }

    private func testGemini() async {
        let result = await GeminiProvider().validateConfiguration()
        await MainActor.run {
            switch result {
            case .success:
                geminiTestResult = "✓ Key valid"
                geminiTestOK = true
            case .failure(let err):
                switch err {
                case .invalidKey:        geminiTestResult = "✗ Invalid key"
                case .notConfigured:     geminiTestResult = "✗ No key"
                case .network(let e):    geminiTestResult = "✗ Network: \(e.localizedDescription)"
                default:                 geminiTestResult = "✗ \(err)"
                }
                geminiTestOK = false
            }
        }
    }

    // MARK: - Replicate

    private var replicateSection: some View {
        providerCard(
            displayName: "Replicate",
            configured: !replicateKey.isEmpty,
            helpURL: ReplicateProvider().helpURL,
            capabilities: "reimagine · inpaint · outpaint"
        ) {
            HStack {
                SecureField("Replicate API token", text: $replicateKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: replicateKey) { _, new in
                        GenerativeFillSettings.apiKey = new
                    }
                Text("~$0.03/call")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Local Qwen

    @State private var qwenMode: LocalQwenImageService.Mode = .fast
    @State private var qwenQuant: LocalQwenImageService.Quantization = .q4KM

    private var localQwenSection: some View {
        let provider = LocalQwenProvider()
        return providerCard(
            displayName: "Local Qwen-Image-Edit (on-device)",
            configured: provider.isConfigured,
            helpURL: provider.helpURL,
            capabilities: "reimagine · Apache-2.0 · free"
        ) {
            if provider.isConfigured {
                VStack(alignment: .leading, spacing: 8) {
                    Text("✓ Installed at ~/.local/bin/qwen-image-mps")
                        .font(.caption)
                        .foregroundStyle(.green)
                    HStack {
                        Text("Speed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Picker("", selection: $qwenMode) {
                            ForEach(LocalQwenImageService.Mode.allCases) { m in
                                Text(m.displayName).tag(m)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: qwenMode) { _, new in LocalQwenProvider.setMode(new) }
                    }
                    HStack(alignment: .top) {
                        Text("Memory")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                            .padding(.top, 1)
                        Text("Standard model (~15 GB, loads once). GGUF quantization for editing is not yet supported by qwen-image-mps.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Not installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("One-time install: `uv tool install qwen-image-mps` (requires uv). First Reimagine call downloads ~20 GB to your HF cache.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - LocalFlux

    @State private var fluxStrength: Double = Double(LocalFluxProvider().selectedStrength)
    @State private var fluxSteps: Int = LocalFluxProvider().selectedSteps
    @State private var fluxQuantize: Int = LocalFluxProvider().selectedQuantize

    private var localFluxSection: some View {
        let provider = LocalFluxProvider()
        return providerCard(
            displayName: "Local FLUX (on-device)",
            configured: provider.isConfigured,
            helpURL: provider.helpURL,
            capabilities: "reimagine · inpaint · outpaint"
        ) {
            if provider.isConfigured {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        if LocalFluxKontextService.isInstalled {
                            Text("✓ mflux-generate-kontext (Reimagine)")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if LocalFluxFillService.isInstalled {
                            Text("✓ mflux-generate-fill (Inpaint · Outpaint)")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }

                    Divider()

                    // Kontext settings (only relevant when kontext is installed)
                    if LocalFluxKontextService.isInstalled {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Strength")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .leading)
                                Slider(value: $fluxStrength, in: 0.1...1.0, step: 0.05)
                                    .frame(width: 160)
                                    .onChange(of: fluxStrength) { _, v in
                                        LocalFluxProvider.setStrength(Float(v))
                                    }
                                Text(String(format: "%.2f", fluxStrength))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, alignment: .trailing)
                            }
                            Text("How much the image changes. 0.3–0.5 = subtle edits; 0.7+ = strong transformation.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            HStack {
                                Text("Steps")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .leading)
                                Picker("", selection: $fluxSteps) {
                                    Text("4  (~2 min)").tag(4)
                                    Text("8  (~5 min)").tag(8)
                                    Text("12 (~7 min)").tag(12)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 110)
                                .onChange(of: fluxSteps) { _, v in
                                    LocalFluxProvider.setSteps(v)
                                }
                            }

                            HStack {
                                Text("Quality")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .leading)
                                Picker("", selection: $fluxQuantize) {
                                    Text("4-bit (~4 GB)").tag(4)
                                    Text("8-bit (~8 GB)").tag(8)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 110)
                                .onChange(of: fluxQuantize) { _, v in
                                    LocalFluxProvider.setQuantize(v)
                                }
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Not installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Install mflux via Homebrew + uv (one-time, ~24 GB download). See AI → Generative Fill Settings for the bootstrap script.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Card chrome

    @ViewBuilder
    private func providerCard<Content: View>(
        displayName: String,
        configured: Bool,
        helpURL: URL,
        capabilities: String,
        @ViewBuilder body: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(configured ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .shadow(color: configured ? .green.opacity(0.4) : .clear, radius: 3)
                Text(displayName)
                    .font(.headline)
                Spacer()
                Link("Get key →", destination: helpURL)
                    .font(.caption)
            }
            Text("Capabilities: \(capabilities)")
                .font(.caption)
                .foregroundStyle(.secondary)
            body()
        }
        .padding(14)
        // Liquid Glass material card — matches `PropertiesTab` convention,
        // reads as part of the macOS 26 chrome rather than a flat
        // gray block. Subtle hairline edge keeps the card legible
        // against any window background.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }
}
