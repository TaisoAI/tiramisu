import Foundation

/// `AIImageProvider` conformance for Replicate. Wraps the existing
/// `ReplicateFillService` + `GenerativeFillSettings` machinery — no
/// behavior change. Reads the same UserDefaults key
/// (`ai.taiso.tiramisu.replicate.apiKey`) so existing users keep
/// their key on upgrade. Zero migration.
struct ReplicateProvider: AIImageProvider {
    static let idValue = "replicate"

    var id: String { Self.idValue }
    var displayName: String { "Replicate" }
    // `.reimagine` is intentionally OUT for v0.6 — our default Replicate
    // model is `black-forest-labs/flux-fill-dev` (the inpainting one).
    // True Reimagine wants `flux-dev` / `flux-1.1-pro` with img2img +
    // strength. That ships in v0.6.1 alongside the LocalFlux img2img path.
    var capabilities: Set<AIImageCapability> { [.inpaint, .outpaint] }
    var requiresAPIKey: Bool { true }
    var helpURL: URL { URL(string: "https://replicate.com/account/api-tokens")! }

    var isConfigured: Bool { !GenerativeFillSettings.apiKey.isEmpty }

    var apiKey: String { GenerativeFillSettings.apiKey }
    var modelVersion: String { GenerativeFillSettings.model }

    func costModel(for capability: AIImageCapability,
                   model: String) -> ProviderCostModel {
        // Replicate: pay per call, no free tier. ~$0.03/img is the FLUX-Fill
        // average; other models drift higher/lower. We surface the average
        // as a useful order-of-magnitude estimate; provider dashboard is
        // the source of truth.
        switch capability {
        case .reimagine, .inpaint, .outpaint:
            return .payPerCall(estimateUSD: 0.03)
        default:
            return .unknown
        }
    }

    // No `validateConfiguration` — Replicate's account endpoint requires
    // a separate scope on the token; safer to just trust the key and let
    // the first real call fail loudly if it's invalid.
}
