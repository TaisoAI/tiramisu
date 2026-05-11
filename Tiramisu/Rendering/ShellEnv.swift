import Foundation

/// Captures relevant environment variables from the user's login shell
/// once at app launch. Solves the macOS launchd-vs-shell-init mismatch:
/// when Tiramisu launches from Finder/Dock, it inherits launchd's empty
/// environment, NOT the variables exported in `.zshrc` / `.bash_profile`.
/// That means `HF_HOME` (and similar) set in the user's shell aren't
/// visible to subprocesses we spawn — mflux can't find a cache that
/// lives on an external drive, even when `huggingface-cli login` worked
/// fine from the user's terminal.
///
/// Strategy: spawn `zsh -l -c 'echo $VAR'` once per variable we care
/// about, cache the result, and merge it into every spawned subprocess
/// environment that needs it.
enum ShellEnv {
    /// Variables we sniff. Add to this list if a future subprocess
    /// depends on something else the user might only set in their shell.
    private static let watched = [
        "HF_HOME",          // HuggingFace cache root (defaults to ~/.cache/huggingface)
        "HF_HUB_CACHE",     // alternate cache location override
        "HF_TOKEN",         // some users export the token rather than file it
        "OPENAI_API_KEY",   // for future OpenAI provider
        "ANTHROPIC_API_KEY",// for future Anthropic provider
    ]

    /// Cached result. nil until first call to `resolved()`.
    nonisolated(unsafe) private static var cache: [String: String]?
    private static let cacheLock = NSLock()

    /// Returns the dictionary of resolved env vars. First call may take
    /// 100-300ms (login shell startup). Subsequent calls are free.
    static func resolved() -> [String: String] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache { return cached }
        var out: [String: String] = [:]
        for name in watched {
            if let value = readFromLoginShell(name), !value.isEmpty {
                out[name] = value
            }
        }
        // If HF_TOKEN wasn't exported as an env var, read from the token
        // file. huggingface_hub (v1.12+) checks $HF_HOME/token as fallback,
        // but gated-model HEAD checks still 401 if no Bearer header. Setting
        // HF_TOKEN explicitly ensures the token is used on every HTTP call.
        if out["HF_TOKEN"] == nil {
            let hfHome = out["HF_HOME"] ?? (ProcessInfo.processInfo.environment["HF_HOME"] ?? "")
            let candidates: [String] = [
                hfHome.isEmpty ? "" : (hfHome + "/token"),
                (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/.cache/huggingface/token",
            ]
            for path in candidates where !path.isEmpty {
                if let tok = try? String(contentsOfFile: path, encoding: .utf8) {
                    let t = tok.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out["HF_TOKEN"] = t; break }
                }
            }
        }
        cache = out
        return out
    }

    /// Merge the sniffed env into an existing environment dict, only
    /// adding keys not already present (caller's explicit values win).
    /// Use when spawning subprocesses that need user-shell visibility.
    static func merged(into env: [String: String]) -> [String: String] {
        var result = env
        for (k, v) in resolved() where result[k] == nil {
            result[k] = v
        }
        return result
    }

    // MARK: - Internals

    /// Spawn `zsh -i -l -c 'echo "$VAR"'` and return the trimmed output.
    /// `-l` = login shell (sources `.zprofile`); `-i` = interactive
    /// (also sources `.zshrc`). Both flags together are needed because
    /// some users export env vars like `HF_HOME` only from `.zshrc`.
    /// Running non-interactively would miss them. Output is one line
    /// per call. Failures return nil.
    private static func readFromLoginShell(_ varName: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-i", "-l", "-c", "echo \"$\(varName)\""]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()  // discard
        do {
            try proc.run()
        } catch {
            return nil
        }
        // Bound the wait — we don't want a hung shell init to block app launch.
        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.availableData
        let raw = String(data: data, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
