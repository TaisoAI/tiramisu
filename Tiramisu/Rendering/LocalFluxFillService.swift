import Foundation
import CoreGraphics
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Local FLUX.1-Fill-dev inference via the user-installed `mflux` CLI.
///
/// Architecture: Tiramisu does NOT bundle Python, mflux, or the FLUX weights —
/// the FLUX.1-Fill-dev license is non-commercial, weights are gated, and the
/// download is ~30 GB. Instead, the user opts in by installing mflux locally
/// (one-time setup, see `LocalFluxFillService.setupInstructions`). We detect
/// the binary and shell out for inference.
///
/// What we send the subprocess:
///   --image-path      = canvas-size source image
///   --masked-image-path = canvas-size mask (white = inpaint, black = preserve)
///   --output          = our temp PNG
///
/// FLUX-Fill handles arbitrary image sizes (multiples of 16), so unlike the
/// 9-ch local SD path we do NOT tile. preferredInputSize stays nil so the
/// Coordinator single-passes the whole canvas.
struct LocalFluxFillService: GenerativeFillService {
    let mfluxPath: URL
    let modelHFCacheDir: URL?     // optional HF_HOME override; nil = inherit user's env
    let stepCount: Int
    let guidanceScale: Float
    let quantize: Int             // 3 / 4 / 5 / 6 / 8 (Q4 default — fits comfortably on M1 Max)
    let extraEnv: [String: String]

    init(mfluxPath: URL = LocalFluxFillService.defaultBinaryURL,
         modelHFCacheDir: URL? = nil,
         stepCount: Int = 28,            // matches multimodalart/flux-fill-outpaint default
         guidanceScale: Float = 30.0,    // matches HF Space default
         quantize: Int = 8,              // Q8 ≈ bf16 fidelity; ~half Q4's color drift
         extraEnv: [String: String] = [:]) {
        self.mfluxPath = mfluxPath
        self.modelHFCacheDir = modelHFCacheDir
        self.stepCount = stepCount
        self.guidanceScale = guidanceScale
        self.quantize = quantize
        self.extraEnv = extraEnv
    }

    /// FLUX-Fill processes arbitrary sizes — no tiling needed.
    var preferredInputSize: CGSize? { nil }

    static var defaultBinaryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/mflux-generate-fill")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: defaultBinaryURL.path)
    }

    static var setupInstructions: String {
        """
        Local FLUX-Fill needs a one-time install (mflux + ~24 GB model weights).

        Easiest path: click "Install Local FLUX-Fill…" below. That opens
        Terminal and runs the bundled bootstrap script which handles uv,
        mflux, the Hugging Face login prompt, and the model download.

        Or run it manually:
          1. brew install uv
          2. uv tool install mflux
          3. Accept the FLUX-Fill license at
             https://huggingface.co/black-forest-labs/FLUX.1-Fill-dev
          4. hf auth login
          5. (If short on disk) Set HF_HOME to an external drive.

        Tiramisu looks for mflux-generate-fill at ~/.local/bin/. Each fill
        takes ~2 minutes on M1 Max with Q4 quantization.

        License note: FLUX.1-Fill-dev is NON-COMMERCIAL. Personal use only.
        Switch to Replicate (cloud) if you need commercial use.
        """
    }

    func fill(image: CGImage,
              mask: CGImage,
              prompt: String,
              progress: @Sendable @escaping (String) -> Void) async throws -> CGImage {
        // DEBUG fast-path: if a cached raw-output PNG exists at the known
        // debug path and the env var THUMBZ_FLUX_USE_CACHED is set, return
        // it immediately instead of spawning mflux. Lets us iterate on the
        // Coordinator's post-processing in seconds. Toggle off to re-run live.
        let env = ProcessInfo.processInfo.environment
        let useCache = env["THUMBZ_FLUX_USE_CACHED"] != nil
            || FileManager.default.fileExists(atPath: "/tmp/tiramisu-flux-use-cached")
        if useCache {
            let cachedURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tiramisu-flux-raw-output.png")
            if let cached = Self.loadAndRetagAsSRGB(cachedURL) {
                progress("Using cached mflux output (debug fast-path)")
                return cached
            }
        }

        guard FileManager.default.fileExists(atPath: mfluxPath.path) else {
            throw GenerativeFillError.predictionFailed(
                "mflux-generate-fill not found at \(mfluxPath.path).\n\n" + Self.setupInstructions)
        }
        // FLUX-Fill expects dims that are multiples of 16. Round to nearest.
        let w = (image.width / 16) * 16
        let h = (image.height / 16) * 16
        guard w >= 256, h >= 256 else {
            throw GenerativeFillError.predictionFailed("Input too small for FLUX-Fill (need >= 256×256, got \(image.width)×\(image.height))")
        }
        let imgSized: CGImage = (w == image.width && h == image.height) ? image
            : (Self.resize(image, to: CGSize(width: w, height: h)) ?? image)
        let maskSized: CGImage = (w == mask.width && h == mask.height) ? mask
            : (Self.resize(mask, to: CGSize(width: w, height: h)) ?? mask)

        let runDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tiramisu-flux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runDir) }
        let imgURL = runDir.appendingPathComponent("image.png")
        let maskURL = runDir.appendingPathComponent("mask.png")
        let outURL = runDir.appendingPathComponent("output.png")
        try Self.writePNG(imgSized, to: imgURL)
        try Self.writePNG(maskSized, to: maskURL)

        progress("Spawning mflux-generate-fill (\(w)×\(h), Q\(quantize))…")
        let proc = Process()
        proc.executableURL = mfluxPath
        proc.arguments = [
            "--model", "dev",
            "--quantize", "\(quantize)",
            "--steps", "\(stepCount)",
            "--guidance", "\(guidanceScale)",
            "--height", "\(h)",
            "--width", "\(w)",
            "--image-path", imgURL.path,
            "--masked-image-path", maskURL.path,
            "--output", outURL.path,
            // Match multimodalart/flux-fill-outpaint HF Space exactly:
            // empty prompt, no negative prompt. Descriptive prompts and long
            // negatives were cuing the model to generate content (faces, etc.)
            // instead of cleanly extending the surrounding texture.
            "--prompt", prompt,
        ]
        // Inherit user environment (PATH, HF_HOME, HF_TOKEN if set in their shell)
        // and merge any explicit overrides we want to set programmatically.
        //
        // Two macOS-specific fixes layered here:
        //
        // 1) launchd-vs-shell-init: when Tiramisu is launched from Finder/Dock,
        //    ProcessInfo.environment does NOT include vars set in the user's
        //    `.zshrc` / `.zprofile` — launchd doesn't source those. ShellEnv
        //    runs a one-shot login shell to capture HF_HOME / HF_TOKEN / etc.
        //
        // 2) Token-resolution flake in huggingface_hub: even when HF_HOME is
        //    correctly set to a non-default path, some huggingface_hub
        //    versions (especially under uv-isolated tool envs like mflux)
        //    look at ~/.cache/huggingface/token rather than $HF_HOME/token
        //    and silently 401 on gated repos. Bulletproof fix: read the
        //    token ourselves, set HF_TOKEN explicitly. That env var
        //    overrides every other lookup in every huggingface_hub release.
        var subprocEnv = ShellEnv.merged(into: ProcessInfo.processInfo.environment)
        if let cache = modelHFCacheDir {
            subprocEnv["HF_HOME"] = cache.path
        }
        // Pin HF_TOKEN from whatever token file we can find — caller-supplied
        // env wins, then HF_HOME/token, then default ~/.cache/huggingface/token.
        if subprocEnv["HF_TOKEN"] == nil || subprocEnv["HF_TOKEN"]?.isEmpty == true {
            let hfHomeForToken = subprocEnv["HF_HOME"] ?? NSString(string: "~/.cache/huggingface").expandingTildeInPath
            let tokenPath = NSString(string: hfHomeForToken).appendingPathComponent("token")
            if let raw = try? String(contentsOfFile: tokenPath, encoding: .utf8) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    subprocEnv["HF_TOKEN"] = trimmed
                    tlog("LocalFlux: passing HF_TOKEN from \(tokenPath) (len=\(trimmed.count))")
                }
            }
        }
        for (k, v) in extraEnv { subprocEnv[k] = v }
        proc.environment = subprocEnv

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        try proc.run()

        // Stream stdout/stderr lines into the progress callback so the user
        // sees per-step inference updates. We *also* keep every line in a
        // ring buffer so the failure path has real diagnostics — earlier
        // versions only relied on `readToEnd` after exit, which returned
        // ~nothing because the stream had already drained the pipe.
        let lineBuffer = LineBuffer(capacity: 80)
        let streamTask = Task.detached {
            let handle = outPipe.fileHandleForReading
            do {
                for try await line in handle.bytes.lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }
                    await lineBuffer.append(trimmed)
                    if trimmed.contains("%") || trimmed.contains("step") || trimmed.contains("Fetching") {
                        progress(trimmed)
                    }
                }
            } catch {
                // Stream errors are usually pipe-closed-by-exit, harmless.
            }
        }
        proc.waitUntilExit()
        // Give the stream a beat to drain any final lines after exit.
        try? await Task.sleep(nanoseconds: 100_000_000)
        streamTask.cancel()

        guard proc.terminationStatus == 0 else {
            let captured = await lineBuffer.snapshot()
            let tail = captured.suffix(40).joined(separator: "\n")
            terr("mflux exited \(proc.terminationStatus). Captured \(captured.count) line(s). Tail:\n\(tail)")
            throw GenerativeFillError.predictionFailed(
                "mflux exited \(proc.terminationStatus). Last output:\n\(tail.isEmpty ? "(no output captured — check Console for stderr)" : tail)")
        }

        progress("Decoding output…")
        // Save a copy of mflux's raw output where the rest of our debug
        // dumps live, so we can inspect what the model actually produced.
        let preservedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tiramisu-flux-raw-output.png")
        try? FileManager.default.removeItem(at: preservedURL)
        try? FileManager.default.copyItem(at: outURL, to: preservedURL)

        guard let result = Self.loadAndRetagAsSRGB(outURL) else {
            throw GenerativeFillError.predictionFailed("Could not decode \(outURL.path)")
        }
        return result
    }

    /// Load a PNG and rebuild the CGImage with the same byte buffer but
    /// tagged as sRGB — bypasses the genericRGB→sRGB color conversion that
    /// CGImageSource applies to ICC-profile-less PNGs (which is what PIL
    /// emits). No actual pixel conversion; just an override of the tag so
    /// downstream draws skip any colorimetric transform.
    private static func loadAndRetagAsSRGB(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let provider = raw.dataProvider,
              let data = provider.data,
              let reTagged = CGDataProvider(data: data) else { return nil }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return CGImage(
            width: raw.width,
            height: raw.height,
            bitsPerComponent: raw.bitsPerComponent,
            bitsPerPixel: raw.bitsPerPixel,
            bytesPerRow: raw.bytesPerRow,
            space: srgb,
            bitmapInfo: raw.bitmapInfo,
            provider: reTagged,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) ?? raw
    }

    // MARK: - helpers

    static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        if image.width == Int(size.width) && image.height == Int(size.height) { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw GenerativeFillError.predictionFailed("Could not create PNG dest at \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw GenerativeFillError.predictionFailed("Could not write PNG at \(url.path)")
        }
    }
}

/// Bounded ring buffer of stream lines for diagnostics. Keeps memory
/// flat across long subprocess runs while still preserving the tail
/// that matters when the subprocess fails. Actor-isolated so the
/// streaming task and the post-exit reader don't race. Internal-by-default
/// (was private) so both `LocalFluxFillService` and `LocalQwenImageService`
/// share the same diagnostic plumbing.
actor LineBuffer {
    private var lines: [String] = []
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    func snapshot() -> [String] { lines }
}
