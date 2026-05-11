import Foundation
import CoreGraphics

/// `AIImageProvider` conformance for the user-installed mflux binaries.
/// Wraps both `LocalFluxFillService` (inpaint/outpaint) and the new
/// `LocalFluxKontextService` (Reimagine via FLUX Kontext).
struct LocalFluxProvider: AIImageProvider {
    static let idValue = "localflux"

    private static let quantizeDefault   = "ai.taiso.tiramisu.localflux.quantize"
    private static let stepsDefault      = "ai.taiso.tiramisu.localflux.steps"
    private static let strengthDefault   = "ai.taiso.tiramisu.localflux.strength"

    var id: String { Self.idValue }
    var displayName: String { "Local FLUX (on-device)" }
    var capabilities: Set<AIImageCapability> { [.reimagine, .inpaint, .outpaint] }
    var requiresAPIKey: Bool { false }
    var helpURL: URL { URL(string: "https://github.com/filipstrand/mflux")! }

    var isConfigured: Bool {
        // Fill (inpaint/outpaint) needs mflux-generate-fill.
        // Reimagine needs mflux-generate-kontext.
        // Show as configured when at least one is present.
        LocalFluxFillService.isInstalled || LocalFluxKontextService.isInstalled
    }

    var isKontextInstalled: Bool { LocalFluxKontextService.isInstalled }

    var selectedQuantize: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.quantizeDefault)
        return stored > 0 ? stored : 4
    }
    var selectedSteps: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.stepsDefault)
        return stored > 0 ? stored : 8
    }
    var selectedStrength: Float {
        let stored = UserDefaults.standard.float(forKey: Self.strengthDefault)
        return stored > 0 ? stored : 0.75
    }

    func costModel(for capability: AIImageCapability,
                   model: String) -> ProviderCostModel {
        switch capability {
        case .reimagine, .inpaint, .outpaint:
            return .alwaysFree
        default:
            return .unknown
        }
    }

    func reimagine(image: CGImage,
                   prompt: String,
                   progress: @Sendable @escaping (String) -> Void = { _ in }) async throws -> CGImage {
        guard LocalFluxKontextService.isInstalled else { throw ProviderError.notConfigured }
        let svc = LocalFluxKontextService(
            quantize: selectedQuantize,
            steps: selectedSteps,
            imageStrength: selectedStrength
        )
        return try await svc.reimagine(image: image, prompt: prompt, progress: progress)
    }

    // MARK: - Settings writers

    static func setQuantize(_ q: Int) {
        UserDefaults.standard.set(q, forKey: quantizeDefault)
    }
    static func setSteps(_ s: Int) {
        UserDefaults.standard.set(s, forKey: stepsDefault)
    }
    static func setStrength(_ s: Float) {
        UserDefaults.standard.set(s, forKey: strengthDefault)
    }
}
