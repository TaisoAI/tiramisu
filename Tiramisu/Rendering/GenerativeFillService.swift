import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

protocol GenerativeFillService: Sendable {
    func fill(image: CGImage,
              mask: CGImage,
              prompt: String,
              progress: @Sendable @escaping (String) -> Void) async throws -> CGImage

    /// If non-nil, the coordinator should tile its input to this size in
    /// Expand mode (one tile per band edge) instead of single-passing the
    /// whole canvas. Used for backends that internally rescale to a fixed
    /// resolution (e.g. Local SD-1.5 → 512×512), which destroys aspect
    /// ratio and means the bands never get seen at native resolution.
    var preferredInputSize: CGSize? { get }

    /// If true, the coordinator pre-fills empty expand bands with
    /// stretched edge content before sending to the service. Set this for
    /// backends that expect the image to have plausible content everywhere
    /// (e.g. OpenAI images/edits) rather than mask-guided blank regions.
    var needsPrepFill: Bool { get }
}

extension GenerativeFillService {
    var preferredInputSize: CGSize? { nil }
    var needsPrepFill: Bool { false }
}

/// What the user is asking the fill engine to do. Drives mask shape,
/// edge-padding, and per-backend strength.
enum GenerativeFillMode: Int, Sendable {
    case generate = 0   // fill marquee with prompted content
    case replace = 1    // substitute marquee content
    case remove = 2     // erase marquee, fill with surroundings
    case expand = 3     // outpaint: extend image to canvas edges
}

enum GenerativeFillError: LocalizedError {
    case missingAPIKey
    case encodeFailed
    case createPredictionFailed(String)
    case predictionFailed(String)
    case timeout
    case downloadFailed
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Replicate API key not set. Settings → Generative Fill."
        case .encodeFailed: return "Could not encode image / mask to PNG."
        case .createPredictionFailed(let s): return "Replicate API rejected the request: \(s)"
        case .predictionFailed(let s): return s
        case .timeout: return "Replicate prediction timed out."
        case .downloadFailed: return "Could not download generated image."
        case .decodeFailed: return "Could not decode the generated image."
        }
    }
}

/// Replicate adapter using `black-forest-labs/flux-fill-dev` for high-quality
/// inpainting. Async polling implementation; no SDK required.
struct ReplicateFillService: GenerativeFillService {
    let apiKey: String
    let modelVersion: String   // e.g. "black-forest-labs/flux-fill-dev" (latest)

    init(apiKey: String,
         modelVersion: String = "black-forest-labs/flux-fill-dev") {
        self.apiKey = apiKey
        self.modelVersion = modelVersion
    }

    func fill(image: CGImage,
              mask: CGImage,
              prompt: String,
              progress: @Sendable @escaping (String) -> Void) async throws -> CGImage {
        guard !apiKey.isEmpty else { throw GenerativeFillError.missingAPIKey }
        progress("Encoding…")

        guard let imgB64 = pngBase64(image), let maskB64 = pngBase64(mask) else {
            throw GenerativeFillError.encodeFailed
        }
        let imageURI = "data:image/png;base64,\(imgB64)"
        let maskURI = "data:image/png;base64,\(maskB64)"

        progress("Submitting…")
        let predictionURL = URL(string: "https://api.replicate.com/v1/models/\(modelVersion)/predictions")!
        var req = URLRequest(url: predictionURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("wait=15", forHTTPHeaderField: "Prefer")  // synchronous up to 15s
        let body: [String: Any] = [
            "input": [
                "prompt": prompt,
                "image": imageURI,
                "mask": maskURI,
                "output_format": "png",
                "output_quality": 100,
                "safety_tolerance": 5,
                "num_inference_steps": 30
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode < 500 else {
            throw GenerativeFillError.createPredictionFailed("HTTP \(((response as? HTTPURLResponse)?.statusCode).map(String.init) ?? "?")")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GenerativeFillError.createPredictionFailed("Bad JSON")
        }
        if let err = json["detail"] as? String {
            throw GenerativeFillError.createPredictionFailed(err)
        }

        // If the response includes terminal output, use it directly.
        if let status = json["status"] as? String, status == "succeeded" {
            return try await downloadOutput(json: json)
        }

        // Otherwise poll.
        guard let id = json["id"] as? String else {
            throw GenerativeFillError.createPredictionFailed("No prediction id")
        }
        return try await pollAndDownload(predictionID: id, progress: progress)
    }

    // MARK: - Helpers

    private func pollAndDownload(predictionID: String,
                                  progress: @Sendable @escaping (String) -> Void) async throws -> CGImage {
        let url = URL(string: "https://api.replicate.com/v1/predictions/\(predictionID)")!
        let deadline = Date().addingTimeInterval(120)  // 2 min ceiling
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            var req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else { continue }
            progress(status)
            switch status {
            case "succeeded": return try await downloadOutput(json: json)
            case "failed":
                let msg = (json["error"] as? String) ?? "Unknown error"
                throw GenerativeFillError.predictionFailed(msg)
            case "canceled":
                throw GenerativeFillError.predictionFailed("Cancelled")
            default: continue
            }
        }
        throw GenerativeFillError.timeout
    }

    private func downloadOutput(json: [String: Any]) async throws -> CGImage {
        // Replicate's `output` is sometimes a single URL string, sometimes an array.
        var urlString: String?
        if let s = json["output"] as? String { urlString = s }
        else if let arr = json["output"] as? [String], let first = arr.first { urlString = first }
        guard let urlString, let url = URL(string: urlString) else {
            throw GenerativeFillError.downloadFailed
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw GenerativeFillError.decodeFailed
        }
        return img
    }

    private func pngBase64(_ image: CGImage) -> String? {
        let mut = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mut, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (mut as Data).base64EncodedString()
    }
}

/// Where the API key is stored. UserDefaults for MVP — Keychain upgrade later.
enum GenerativeFillSettings {
    private static let apiKeyKey = "ai.taiso.tiramisu.replicate.apiKey"
    private static let modelKey = "ai.taiso.tiramisu.replicate.model"
    private static let backendKey = "ai.taiso.tiramisu.fill.backend"

    enum Backend: String { case replicate, localFlux, openaicompat }

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyKey) }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "black-forest-labs/flux-fill-dev" }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    static var backend: Backend {
        get { Backend(rawValue: UserDefaults.standard.string(forKey: backendKey) ?? "") ?? .replicate }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: backendKey) }
    }
}
