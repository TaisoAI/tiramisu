import Foundation

/// What an AI image model can do. Used by features (Reimagine, Generative
/// Fill, Smart Select, etc.) to ask "which providers can serve me?" and
/// for the Settings UI to show per-provider capability badges. Keep
/// additions to this enum coordinated — every provider's `capabilities`
/// is hand-declared, so adding a new case is a small fan-out edit.
enum AIImageCapability: String, Codable, Sendable, CaseIterable {
    case reimagine            // image + prompt → image
    case inpaint              // image + mask + prompt → filled image
    case outpaint             // image + bands mask + prompt → expanded image
    case segment              // image + click → mask
    case upscale              // image → larger image
    case removeBackground     // image → image with bg alpha=0
    case decomposeLayers      // image → [RGBA layers]
}

/// Per-(provider, model, capability) cost characterization. Drives the
/// color-coded cost line in the Reimagine sheet. Estimates only — no
/// provider returns authoritative pre-call billing data, so this is
/// published-rate info paired with `QuotaTracker`'s local counter.
enum ProviderCostModel: Sendable, Equatable {
    /// Always free, runs on the user's hardware. e.g. LocalFlux.
    case alwaysFree

    /// Free quota of N calls per local-day, then the per-call rate
    /// kicks in IF the user has billing enabled on their account.
    /// e.g. Gemini Nano Banana 500/day free, then ~$0.04.
    case freeQuotaThenPaid(perDay: Int, paidEstimateUSD: Double)

    /// Pure pay-per-call. e.g. Replicate, OpenAI.
    case payPerCall(estimateUSD: Double)

    /// We don't know — Settings + Reimagine sheet show "Cost: unknown"
    /// rather than lie.
    case unknown
}

/// Typed errors a provider can raise. Mapped to user-facing strings by
/// the calling feature; we don't bake copy into the protocol.
enum ProviderError: Error, Sendable {
    case notConfigured                       // no API key, binary not installed
    case invalidKey                          // 401 / 403 from auth check
    case quotaExceeded(detail: String)       // 429 — detail = actual provider message (daily / per-min / token / project)
    case invalidInput(String)                // 400 INVALID_ARGUMENT
    case contentPolicy                       // model refused on safety grounds
    case network(Error)                      // transport failure
    case decodeFailure(String)               // response body wasn't what we expected
    case unknown(String)                     // catch-all with provider's message
}

/// What every AI image provider implements. Tiny on purpose — capability-
/// specific calls (e.g. `reimagine(image:prompt:)`) live on per-provider
/// extensions. We formalize a shared shape only when two providers
/// genuinely overlap on a capability.
protocol AIImageProvider: Sendable {
    /// Stable identifier used for UserDefaults keys + audit log lines.
    /// Lowercase, no spaces. e.g. "gemini" / "replicate" / "localflux".
    var id: String { get }

    /// Display name in Settings + Reimagine sheet. e.g. "Google Gemini".
    var displayName: String { get }

    /// What this provider can do. Used by features to discover candidates.
    var capabilities: Set<AIImageCapability> { get }

    /// True if the provider needs an API key. False for local-only ones.
    var requiresAPIKey: Bool { get }

    /// Where the user goes to get an API key (or install instructions).
    var helpURL: URL { get }

    /// True if the provider is configured + ready right now (key present,
    /// binary installed, etc.). Cheap; the Settings panel renders this on
    /// every observation tick.
    var isConfigured: Bool { get }

    /// Per-(capability, model) cost characterization. Drives the cost
    /// line in the Reimagine sheet. `model` is the provider-specific
    /// model identifier (e.g. "gemini-2.5-flash-image").
    func costModel(for capability: AIImageCapability,
                   model: String) -> ProviderCostModel

    /// Optional sanity check — hit a free endpoint to verify the key
    /// isn't malformed. Called when the user clicks "Test" in Settings.
    /// Default impl returns `.success(())` for providers that don't have
    /// a cheap way to validate.
    func validateConfiguration() async -> Result<Void, ProviderError>
}

extension AIImageProvider {
    func validateConfiguration() async -> Result<Void, ProviderError> {
        .success(())
    }
}

/// All providers known to the app. v0.6 wires three: Gemini (new),
/// Replicate (existing), LocalFlux (existing). New providers in v0.7+
/// are added here and instantly discoverable by every feature that asks
/// "which providers serve `.reimagine` / `.inpaint` / `.upscale`?"
enum AIProviders {
    /// Built lazily so the app can run without ever touching a provider
    /// (e.g. headless ControlServer tests). Each provider instance is
    /// stateless beyond what it reads from UserDefaults.
    static var all: [any AIImageProvider] {
        [
            GeminiProvider(),
            LocalQwenProvider(),
            ReplicateProvider(),
            LocalFluxProvider(),
        ]
    }

    /// Providers that can serve a given capability, in display order.
    /// Cheap — used by feature UIs to populate provider dropdowns.
    static func candidates(for capability: AIImageCapability) -> [any AIImageProvider] {
        all.filter { $0.capabilities.contains(capability) }
    }

    /// Default provider for a capability. Today: cheapest configured
    /// first (free local > free quota > pay per call). Per-feature
    /// override via Settings → Routing lands in v0.6.1.
    static func defaultProvider(for capability: AIImageCapability,
                                model: String? = nil) -> (any AIImageProvider)? {
        let configured = candidates(for: capability).filter { $0.isConfigured }
        return configured.min { a, b in
            costRank(a, capability: capability, model: model)
                < costRank(b, capability: capability, model: model)
        }
    }

    /// Lower number = cheaper. Used to rank providers when picking the
    /// default for a capability.
    private static func costRank(_ p: any AIImageProvider,
                                 capability: AIImageCapability,
                                 model: String?) -> Int {
        let cm = p.costModel(for: capability, model: model ?? "")
        switch cm {
        case .alwaysFree:                return 0
        case .freeQuotaThenPaid:         return 1
        case .payPerCall:                return 2
        case .unknown:                   return 3
        }
    }
}
