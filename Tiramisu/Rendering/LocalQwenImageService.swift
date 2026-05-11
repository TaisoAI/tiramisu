import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Local Qwen-Image-Edit inference via the user-installed `qwen-image-mps`
/// CLI. Apache-2.0 model, no gated-repo auth needed. Architecturally
/// designed for the Reimagine workflow — Qwen-Image-Edit is purpose-
/// trained on (image, edit-prompt → new image) pairs, unlike FLUX which
/// is text-to-image with an img2img mode bolted on.
///
/// Install (one-time): `uv tool install qwen-image-mps`
/// Binary at `~/.local/bin/qwen-image-mps`. Same uv-managed pattern as
/// the user's existing mflux setup.
struct LocalQwenImageService: Sendable {

    /// Quantization presets exposed in Settings. Q4_K_M balances quality
    /// and memory; Q6_K is higher quality but uses more RAM; Q8_0 is
    /// near-lossless but tight on 32GB Macs.
    enum Quantization: String, CaseIterable, Sendable, Identifiable {
        case q4KM = "Q4_K_M"     // ~6 GB peak, fastest, recommended default for 32GB Macs
        case q6K  = "Q6_K"       // ~8 GB peak, better detail
        case q8   = "Q8_0"       // ~10 GB peak, near-lossless

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .q4KM: return "Q4_K_M (balanced, ~6 GB)"
            case .q6K:  return "Q6_K (higher detail, ~8 GB)"
            case .q8:   return "Q8_0 (near-lossless, ~10 GB)"
            }
        }
    }

    /// Speed mode. Qwen-Image-Edit's default (`normal`) is 40 inference
    /// steps and produces the highest quality. The Rapid-AIO transformer
    /// (`fast`) finishes in 4 steps with marginal quality loss — that's
    /// our default because 10-20s feels live whereas 60-90s breaks flow.
    enum Mode: String, CaseIterable, Sendable, Identifiable {
        case fast    = "fast"     // -f flag, 4 steps, ~10-20s on M1 Max
        case normal  = "normal"   // 40 steps, ~60-90s on M1 Max

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .fast:   return "Fast (4-step Rapid-AIO, ~10-20s)"
            case .normal: return "Normal (40-step, ~60-90s, higher quality)"
            }
        }
    }

    /// Default install path for the binary. User-overridable in
    /// Settings if they've installed somewhere non-standard.
    static var defaultBinaryURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.local/bin/qwen-image-mps").expandingTildeInPath)
    }

    let binaryURL: URL
    let quantization: Quantization
    let mode: Mode

    init(binaryURL: URL = LocalQwenImageService.defaultBinaryURL,
         quantization: Quantization = .q4KM,
         mode: Mode = .fast) {
        self.binaryURL = binaryURL
        self.quantization = quantization
        self.mode = mode
    }

    /// One-time setup instructions surfaced in the Settings panel when
    /// the binary isn't present. uv is widely installed already on Macs
    /// running mflux; tagging the prerequisite explicitly anyway.
    static let setupInstructions = """
    Local Qwen-Image-Edit needs a one-time install (qwen-image-mps + ~20 GB \
    model weights on first run).

    Prerequisites: uv (https://docs.astral.sh/uv/) — already installed if \
    you set up mflux.

      uv tool install qwen-image-mps

    Tiramisu looks for the binary at ~/.local/bin/qwen-image-mps. First \
    Reimagine call will download Qwen-Image-Edit weights to your HF cache \
    ($HF_HOME or ~/.cache/huggingface).
    """

    /// Run an image+prompt → image edit. Whole-canvas Reimagine via the
    /// `edit` subcommand. Throws `ProviderError` on any failure path.
    /// `progress` is called for every stdout/stderr line so the UI can
    /// show live subprocess output (model download progress, denoising
    /// step counts, etc.) in a terminal-style component.
    func reimagine(image: CGImage,
                   prompt: String,
                   progress: @Sendable @escaping (String) -> Void = { _ in }) async throws -> CGImage {
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            throw ProviderError.notConfigured
        }

        let started = Date()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let inputPath = tmpDir.appendingPathComponent("tiramisu-qwen-in-\(UUID().uuidString).png")
        let outputName = "tiramisu-qwen-out-\(UUID().uuidString).png"
        let outputPath = tmpDir.appendingPathComponent(outputName)

        // Encode canvas to PNG for the subprocess.
        guard let pngData = encodePNG(image) else {
            throw ProviderError.invalidInput("could not encode source as PNG")
        }
        do {
            try pngData.write(to: inputPath)
        } catch {
            throw ProviderError.invalidInput("could not write source PNG to temp")
        }
        defer {
            try? FileManager.default.removeItem(at: inputPath)
            try? FileManager.default.removeItem(at: outputPath)
        }

        // Build args. `--fast` is mutually exclusive with `--steps` so we
        // skip the step count when fast mode is selected — qwen-image-mps
        // internally pins it to 4 in that mode.
        // NOTE: --quantization is intentionally omitted for `edit`. As of
        // qwen-image-mps 0.7.x, GGUF quantized models exist only for the
        // `generate` subcommand; passing --quantization to `edit` downloads
        // a GGUF file and then falls back to the full standard transformer
        // anyway. Drop it until the tool adds native GGUF edit support.
        var args: [String] = [
            "edit",
            "-i", inputPath.path,
            "-p", prompt,
            "-o", outputName,
            "--outdir", tmpDir.path,
        ]
        if mode == .fast {
            args.append("-f")
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = args
        // Same launchd-vs-shell-init + HF_TOKEN-explicit-pass treatment
        // we apply to mflux. Both honour the same HF_HOME variable.
        var subprocEnv = ShellEnv.merged(into: ProcessInfo.processInfo.environment)
        if subprocEnv["HF_TOKEN"]?.isEmpty != false {
            // huggingface-cli login writes to ~/.cache/huggingface/token
            // (default) regardless of where HF_HOME points, so check that
            // path first, then fall back to $HF_HOME/token.
            let candidates: [String] = [
                NSString(string: "~/.cache/huggingface/token").expandingTildeInPath,
                NSString(string: subprocEnv["HF_HOME"] ?? "~/.cache/huggingface")
                    .expandingTildeInPath
                    .appending("/token"),
            ]
            for path in candidates {
                if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        subprocEnv["HF_TOKEN"] = trimmed
                        subprocEnv["HUGGING_FACE_HUB_TOKEN"] = trimmed  // legacy alias
                        break
                    }
                }
            }
        }
        proc.environment = subprocEnv

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Capture output for diagnostics — same LineBuffer pattern as mflux.
        let lineBuffer = LineBuffer(capacity: 80)
        do {
            try proc.run()
        } catch {
            throw ProviderError.network(error)
        }
        let streamTask = Task.detached {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    await lineBuffer.append(trimmed)
                    // Surface to the UI in real time so the terminal-style
                    // view in the Reimagine sheet shows download/step
                    // progress as it happens.
                    progress(trimmed)
                }
            }
        }
        proc.waitUntilExit()
        try? await Task.sleep(nanoseconds: 100_000_000)
        streamTask.cancel()

        guard proc.terminationStatus == 0 else {
            let captured = await lineBuffer.snapshot()
            let tail = captured.suffix(40).joined(separator: "\n")
            throw ProviderError.unknown("qwen-image-mps exited \(proc.terminationStatus). Last output:\n\(tail.isEmpty ? "(no output)" : tail)")
        }

        // Decode the output file.
        guard FileManager.default.fileExists(atPath: outputPath.path) else {
            throw ProviderError.decodeFailure("qwen-image-mps did not produce expected output at \(outputPath.path)")
        }
        guard let outData = try? Data(contentsOf: outputPath),
              let src = CGImageSourceCreateWithData(outData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ProviderError.decodeFailure("could not decode qwen-image-mps output PNG")
        }

        QuotaTracker.shared.record(providerID: LocalQwenProvider.idValue, modelID: "qwen-image-edit")
        CloudAudit.log(
            provider: "Local Qwen",
            model: "qwen-image-edit (\(mode.rawValue), \(quantization.rawValue))",
            capability: .reimagine,
            inputSize: CGSize(width: image.width, height: image.height),
            outputSize: CGSize(width: cg.width, height: cg.height),
            durationSeconds: Date().timeIntervalSince(started),
            bytesIn: pngData.count,
            bytesOut: outData.count
        )
        return cg
    }

    // MARK: - Internals

    private func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
