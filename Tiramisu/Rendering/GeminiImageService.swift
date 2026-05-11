import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// HTTP client for Gemini's image-generation API. Single class. Async/await.
/// Records to `QuotaTracker` and `CloudAudit` on success.
///
/// Endpoint reference:
///   POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
///   Header: x-goog-api-key: <user's key>
///
/// Request body sends the canvas as base64 inline_data + the user's text
/// prompt. Response returns base64 inline_data of the new image.
struct GeminiImageService: Sendable {

    /// Models exposed to users via the Settings model selector. Order
    /// matters — the first case is the default.
    ///
    /// As of 2026-05-11 only `gemini-2.5-flash-image` (Nano Banana) is
    /// verified to exist and accept generateContent with IMAGE response.
    /// The "Pro Image" variant the research mentioned (Nano Banana Pro)
    /// doesn't resolve under v1beta — pulling it from the list until a
    /// real model ID is confirmed (or it ships). Tail
    /// `GET https://generativelanguage.googleapis.com/v1beta/models?key=<key>`
    /// to see what's actually available on your project.
    enum Model: String, CaseIterable, Sendable, Identifiable {
        case flashImage = "gemini-2.5-flash-image"   // Nano Banana — free 500/day

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .flashImage: return "Nano Banana (Gemini 2.5 Flash Image)"
            }
        }
        var freeQuotaPerDay: Int {
            switch self {
            case .flashImage: return 500
            }
        }
        var paidEstimateUSD: Double {
            switch self {
            case .flashImage: return 0.04
            }
        }
    }

    let apiKey: String
    /// Model identifier as returned by Gemini's ListModels endpoint
    /// (e.g. "gemini-2.5-flash-image"). Was previously a hard-coded enum
    /// — switched to a free-form string so the UI can populate from the
    /// API's live model list.
    let modelID: String

    /// Run an image+prompt → image generation. Whole-canvas reimagine.
    /// Throws `ProviderError` on any failure path. `progress` is called
    /// with human-readable status strings so the terminal panel in the
    /// Reimagine sheet shows live action even for cloud calls (where
    /// there's no streaming subprocess to tap into).
    func reimagine(image: CGImage,
                   prompt: String,
                   progress: @Sendable @escaping (String) -> Void = { _ in }) async throws -> CGImage {
        let started = Date()
        // Gemini's image-gen models work best on ≤2048px inputs and can
        // refuse / silently 429 on larger payloads. Downscale once here
        // so the user can have a 4K canvas without thinking about it.
        progress("[Gemini] Preparing source image (max 2048px on long side)…")
        let toSend = downscaleIfNeeded(image, maxDimension: 2048)
        progress("[Gemini] Source: \(toSend.width)×\(toSend.height) → PNG-encoding")
        guard let pngData = encodePNG(toSend) else {
            throw ProviderError.invalidInput("could not encode source image as PNG")
        }
        progress("[Gemini] PNG \(pngData.count / 1024) KB · sending to \(modelID)")
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["inline_data": [
                        "mime_type": "image/png",
                        "data": pngData.base64EncodedString()
                    ]],
                    ["text": prompt],
                ]
            ]],
            "generationConfig": [
                "responseModalities": ["IMAGE"]
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: endpointURL(model: modelID))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = bodyData
        // Gemini image generation can take 10-90s on a good day and
        // 2-4 minutes during peak load or first-call provisioning.
        // 300s (5 min) is long enough to surface real failures without
        // killing legitimate slow generations.
        req.timeoutInterval = 300

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            progress("[Gemini] Network error: \(error.localizedDescription)")
            throw ProviderError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.unknown("non-HTTP response")
        }
        if http.statusCode != 200 {
            progress("[Gemini] HTTP \(http.statusCode) — see error banner")
            throw mapHTTPError(status: http.statusCode, body: data)
        }

        // Parse response JSON → first inline_data → decoded CGImage.
        progress("[Gemini] HTTP 200 · received \(data.count / 1024) KB · decoding")
        let result = try parseImageResponse(data)
        progress("[Gemini] Decoded \(result.image.width)×\(result.image.height) PNG · \(String(format: "%.1f", Date().timeIntervalSince(started)))s total")

        // Record to local quota counter + audit log on success.
        QuotaTracker.shared.record(providerID: GeminiProvider.idValue, modelID: modelID)
        CloudAudit.log(
            provider: "Gemini",
            model: modelID,
            capability: .reimagine,
            inputSize: CGSize(width: image.width, height: image.height),
            outputSize: CGSize(width: result.image.width, height: result.image.height),
            durationSeconds: Date().timeIntervalSince(started),
            bytesIn: pngData.count,
            bytesOut: result.byteCount,
            promptTokens: result.promptTokens,
            outputTokens: result.outputTokens
        )
        return result.image
    }

    /// Cheap key-validation endpoint. Lists models; doesn't count against
    /// any quota. 200 = key valid, 401/403 = invalid.
    func validate() async -> Result<Void, ProviderError> {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)")!
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.unknown("non-HTTP response"))
            }
            switch http.statusCode {
            case 200:        return .success(())
            case 401, 403:   return .failure(.invalidKey)
            default:         return .failure(.unknown("HTTP \(http.statusCode)"))
            }
        } catch {
            return .failure(.network(error))
        }
    }

    /// Discovered image-generation model. The API returns a richer record
    /// per entry; we keep only what the UI needs.
    struct DiscoveredModel: Identifiable, Hashable, Sendable {
        let id: String          // e.g. "gemini-2.5-flash-image" (without "models/" prefix)
        let displayName: String // human-friendly label
        /// True when the model is on Google's free tier (no billing
        /// required). Empirically: only `gemini-2.5-flash-image` (the
        /// exact Nano Banana ID) qualifies as of May 2026. Pro variants
        /// (`gemini-3-pro-image`), newer Flash variants
        /// (`gemini-3.1-flash-image`), and preview variants
        /// (`gemini-2.5-flash-preview-image`) all return `limit: 0` for
        /// free-tier accounts — paid-only despite being listed.
        var isFreeTier: Bool { Self.knownFreeTierModels.contains(id) }
        static let knownFreeTierModels: Set<String> = [
            "gemini-2.5-flash-image",
        ]
    }

    /// Fetch the set of models that:
    ///   (a) support `generateContent` (Gemini conversational API)
    ///   (b) appear capable of returning images — heuristic: model name
    ///       contains "image" OR description mentions image generation.
    /// We deliberately exclude `imagen-*` models because they use the
    /// `:predict` endpoint with a different request shape; supporting
    /// them is a separate provider implementation later.
    func fetchImageModels(apiKey: String) async throws -> [DiscoveredModel] {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.unknown("non-HTTP response")
        }
        switch http.statusCode {
        case 200:        break
        case 401, 403:   throw ProviderError.invalidKey
        default:         throw ProviderError.unknown("HTTP \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw ProviderError.decodeFailure("missing 'models' array")
        }

        var out: [DiscoveredModel] = []
        for m in models {
            // Name comes as "models/gemini-2.5-flash-image" — strip prefix.
            guard let fullName = m["name"] as? String else { continue }
            let id = fullName.hasPrefix("models/") ? String(fullName.dropFirst("models/".count)) : fullName

            // Filter: must support generateContent.
            let methods = (m["supportedGenerationMethods"] as? [String]) ?? []
            guard methods.contains("generateContent") else { continue }

            // Heuristic: name contains "image" — this picks up
            // `gemini-2.5-flash-image` and any future image-capable
            // generateContent models without false-positives from pure
            // text models like `gemini-2.5-pro`.
            let lower = id.lowercased()
            guard lower.contains("image") else { continue }

            // Exclude Imagen (uses predict endpoint, different request shape).
            if lower.hasPrefix("imagen-") { continue }

            let label = (m["displayName"] as? String) ?? id
            out.append(DiscoveredModel(id: id, displayName: label))
        }
        // Sort order: free-tier models FIRST (so the picker defaults to
        // one that actually works for users without billing), then by
        // name for stable ordering. The old "shortest first" sort
        // accidentally surfaced `gemini-3-pro-image` (18 chars, paid-only)
        // ahead of `gemini-2.5-flash-image` (24 chars, free 500/day).
        return out.sorted { a, b in
            if a.isFreeTier != b.isFreeTier { return a.isFreeTier }
            return a.id < b.id
        }
    }

    // MARK: - Internals

    private func endpointURL(model: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    private func mapHTTPError(status: Int, body: Data) -> ProviderError {
        // Try to surface Google's error.message + error.status.
        let detail = parseErrorDetail(body) ?? "HTTP \(status)"
        switch status {
        case 400: return .invalidInput(detail)
        case 401, 403: return .invalidKey
        case 429: return .quotaExceeded(detail: detail)
        default:  return .unknown(detail)
        }
    }

    private func parseErrorDetail(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any] else { return nil }
        return err["message"] as? String
    }

    /// What we extract from a successful `generateContent` response.
    private struct ParsedImage {
        let image: CGImage
        let byteCount: Int
        let promptTokens: Int?
        let outputTokens: Int?
    }

    private func parseImageResponse(_ data: Data) throws -> ParsedImage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decodeFailure("response body not JSON")
        }

        // Surface SAFETY blocks before we hunt for an image part.
        if let candidates = json["candidates"] as? [[String: Any]],
           let first = candidates.first,
           (first["finishReason"] as? String) == "SAFETY" {
            throw ProviderError.contentPolicy
        }

        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw ProviderError.decodeFailure("missing candidates/content/parts")
        }
        // Find the first inline_data part with image bytes.
        var imageData: Data?
        for part in parts {
            if let inline = part["inline_data"] as? [String: Any] ?? part["inlineData"] as? [String: Any],
               let b64 = inline["data"] as? String,
               let bytes = Data(base64Encoded: b64) {
                imageData = bytes
                break
            }
        }
        guard let bytes = imageData else {
            throw ProviderError.decodeFailure("no inline_data image in response parts")
        }
        guard let cg = decodeImage(bytes) else {
            throw ProviderError.decodeFailure("response image bytes failed to decode")
        }

        let usage = json["usageMetadata"] as? [String: Any]
        return ParsedImage(
            image: cg,
            byteCount: bytes.count,
            promptTokens: usage?["promptTokenCount"] as? Int,
            outputTokens: usage?["candidatesTokenCount"] as? Int
        )
    }

    /// Downscale `image` so the longer side ≤ `maxDimension` while
    /// preserving aspect ratio. No-op when the image is already small.
    /// Output is in sRGB premultipliedLast for clean PNG encoding.
    private func downscaleIfNeeded(_ image: CGImage, maxDimension: Int) -> CGImage {
        let w = image.width, h = image.height
        let longSide = max(w, h)
        if longSide <= maxDimension { return image }
        let scale = Double(maxDimension) / Double(longSide)
        let newW = Int((Double(w) * scale).rounded())
        let newH = Int((Double(h) * scale).rounded())
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: newW, height: newH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    private func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func decodeImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
