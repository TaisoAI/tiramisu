import Foundation
import CoreGraphics

struct OpenAICompatibleProvider: AIImageProvider {
    static let idValue = "openaicompat"

    private static let baseURLKey   = "ai.taiso.tiramisu.openaicompat.baseurl"
    private static let apiKeyKey    = "ai.taiso.tiramisu.openaicompat.apikey"
    private static let modelKey     = "ai.taiso.tiramisu.openaicompat.model"
    private static let authStyleKey = "ai.taiso.tiramisu.openaicompat.authstyle"

    enum AuthStyle: String, CaseIterable, Identifiable {
        case azureAPIKey = "azure"   // api-key header, deployment in URL path
        case bearerToken = "bearer"  // Authorization: Bearer, model in body

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .azureAPIKey: return "Azure (api-key)"
            case .bearerToken: return "OpenAI (Bearer)"
            }
        }
    }

    var id: String { Self.idValue }
    var displayName: String { "OpenAI-compatible" }
    var capabilities: Set<AIImageCapability> { [.reimagine] }
    var requiresAPIKey: Bool { true }
    var helpURL: URL { URL(string: "https://platform.openai.com/docs/api-reference/images")! }

    var baseURL: String {
        UserDefaults.standard.string(forKey: Self.baseURLKey) ?? ""
    }
    var apiKey: String {
        UserDefaults.standard.string(forKey: Self.apiKeyKey) ?? ""
    }
    var model: String {
        let stored = UserDefaults.standard.string(forKey: Self.modelKey) ?? ""
        return stored.isEmpty ? "gpt-image-1" : stored
    }

    /// Explicit auth style. If never set, auto-detects from the base URL.
    var authStyle: AuthStyle {
        if let raw = UserDefaults.standard.string(forKey: Self.authStyleKey),
           let style = AuthStyle(rawValue: raw) { return style }
        return Self.detectAuthStyle(for: baseURL)
    }

    static func detectAuthStyle(for url: String) -> AuthStyle {
        let isAzure = url.contains(".cognitiveservices.azure.com") ||
                      url.contains(".openai.azure.com")
        return isAzure ? .azureAPIKey : .bearerToken
    }

    var isConfigured: Bool { !baseURL.isEmpty && !apiKey.isEmpty }

    func costModel(for capability: AIImageCapability, model: String) -> ProviderCostModel {
        .payPerCall(estimateUSD: 0.04)
    }

    func reimagine(image: CGImage,
                   prompt: String,
                   progress: @Sendable @escaping (String) -> Void = { _ in }) async throws -> CGImage {
        guard isConfigured else { throw ProviderError.notConfigured }
        let svc = OpenAICompatibleImageService(
            baseURL: baseURL, apiKey: apiKey, model: model, authStyle: authStyle)
        return try await svc.reimagine(image: image, prompt: prompt, progress: progress)
    }

    static func setBaseURL(_ v: String)       { UserDefaults.standard.set(v, forKey: baseURLKey) }
    static func setAPIKey(_ v: String)        { UserDefaults.standard.set(v, forKey: apiKeyKey) }
    static func setModel(_ v: String)         { UserDefaults.standard.set(v, forKey: modelKey) }
    static func setAuthStyle(_ s: AuthStyle)  { UserDefaults.standard.set(s.rawValue, forKey: authStyleKey) }
}
