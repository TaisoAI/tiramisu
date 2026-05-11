import Foundation
import CoreGraphics

/// `AIImageProvider` conformance for local Qwen-Image-Edit via the
/// user-installed `qwen-image-mps` CLI. Purpose-built for Reimagine —
/// Qwen-Image-Edit is trained on image-edit pairs, which matches our
/// "image + prompt → new image" semantic exactly. Apache-2.0 weights,
/// no gated-repo auth gymnastics.
struct LocalQwenProvider: AIImageProvider {
    static let idValue = "localqwen"

    private static let modeDefault = "world.hanley.tiramisu.localqwen.mode"
    private static let quantDefault = "world.hanley.tiramisu.localqwen.quant"

    var id: String { Self.idValue }
    var displayName: String { "Local Qwen-Image-Edit (on-device)" }
    var capabilities: Set<AIImageCapability> { [.reimagine] }
    var requiresAPIKey: Bool { false }
    var helpURL: URL { URL(string: "https://github.com/ivanfioravanti/qwen-image-mps")! }

    /// True when the user has installed qwen-image-mps at the expected
    /// path. We rely on file-existence rather than running --version so
    /// the Settings UI status dot is cheap.
    var isConfigured: Bool {
        FileManager.default.fileExists(atPath: LocalQwenImageService.defaultBinaryURL.path)
    }

    var selectedMode: LocalQwenImageService.Mode {
        let raw = UserDefaults.standard.string(forKey: Self.modeDefault) ?? LocalQwenImageService.Mode.fast.rawValue
        return LocalQwenImageService.Mode(rawValue: raw) ?? .fast
    }

    var selectedQuantization: LocalQwenImageService.Quantization {
        let raw = UserDefaults.standard.string(forKey: Self.quantDefault) ?? LocalQwenImageService.Quantization.q4KM.rawValue
        return LocalQwenImageService.Quantization(rawValue: raw) ?? .q4KM
    }

    func costModel(for capability: AIImageCapability,
                   model: String) -> ProviderCostModel {
        // Always free — runs on the user's hardware.
        capability == .reimagine ? .alwaysFree : .unknown
    }

    /// Reimagine via Qwen-Image-Edit. Wraps the service with the user's
    /// persisted mode + quantization choices. `progress` streams every
    /// stdout/stderr line from qwen-image-mps — model download progress,
    /// step counts, etc.
    func reimagine(image: CGImage,
                   prompt: String,
                   progress: @Sendable @escaping (String) -> Void = { _ in }) async throws -> CGImage {
        guard isConfigured else { throw ProviderError.notConfigured }
        let service = LocalQwenImageService(
            binaryURL: LocalQwenImageService.defaultBinaryURL,
            quantization: selectedQuantization,
            mode: selectedMode
        )
        return try await service.reimagine(image: image, prompt: prompt, progress: progress)
    }

    // MARK: - Settings writers

    static func setMode(_ mode: LocalQwenImageService.Mode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeDefault)
    }

    static func setQuantization(_ quant: LocalQwenImageService.Quantization) {
        UserDefaults.standard.set(quant.rawValue, forKey: quantDefault)
    }
}
