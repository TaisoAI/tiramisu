# Contributing to Tiramisu

Thanks for considering it. PRs are welcome — small fixes, big features, docs, polish, anything that makes the app better for creators.

## Before you open a PR

For anything beyond a small fix, **open an issue first** to discuss. It saves both of us time if the approach lands wrong, and lets others weigh in.

## Setup

```bash
git clone https://github.com/TaisoAI/tiramisu.git
cd tiramisu
brew install xcodegen
xcodegen generate
open Tiramisu.xcodeproj
```

The xcodeproj is **regenerated from `project.yml`** by xcodegen. Don't edit it by hand — your changes won't survive a regenerate.

## House rules

- **xcodegen-only.** All target / source / dep changes go in `project.yml`. The `.xcodeproj/` is gitignored.
- **No personal paths.** No `/Users/<name>/...`, no `/Volumes/...` baked into source. Use env vars or known per-user locations like `~/Library/Application Support/Tiramisu/`.
- **No telemetry.** Don't add an analytics SDK, don't add a "ping home on launch," don't add Sentry without an explicit opt-in toggle. Zero-telemetry is a wedge against Adobe; we don't compromise it.
- **No new SaaS dependencies** for core features. Cloud-optional is fine (e.g., Replicate as one backend among many); cloud-required is not.
- **Real errors, not silent failures.** Convert `try?` to a real error path with a user-facing alert when the failure matters. Hidden bugs help no one.
- **Sandbox stays off.** The Local FLUX-Fill backend spawns a user-installed subprocess; sandbox would block it. See `docs/sandbox-and-local-flux.md` (in the marketing site repo).

## PR checklist

Before opening a PR, please:

1. `xcodegen generate && xcodebuild -scheme Tiramisu build` — must succeed.
2. Ran the app at least once — no crash on launch, no obvious regression.
3. New file? Added a one-line doc comment on the public type.
4. Changed `project.yml`? Confirm `xcodegen generate` produces a working project from a clean checkout.
5. PR description: what changed, why, what you tested, any tradeoffs.

## License

By contributing, you agree your contributions are licensed under **AGPL-3.0** (matching the project license). If you can't accept that, please don't submit a PR.

If your contribution incorporates someone else's code, please disclose the source and confirm it's compatible with AGPL-3.0.

## Code style

No formal style guide yet. Match what's already in the file. Some loose conventions:

- Prefer `enum` namespaces over `class` for stateless utilities.
- `@MainActor` on anything UI-touching.
- Strict-concurrency-clean (`SWIFT_STRICT_CONCURRENCY: complete` is set).
- Use `tlog(...)` for logging — not `print`.
- Comments explain the **why**, not the **what**. The code shows what.

## Reporting bugs

Open a [GitHub issue](https://github.com/TaisoAI/tiramisu/issues/new). Include:

- macOS version + chip (M-series, year)
- What you did, what you expected, what happened
- Relevant logs from `~/Library/Logs/Tiramisu/Tiramisu.log` (last ~50 lines is usually enough)

For security-sensitive reports, see [SECURITY.md](SECURITY.md) — please don't file public issues for those.

## Things we're explicitly not interested in

- Cross-platform ports (Windows / Linux / web). The whole stack is bet on Apple Silicon native; cross-platform is a different product.
- Optional adware, donation prompts, "Pro tier" features. The app is free, full stop.
- Mac App Store builds (sandbox makes Local FLUX-Fill impossible — see `docs/sandbox-and-local-flux.md` in the site repo).
- Telemetry / analytics / crash reporting that runs by default.

Everything else is fair game. Have at it.
