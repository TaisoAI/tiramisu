import Foundation
import CoreGraphics

/// `AIImageProvider` conformance for Google Gemini. Stores its API key
/// in UserDefaults under `world.hanley.tiramisu.gemini.apiKey` and the
/// selected model under `.gemini.model` (defaults to Nano Banana).
struct GeminiProvider: AIImageProvider {
    static let idValue = "gemini"
    private static let apiKeyDefault = "world.hanley.tiramisu.gemini.apiKey"
    private static let modelDefault  = "world.hanley.tiramisu.gemini.model"

    var id: String { Self.idValue }
    var displayName: String { "Google Gemini" }
    var capabilities: Set<AIImageCapability> { [.reimagine] }
    var requiresAPIKey: Bool { true }
    var helpURL: URL { URL(string: "https://aistudio.google.com/apikey")! }

    var isConfigured: Bool { !apiKey.isEmpty }

    /// Stored key in UserDefaults. Empty string when unset (UserDefaults
    /// default for missing String values is nil; we coerce to "" here so
    /// every callsite can do a single `.isEmpty` check).
    var apiKey: String {
        UserDefaults.standard.string(forKey: Self.apiKeyDefault) ?? ""
    }

    /// Default fallback when no model has been selected yet AND the
    /// API hasn't been queried for available models.
    static let defaultModelID = "gemini-2.5-flash-image"

    /// Selected model ID — a string fetched from Gemini's ListModels
    /// rather than a hard-coded enum. Falls back to the canonical
    /// Nano Banana ID when nothing is stored.
    var selectedModelID: String {
        UserDefaults.standard.string(forKey: Self.modelDefault) ?? Self.defaultModelID
    }

    func costModel(for capability: AIImageCapability,
                   model: String) -> ProviderCostModel {
        guard capability == .reimagine else { return .unknown }
        let modelID = model.isEmpty ? selectedModelID : model
        // Per Google's pricing (May 2026): ONLY `gemini-2.5-flash-image`
        // (the bare Nano Banana ID) has a free tier — 500 RPD. Every other
        // image-capable Gemini variant — including the "newer" 3.x flash,
        // 3-pro-image, 2.5-flash-preview-image — returns `limit: 0` for
        // free-tier accounts. Honest cost surfacing: free for Nano Banana,
        // paid-per-call for everything else (estimate from Pro pricing tier).
        if GeminiImageService.DiscoveredModel.knownFreeTierModels.contains(modelID) {
            return .freeQuotaThenPaid(perDay: 500, paidEstimateUSD: 0.04)
        }
        // Newer variants are paid-only — show as pay-per-call so the UI
        // doesn't mislead about a free quota that doesn't exist.
        return .payPerCall(estimateUSD: 0.12)
    }

    func validateConfiguration() async -> Result<Void, ProviderError> {
        guard !apiKey.isEmpty else { return .failure(.notConfigured) }
        return await GeminiImageService(apiKey: apiKey, modelID: selectedModelID).validate()
    }

    // MARK: - Capability call (Reimagine)

    /// Convenience wrapper exposing the Gemini service through the
    /// provider. Lets callers stay at the `any AIImageProvider` level
    /// where useful, but they can also drop down to `GeminiImageService`
    /// directly when they need Gemini-specific features.
    func reimagine(image: CGImage,
                   prompt: String,
                   progress: @Sendable @escaping (String) -> Void = { _ in }) async throws -> CGImage {
        guard !apiKey.isEmpty else { throw ProviderError.notConfigured }
        return try await GeminiImageService(apiKey: apiKey, modelID: selectedModelID)
            .reimagine(image: image, prompt: prompt, progress: progress)
    }

    /// Fetch the live list of image-capable generateContent models from
    /// Gemini using the stored API key. Used by the Settings + Reimagine
    /// UIs to populate the model picker dynamically — no more hard-coded
    /// guesses about which Pro/Flash variant exists this week.
    func availableModels() async throws -> [GeminiImageService.DiscoveredModel] {
        guard !apiKey.isEmpty else { throw ProviderError.notConfigured }
        return try await GeminiImageService(apiKey: apiKey, modelID: selectedModelID)
            .fetchImageModels(apiKey: apiKey)
    }

    // MARK: - Settings writers

    /// Settings UI calls these to persist user changes. Kept as static
    /// methods so the UI doesn't need a struct instance.
    static func setAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: apiKeyDefault)
    }

    static func setModelID(_ id: String) {
        UserDefaults.standard.set(id, forKey: modelDefault)
    }
}
