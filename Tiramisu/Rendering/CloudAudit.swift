import Foundation

/// Append-only audit log of every cloud AI call. One file:
/// `~/Library/Logs/Tiramisu/cloud-audit.log`. Never sent anywhere.
///
/// This is what makes "your image never leaves your Mac without you
/// knowing" provable — the file is human-readable, the user can `tail`
/// it, the app reads it back into Debug → Cloud Audit (in v0.6.1).
///
/// Format chosen for grep-ability + future parsing:
///   `2026-05-11T18:42:33Z [Gemini gemini-2.5-flash-image] reimagine 1280x720 → 1280x720, 1.2s, 38KB→42KB, 1290+1290 tokens`
enum CloudAudit {
    /// Where the file lives. Created on first write; readable by the user.
    static var fileURL: URL {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Tiramisu", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir,
                                                 withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("cloud-audit.log")
    }

    /// Record one call. Token counts are optional — providers that don't
    /// return usage metadata pass `nil`.
    static func log(provider: String,
                    model: String,
                    capability: AIImageCapability,
                    inputSize: CGSize,
                    outputSize: CGSize,
                    durationSeconds: Double,
                    bytesIn: Int? = nil,
                    bytesOut: Int? = nil,
                    promptTokens: Int? = nil,
                    outputTokens: Int? = nil) {
        var line = nowISO()
        line += " [\(provider) \(model)] \(capability.rawValue)"
        line += " \(Int(inputSize.width))x\(Int(inputSize.height))"
        line += " → \(Int(outputSize.width))x\(Int(outputSize.height))"
        line += String(format: ", %.1fs", durationSeconds)
        if let bIn = bytesIn, let bOut = bytesOut {
            line += ", \(formatKB(bIn))→\(formatKB(bOut))"
        }
        if let pt = promptTokens, let ot = outputTokens {
            line += ", \(pt)+\(ot) tokens"
        }
        line += "\n"
        append(line)
    }

    /// Lower-level: just append a raw line (caller pre-formats). Used for
    /// errors / cancellations the structured signature doesn't cover.
    static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Built per call rather than a static — ISO8601DateFormatter isn't
    /// Sendable, and the cost of constructing one is trivial vs the HTTP
    /// call we're logging about.
    private static func nowISO() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    private static func formatKB(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        return "\(bytes / 1024)KB"
    }
}
