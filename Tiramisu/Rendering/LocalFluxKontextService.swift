import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Local FLUX Kontext inference via the user-installed `mflux-generate-kontext`
/// CLI. Kontext is a purpose-built image+prompt → edited image model (released
/// June 2025), which is exactly the semantic we need for Reimagine Whole Image.
/// Unlike FLUX-Fill (inpainting only), Kontext handles the full canvas guided
/// by a text prompt — equivalent to "img2img with prompt steering."
///
/// MLX-native: uses Apple unified memory, not PyTorch+MPS, so it runs far more
/// efficiently on Apple Silicon. With `--quantize 4` the model footprint is
/// ~4 GB vs ~14 GB for the standard transformer.
///
/// Binary: `mflux-generate-kontext` (ships with mflux ≥ 0.9, same uv install
/// the user already has for mflux-generate-fill).
struct LocalFluxKontextService: Sendable {

    static var defaultBinaryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/mflux-generate-kontext")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: defaultBinaryURL.path)
    }

    let binaryURL: URL
    /// MLX quantization level. 4 = ~4 GB footprint (recommended); 8 = near-
    /// lossless but ~8 GB.
    let quantize: Int
    /// Denoising steps. 20 gives good quality; 12-15 is faster with minor loss.
    let steps: Int
    /// How strongly the output departs from the source image. 0 = no change,
    /// 1 = ignore source. 0.75 is a good "whole-canvas reimagine" default —
    /// meaningful transformation while preserving rough composition.
    let imageStrength: Float

    init(binaryURL: URL = LocalFluxKontextService.defaultBinaryURL,
         quantize: Int = 4,
         steps: Int = 8,
         imageStrength: Float = 0.75) {
        self.binaryURL = binaryURL
        self.quantize = quantize
        self.steps = steps
        self.imageStrength = imageStrength
    }

    func reimagine(image: CGImage,
                   prompt: String,
                   progress: @Sendable @escaping (String) -> Void = { _ in }) async throws -> CGImage {
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            throw ProviderError.notConfigured
        }

        // Kontext requires dimensions that are multiples of 16.
        let w = (image.width / 16) * 16
        let h = (image.height / 16) * 16
        guard w >= 256, h >= 256 else {
            throw ProviderError.invalidInput("Canvas too small for Kontext (need ≥256×256, got \(image.width)×\(image.height))")
        }
        let sized: CGImage = (w == image.width && h == image.height) ? image
            : (resize(image, to: CGSize(width: w, height: h)) ?? image)

        let runDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tiramisu-kontext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runDir) }

        let inputURL = runDir.appendingPathComponent("input.png")
        let outputURL = runDir.appendingPathComponent("output.png")
        try writePNG(sized, to: inputURL)

        progress("[Kontext] \(w)×\(h) · Q\(quantize) · \(steps) steps · strength \(imageStrength)")

        // Run via `zsh -l` so the login shell sources the user's .zshrc /
        // .zprofile. This guarantees HF_HOME, HF_TOKEN, and PATH are exactly
        // what the user sees in their terminal — no manual env assembly needed.
        // Shell-quoting: use printf %q to make each argument safe, then pass
        // the whole command as a single string to `zsh -l -c`.
        let quotedArgs: [String] = [
            binaryURL.path,
            "--image-path",     inputURL.path,
            "--image-strength", "\(imageStrength)",
            "--prompt",         prompt,
            "--quantize",       "\(quantize)",
            "--steps",          "\(steps)",
            "--height",         "\(h)",
            "--width",          "\(w)",
            "--output",         outputURL.path,
        ].map { shellQuote($0) }
        let shellCmd = quotedArgs.joined(separator: " ")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", shellCmd]
        // Merge sniffed shell vars (HF_HOME, HF_TOKEN, etc.) into the
        // app's launchd environment. ShellEnv runs zsh -i -l so it picks
        // up both .zprofile and .zshrc. Without this, HF_HOME set in
        // .zshrc is invisible to the subprocess and mflux can't find the
        // model cache on an external drive.
        proc.environment = ShellEnv.merged(into: ProcessInfo.processInfo.environment)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe

        let lineBuffer = LineBuffer(capacity: 80)
        do { try proc.run() } catch { throw ProviderError.network(error) }

        let streamTask = Task.detached(priority: .utility) {
            // tqdm writes progress with \r (not \n) when stdout/stderr is
            // not a TTY. Swift's .lines splits only on \n, so we'd see
            // nothing until the process exits. Read bytes manually and
            // flush on both \r and \n so each step appears immediately.
            var accum = Data()
            do {
                for try await byte in pipe.fileHandleForReading.bytes {
                    if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                        if let s = String(data: accum, encoding: .utf8) {
                            let t = s.trimmingCharacters(in: .whitespaces)
                            if !t.isEmpty {
                                await lineBuffer.append(t)
                                progress(t)
                            }
                        }
                        accum = Data()
                    } else {
                        accum.append(byte)
                    }
                }
            } catch {}
            if let s = String(data: accum, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { await lineBuffer.append(t); progress(t) }
            }
        }
        // Wait for the process, honouring task cancellation. If the parent
        // task is cancelled (user hit Cancel), we kill the subprocess so it
        // doesn't linger as a zombie mflux process eating GPU memory.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proc.terminationHandler = { _ in cont.resume() }
            }
        } onCancel: {
            proc.terminate()
        }
        streamTask.cancel()

        guard proc.terminationStatus == 0 else {
            let tail = await lineBuffer.snapshot().suffix(40).joined(separator: "\n")
            throw ProviderError.unknown("mflux-generate-kontext exited \(proc.terminationStatus). Last output:\n\(tail.isEmpty ? "(no output)" : tail)")
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ProviderError.decodeFailure("mflux-generate-kontext did not write output to \(outputURL.path)")
        }
        guard let src = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ProviderError.decodeFailure("Could not decode Kontext output PNG")
        }
        // Re-tag as sRGB to avoid the genericRGB→sRGB transform CoreGraphics
        // applies to ICC-profile-less PNGs from Python/PIL pipelines.
        return retagAsSRGB(cg)
    }

    // MARK: - Helpers

    private func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil,
                                  width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ProviderError.invalidInput("Could not create PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ProviderError.invalidInput("Could not write PNG at \(url.path)")
        }
    }

    /// POSIX single-quote escaping: wrap in single quotes, escape embedded
    /// single quotes as '\''. Safe for any string including prompts with
    /// spaces, quotes, or shell metacharacters.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func retagAsSRGB(_ raw: CGImage) -> CGImage {
        guard let provider = raw.dataProvider,
              let data = provider.data,
              let dp = CGDataProvider(data: data),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return raw }
        return CGImage(
            width: raw.width, height: raw.height,
            bitsPerComponent: raw.bitsPerComponent,
            bitsPerPixel: raw.bitsPerPixel,
            bytesPerRow: raw.bytesPerRow,
            space: srgb, bitmapInfo: raw.bitmapInfo,
            provider: dp, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ) ?? raw
    }
}
