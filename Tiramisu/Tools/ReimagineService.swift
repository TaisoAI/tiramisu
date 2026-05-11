import Foundation
import CoreGraphics
import AppKit

/// Orchestrates a full Reimagine: snapshot the canvas → call the chosen
/// provider → land the result as a new layer above the active one.
///
/// The provider/model dispatch happens here; the sheet UI and menu hook
/// just call `run()` with the user's prompt. v0.6 dispatches based on
/// the provider's `id`; v0.6.1 will route via Settings → Routing.
@MainActor
enum ReimagineService {

    enum ReimagineError: Error, LocalizedError {
        case noProvider                          // no configured provider supports .reimagine
        case providerFailed(ProviderError)
        case unsupportedProvider(String)         // provider doesn't yet have a Reimagine wrapper
        case canvasSnapshotFailed

        var errorDescription: String? {
            switch self {
            case .noProvider:
                return "No configured provider supports Reimagine. Add a Gemini key in Settings → AI Providers."
            case .providerFailed(let pe):
                return String(describing: pe)
            case .unsupportedProvider(let id):
                return "Provider '\(id)' doesn't support Reimagine in this version."
            case .canvasSnapshotFailed:
                return "Could not snapshot the canvas. Is there at least one visible layer?"
            }
        }
    }

    /// Run a Reimagine against the given store. Result is appended as a
    /// new raster layer above the currently-active layer (or at the top
    /// if no active layer). The new layer becomes active.
    ///
    /// - Parameters:
    ///   - store: the document being edited
    ///   - provider: which provider to dispatch to (caller already chose
    ///               from the per-capability candidates)
    ///   - prompt: user's text prompt
    ///   - sequenceIndex: passed by the sheet so re-rolls can name layers
    ///                    "<prompt> — 1", "<prompt> — 2", etc.
    static func run(store: DocumentStore,
                    provider: any AIImageProvider,
                    prompt: String,
                    sequenceIndex: Int,
                    progress: @Sendable @escaping (String) -> Void = { _ in }) async throws {
        // 1. Snapshot the canvas — what the model sees is exactly what's
        //    composited right now.
        progress("[Reimagine] Snapshotting canvas…")
        guard let canvasImage = LayerRenderer.composite(store: store) else {
            throw ReimagineError.canvasSnapshotFailed
        }
        progress("[Reimagine] Canvas \(canvasImage.width)×\(canvasImage.height) · provider=\(provider.displayName)")

        // 2. Dispatch by provider id. v0.6 ships Gemini only for
        //    Reimagine because LocalFlux's current binary
        //    (`mflux-generate-fill`) and Replicate's default model
        //    (`flux-fill-dev`) are inpainting models, not img2img.
        //    The right local model (FLUX.1-dev via `mflux-generate
        //    --init-image`) ships in v0.6.1.
        let result: CGImage
        switch provider.id {
        case GeminiProvider.idValue:
            do {
                result = try await GeminiProvider().reimagine(image: canvasImage, prompt: prompt, progress: progress)
            } catch let e as ProviderError {
                throw ReimagineError.providerFailed(e)
            } catch {
                throw ReimagineError.providerFailed(.network(error))
            }

        case LocalQwenProvider.idValue:
            do {
                result = try await LocalQwenProvider().reimagine(image: canvasImage, prompt: prompt, progress: progress)
            } catch let e as ProviderError {
                throw ReimagineError.providerFailed(e)
            } catch {
                throw ReimagineError.providerFailed(.network(error))
            }

        case LocalFluxProvider.idValue:
            do {
                result = try await LocalFluxProvider().reimagine(image: canvasImage, prompt: prompt, progress: progress)
            } catch let e as ProviderError {
                throw ReimagineError.providerFailed(e)
            } catch {
                throw ReimagineError.providerFailed(.network(error))
            }

        default:
            throw ReimagineError.unsupportedProvider(provider.id)
        }

        // 3. Wrap the result as a SmartSource so it lands "fit" inside
        //    the canvas (centered, scaled to fit with aspect preserved)
        //    rather than stuffed at native dims and clipped to extent.
        //    Same pattern as Generative Fill so users get consistent
        //    placement semantics across AI features. Smart-source also
        //    means the user can resize/move it freely after.
        guard let png = LayerSnapshot.encodePNG(result) else {
            throw ReimagineError.providerFailed(.decodeFailure("could not encode result as PNG"))
        }
        let canvas = store.canvasSize
        let fitScale = min(
            canvas.width  / max(1, CGFloat(result.width)),
            canvas.height / max(1, CGFloat(result.height))
        )
        let smart = SmartSource(
            sourcePath: nil,
            sourceBytes: png,
            sourceFormat: "png",
            pixelWidth: result.width,
            pixelHeight: result.height,
            centerX: Double(canvas.width / 2),
            centerY: Double(canvas.height / 2),
            scaleX: Double(fitScale),
            scaleY: Double(fitScale)
        )

        store.checkpoint("Reimagine")
        let new = PXLayer(name: layerName(prompt: prompt, sequenceIndex: sequenceIndex), kind: .raster)
        new.smart = smart

        if let active = store.activeLayer,
           let idx = store.layers.firstIndex(where: { $0.id == active.id }) {
            store.layers.insert(new, at: idx + 1)
        } else {
            store.layers.append(new)
        }
        store.activeLayerID = new.id
        store.invalidate()
    }

    /// Pure-white mask the same size as `image`. White = "regenerate this
    /// pixel" for FLUX-Fill semantics, so a full-white mask is equivalent
    /// to "regenerate the entire canvas guided by the prompt." Used to
    /// adapt LocalFlux + Replicate (which expect inpaint-style inputs)
    /// into a Reimagine-style call.
    private static func fullCoverageMask(matching image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Layer name = first 40 chars of the prompt + sequence index.
    /// Lineage by naming + ordering for v0.6; tree visualization is v0.7.
    private static func layerName(prompt: String, sequenceIndex: Int) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = trimmed.count <= 40 ? trimmed : String(trimmed.prefix(40)) + "…"
        return "\(truncated) — \(sequenceIndex)"
    }
}
