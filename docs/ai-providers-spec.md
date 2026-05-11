# AI Providers + Reimagine — v0.6 spec

Written 2026-05-11. The canonical engineering doc for the v0.6 AI
Providers settings surface and the first feature built on top of it,
**Reimagine Whole Image**. Mirrored on the intranet at
`/internal/v0-6-ai-providers-spec.html`.

This is the spec we build to. Drift from this doc means either we
update the doc first or we revisit the design.

---

## 1. Problem + goals

The current AI surface is a single popup ("AI → Generative Fill
Settings") with one provider config (Replicate API key) and one
backend toggle (Replicate vs LocalFlux). It works for the v0.5
generative-fill flow but doesn't scale to:

- Multiple cloud providers (Gemini, OpenAI, Anthropic, Stability,
  Black Forest Labs Direct, Together, Fal …).
- Multiple capabilities (img2img reimagine, inpaint, outpaint, segment,
  upscale, decompose-to-layers).
- Per-feature provider selection (Reimagine = Gemini, Generative Fill =
  LocalFlux, Smart Select = built-in Vision, Auto-Layer = Qwen ML).
- The "free first" creator path that lets a new user try AI in 30
  seconds with zero install + zero payment.

**Goals (v0.6):**

1. One central **AI Providers** settings pane managing all keys + model
   choices.
2. **Gemini** as a first-class new provider — free tier 500 RPD, the
   zero-friction path for new users.
3. **Reimagine Whole Image** feature — composite canvas + prompt →
   Gemini → result as a new layer above the active layer.
4. **Audit log** of every cloud call (file-based for now, no UI).

**Explicit non-goals (defer to v0.6.1 / v0.7):**

- Capability routing UI ("which provider serves Reimagine"). Hard-code
  defaults in v0.6, expose dropdown later.
- Local Only master switch. Document the pattern, ship the switch in
  v0.6.1.
- Cost-per-call estimation in the Reimagine sheet.
- Prompt history / favorites.
- Keychain storage for API keys — UserDefaults is sufficient for the
  threat model (single-user creator tool, BYO keys).
- Reimagine Selection (selection-scoped img2img). v0.6.1.

---

## 2. Provider model

Tiny protocol; expand as features land. Lives in
`Tiramisu/Rendering/AIProvider.swift` (new file).

```swift
enum AIImageCapability: String, Codable, Sendable, CaseIterable {
    case reimagine        // image + prompt → image
    case inpaint          // image + mask + prompt → filled image
    case outpaint         // image + mask of empty bands + prompt → expanded image
    case segment          // image + click → mask
    case upscale          // image → larger image
    case removeBackground // image → image with bg alpha=0
    case decomposeLayers  // image → [RGBA layers]
}

protocol AIImageProvider: Sendable {
    var id: String { get }                                // "gemini" / "replicate" / "localflux"
    var displayName: String { get }                       // "Google Gemini"
    var capabilities: Set<AIImageCapability> { get }
    var requiresAPIKey: Bool { get }                      // false for LocalFlux
    var helpURL: URL { get }                              // where to get an API key

    /// Per-(provider, model, capability) cost characterization. Used by
    /// the Reimagine sheet to show a green/yellow/red cost line BEFORE
    /// the user spends a call. Estimates only — no provider returns
    /// authoritative pre-call billing data, so this is published-rate
    /// info paired with a local quota counter (see QuotaTracker).
    func costModel(for capability: AIImageCapability, model: String) -> ProviderCostModel

    /// True if the provider is configured + ready (key present, binary
    /// installed, etc.). Cheap; called on every settings panel render.
    var isConfigured: Bool { get }

    /// Optional sanity check — hit a free endpoint to verify the key
    /// isn't malformed. Called when user clicks "Test" in settings.
    /// Default impl returns true.
    func validateConfiguration() async -> Result<Void, ProviderError>
}

enum ProviderCostModel: Sendable {
    /// Always free, runs on the user's hardware. e.g. LocalFlux.
    case alwaysFree

    /// Free quota of N calls per UTC-day (or local, depending on
    /// provider), then the per-call rate kicks in IF the user has billing
    /// enabled on their account. e.g. Gemini 500/day free, then ~$0.04.
    case freeQuotaThenPaid(perDay: Int, paidEstimateUSD: Double)

    /// Pure pay-per-call. e.g. Replicate, OpenAI.
    case payPerCall(estimateUSD: Double)

    /// We don't know — show "Cost: unknown" in the UI rather than lie.
    case unknown
}
```

Each provider conforms in its own file:
`GeminiProvider.swift`, `ReplicateProvider.swift`, `LocalFluxProvider.swift`,
etc. Capability-specific calls (e.g. `reimagine(image:prompt:)`) live
on protocol extensions or per-provider — start ad-hoc, formalize once
two providers implement the same capability.

**Provider registry** is a single `enum AIProviders` with
`static let all: [any AIImageProvider]`. No dynamic loading, no
plugin architecture in v0.6.

---

## 3. Settings architecture

**Standard macOS Settings window.** SwiftUI `Settings { ... }` Scene at
the app root. Discovered via `⌘,`. One pane today; structured to grow.

```
Tiramisu Settings
├── AI Providers       (this v0.6)
├── (future) Routing   — per-feature provider selection
├── (future) Privacy   — Local Only mode + audit log surface
├── (future) Editor    — workspace prefs
```

**AI Providers pane layout:**

```
┌─ AI Providers ─────────────────────────────────────────┐
│                                                        │
│  Add cloud or local AI providers. Tiramisu uses your   │
│  keys for your generations — they don't pass through   │
│  our servers. Local providers run entirely on your Mac.│
│                                                        │
│  ▸ Gemini (Google)              ◯ Configured           │
│    Capabilities: Reimagine                             │
│    API key: [········] [Test] [Get free key →]         │
│    Model: [Gemini 2.5 Flash Image ▾] (free 500/day)    │
│                                                        │
│  ▸ Replicate                    ● Not configured       │
│    Capabilities: Inpaint, Outpaint, Reimagine          │
│    API key: [        ] [Test] [Get key →]              │
│    Model: [black-forest-labs/flux-fill-dev ▾]          │
│                                                        │
│  ▸ LocalFlux (on-device)        ● Not installed        │
│    Capabilities: Inpaint, Outpaint, Reimagine          │
│    Status: mflux-generate-fill not found at ~/.local/  │
│    [Show install instructions]                         │
│                                                        │
└────────────────────────────────────────────────────────┘
```

Each provider row is a disclosure group with consistent fields:
status dot, capability list, key field (when applicable), test button,
help link, model selector, free-quota note. Rows render via a single
`ProviderRow` view, configured per provider.

**Storage:**

- API keys: `UserDefaults.standard` under namespaced keys
  (`ai.taiso.tiramisu.gemini.apiKey`, etc.). The existing
  `ai.taiso.tiramisu.replicate.apiKey` stays put — zero migration.
- Selected model per provider: `ai.taiso.tiramisu.{providerID}.model`.
- Per-feature provider routing (when added): `ai.taiso.tiramisu.routing.{capability}`.

**Why not Keychain in v0.6:** keychain adds a first-run permission
dialog, ~80 LOC of `SecItem` plumbing, mock layers in tests, and
migration work for the existing Replicate key. The threat model is a
single-user creator tool storing the user's own BYO keys; the user can
audit the source. UserDefaults is the right choice for v0.6. A future
security pass can move to Keychain if a real complaint emerges.

### Cost-awareness via QuotaTracker

The Reimagine sheet should show a clear cost line BEFORE the user
spends a call: "Free (487/500 today)" / "Paid (~$0.04/call)" /
"$0 — runs on your Mac". The honest reality across providers:

- **No major AI API exposes live remaining-quota in response headers.**
  Gemini doesn't, OpenAI doesn't, Replicate doesn't. We can only
  approximate.
- **No major API tells us the user's billing tier reliably.** Gemini's
  free vs paid mode depends on whether the user enabled billing on
  their Google Cloud project — that's invisible without admin scope.

So we approximate, *honestly*:

1. Each provider declares its `costModel` per (capability, model) — see
   the protocol above. Hard-coded from published pricing pages.
2. A central `QuotaTracker` actor records every call locally
   (`{providerID}.{modelID}.{YYYY-MM-DD}` → call count) in
   UserDefaults. Resets daily.
3. The Reimagine sheet asks the provider its `costModel` and asks
   `QuotaTracker` for today's count, then renders one of:

| State                                  | Color | Example label                                                         |
|----------------------------------------|-------|-----------------------------------------------------------------------|
| Free, plenty of quota                  | 🟢    | "Free (487/500 used today)"                                           |
| Free, near limit (≥80%)                | 🟡    | "Free (495/500 — almost out)"                                          |
| Free quota exhausted on free-then-paid | 🔴    | "Free quota exhausted — next call ~$0.04 if billing is enabled"       |
| Pay-per-call                           | 💵    | "Paid (~$0.04 per call)"                                              |
| Always free local                      | 💻    | "Free (runs on your Mac)"                                             |
| Unknown                                | ❓    | "Cost: unknown — check your provider dashboard"                       |

**Disclaimer line in the sheet** (small, secondary text): "Estimates
based on published rates. Cross-app calls (e.g. gemini.google.com web,
other tools) can drift the count — your provider dashboard is
authoritative."

`QuotaTracker.swift` shape:

```swift
@MainActor
actor QuotaTracker {
    static let shared = QuotaTracker()

    /// Increment today's count for (providerID, modelID).
    func record(providerID: String, modelID: String)

    /// How many calls today (resets at local midnight)?
    func count(providerID: String, modelID: String) -> Int

    /// Convenience: is this provider/model under its free quota right now?
    func underFreeQuota(provider: any AIImageProvider,
                       capability: AIImageCapability,
                       modelID: String) -> Bool
}
```

Persistence: `ai.taiso.tiramisu.quota.{providerID}.{modelID}.{YYYY-MM-DD}`
in UserDefaults. Old keys (>3 days) get garbage-collected on app launch.

---

## 4. Provider catalog (v0.6 launch)

| Provider     | Capabilities                 | Cost model                                          | Auth            | Status   |
|--------------|------------------------------|-----------------------------------------------------|-----------------|----------|
| **Gemini**   | reimagine                    | `freeQuotaThenPaid(perDay: 500, paidEstimateUSD: 0.04)` (Nano Banana); `(perDay: 100, $0.12)` (Pro Image) | API key | NEW v0.6 |
| **Replicate**| inpaint, outpaint, reimagine | `payPerCall($0.03)` per FLUX-Fill call (avg)        | API key         | exists   |
| **LocalFlux**| inpaint, outpaint, reimagine | `alwaysFree`                                         | mflux install   | exists   |

Other providers waiting in the wings, scoped to v0.7+:

- **OpenAI** (GPT Image 2): reimagine, inpaint, outpaint. ~$0.006–$0.21/img.
- **Anthropic Claude**: doesn't generate images, but text-side prompt-helper for layer naming + prompt rewriting.
- **Stability** (SD 3.5, SDXL): img2img + inpaint, paid.
- **Black Forest Labs Direct** (FLUX cloud): paid alternative to Replicate's FLUX hosting.
- **Together / Fal**: aggregator clouds offering many models with one key.

Each new provider = one Swift file conforming to `AIImageProvider` +
one row in the settings pane. ~150 LOC each.

---

## 5. Reimagine Whole Image — UX spec

The first feature built on top of the new provider system. v0.6
headline alongside Auto-Layer and Smart Select 2.

**Trigger:** menu **AI → Reimagine Whole Image…**, hotkey `⌘⇧R`.

**Sheet UI:**

```
┌─ Reimagine ────────────────────────────────────────────┐
│                                                        │
│  ┌──────────────────┐  Provider: [Gemini ▾]            │
│  │                  │  Model:    [Nano Banana ▾]       │
│  │   [snapshot of   │  🟢 Free (487/500 used today)    │
│  │   current canvas]│                                  │
│  │                  │  Prompt:                         │
│  │                  │  ┌────────────────────────────┐  │
│  └──────────────────┘  │ make it cinematic with     │  │
│   1280 × 720           │ golden hour lighting and   │  │
│                        │ shallow depth of field     │  │
│                        └────────────────────────────┘  │
│                                                        │
│  Estimates based on published rates · check provider   │
│  dashboard for actual usage                            │
│                        [Cancel]    [Reimagine ⌘↵]      │
└────────────────────────────────────────────────────────┘
```

- **Snapshot preview** (left) shows the live canvas composite. Reduces
  "wait, what does the model see?" confusion.
- **Provider selector** scoped to capability `.reimagine`, defaults to
  the cheapest configured provider (Gemini > LocalFlux > Replicate).
- **Model selector** updates when provider changes.
- **Cost line** updates when provider/model changes — color-coded per
  the QuotaTracker spec (🟢🟡🔴💵💻❓). The single most important
  affordance for trust: the user sees BEFORE they click Reimagine
  whether this call is free or costs money.
- **Prompt** is a multi-line text editor, monospace, no placeholder
  beyond a quiet hint. Cmd+Return submits.
- **Disclaimer** under the prompt — quiet 11pt secondary text reminding
  the user the cost line is an estimate.

**During generation:**

- Sheet stays open with a progress indicator and a Cancel button.
- Estimated time per provider — Gemini Nano Banana ~2-4s, LocalFlux
  ~30-60s, Replicate ~10-30s.
- On error: in-sheet error message with actionable text ("Invalid
  Gemini API key — check Settings → AI Providers") + retry button.

**Result handling:**

- New `PXLayer(kind: .raster)` inserted above the active layer.
- Layer name = first 40 chars of the prompt + sequence number:
  `"cinematic golden hour shallow depth — 1"`.
- New layer becomes active.
- Sheet stays open for re-roll. Re-roll increments the sequence
  number: `"cinematic golden hour shallow depth — 2"`. Each roll is
  its own layer; user picks the winner, deletes the rest.
- Undo treats the whole roll as one operation (single checkpoint).

**Lineage:** for v0.6, the layer names + ordering ARE the lineage.
Tree visualization is v0.7.

---

## 6. Gemini integration — concrete

**File:** `Tiramisu/Rendering/GeminiImageService.swift` (new).

**Endpoint:**
```
POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
```
where `{model}` is `gemini-2.5-flash-image` (Nano Banana, default) or
`gemini-3-pro-image` (Nano Banana Pro). Header
`x-goog-api-key: <user's key>`. Content-Type `application/json`.

**Request body:**
```json
{
  "contents": [{
    "parts": [
      { "inline_data": { "mime_type": "image/png",
                         "data": "<base64-encoded canvas PNG>" } },
      { "text": "<user prompt>" }
    ]
  }],
  "generationConfig": {
    "responseModalities": ["IMAGE"]
  }
}
```

**Response (success):**
```json
{
  "candidates": [{
    "content": {
      "parts": [
        { "inline_data": { "mime_type": "image/png",
                           "data": "<base64 image>" } }
      ]
    },
    "finishReason": "STOP"
  }],
  "usageMetadata": {
    "promptTokenCount": 1290,
    "candidatesTokenCount": 1290,
    "totalTokenCount": 2580
  }
}
```

**Response (error):** Google returns a JSON body with `error.message`
and `error.status`. Map common cases to typed Swift errors:

| HTTP / status                  | Tiramisu error case          | UI message                                                 |
|--------------------------------|------------------------------|------------------------------------------------------------|
| 400 INVALID_ARGUMENT (bad image)| `.invalidInput`              | "Image rejected by Gemini — try a different canvas"        |
| 401 / 403 PERMISSION_DENIED    | `.invalidKey`                | "Invalid Gemini API key — check Settings → AI Providers"   |
| 429 RESOURCE_EXHAUSTED         | `.quotaExceeded`             | "Daily Gemini quota exhausted — try Local Flux or wait"    |
| `finishReason: "SAFETY"`       | `.contentPolicy`             | "Gemini blocked this prompt for content policy reasons"    |
| Network failure                | `.network(underlying)`       | "Network error reaching Gemini"                            |
| Other                          | `.unknown(detail)`           | underlying message                                         |

**Validation endpoint** (for the "Test" button in settings):
```
GET https://generativelanguage.googleapis.com/v1beta/models?key=<key>
```
Lists available models. Free, no quota. 200 = key valid.

**One-class shape:**
```swift
struct GeminiImageService {
    enum Model: String, CaseIterable {
        case flashImage = "gemini-2.5-flash-image"        // Nano Banana
        case proImage   = "gemini-3-pro-image"            // Nano Banana Pro
    }

    let apiKey: String
    let model: Model

    func reimagine(image: CGImage, prompt: String) async throws -> CGImage
    func validate() async -> Result<Void, GeminiError>
}
```

Async/await throughout. ~150 LOC including error mapping + base64
encode/decode of CGImage.

---

## 7. Privacy + audit

The "your image never leaves your Mac without you knowing" claim has
to be provable. v0.6 ships the audit log; UI surface lands v0.6.1.

**Audit log file:** `~/Library/Logs/Tiramisu/cloud-audit.log`. One line
per cloud call, append-only, never sent anywhere:

```
2026-05-11T18:42:33Z [Gemini gemini-2.5-flash-image] reimagine 1280x720 → 1280x720, 1.2s, 38KB→42KB, 1290+1290 tokens
2026-05-11T18:42:51Z [Replicate flux-fill-dev] inpaint 1280x720 → 1280x720, 14.3s, 41KB→39KB
```

Format intentionally human-readable, parseable later if needed.

**Audit log writer:** centralized in `CloudAudit.swift`
(`CloudAudit.log(provider:model:capability:input:output:duration:bytesIn:bytesOut:tokens:)`).
Every provider service calls it before returning successfully.

**Local Only mode (v0.6.1):** master toggle in Settings → Privacy that
flips a `store.cloudCallsEnabled = false` flag. Every cloud-capable
provider checks this flag and refuses with `.disabledByLocalOnlyMode`.
Status bar icon shows a closed-cloud glyph when active.

---

## 8. Future provider hooks

Each future provider is a new file conforming to `AIImageProvider` +
one row in the settings pane. The protocol is intentionally minimal so
adding one is mechanical:

| Provider            | Capabilities to add                         | Notes                                                                        |
|---------------------|---------------------------------------------|------------------------------------------------------------------------------|
| OpenAI GPT Image 2  | reimagine, inpaint, outpaint               | Pay per call. No free tier. Use as quality option.                          |
| Anthropic Claude    | (text only) prompt-helper, layer-naming    | Special — text capability, surfaced via Foundation-Models-style prompt helper. |
| Stability AI        | reimagine, inpaint, outpaint, upscale       | SD 3.5 / SDXL. Paid.                                                         |
| Black Forest Labs   | reimagine, inpaint, outpaint                | FLUX direct. Cheaper than Replicate's hosting.                              |
| Together AI         | many (aggregator)                           | One key, many models. Strong free tier on some models.                       |
| Fal.ai              | many (aggregator)                           | Faster cold-starts than Replicate.                                           |
| RMBG 2.0 (Bria)     | removeBackground                            | Local Core ML or hosted. v0.7 drop-in upgrade.                               |
| Real-ESRGAN local   | upscale                                     | Core ML. v0.7 new feature.                                                   |
| Qwen-Image-Layered  | decomposeLayers                             | Local Core ML. v0.6 headline (Auto-Layer).                                   |
| SAM 3 local         | segment                                     | Local Core ML. v0.6 (Smart Select 2).                                        |

---

## 9. Migration

**Trivial.** The existing `ai.taiso.tiramisu.replicate.apiKey`
UserDefaults value stays where it is and the new `ReplicateProvider`
reads from the same key. Users opening v0.6 see their existing key
already populated in the new Settings pane. No data loss, no prompt.

---

## 10. Open questions

Things to decide before code:

1. **Default provider when multiple are configured.** Today: hard-coded
   priority Gemini > LocalFlux > Replicate (cheapest first). Acceptable
   for v0.6, becomes a per-feature dropdown in v0.6.1. Confirm?

2. **Reimagine sheet — modal vs detached panel?** Sheet is simplest,
   blocks the canvas. Detached panel keeps canvas interactive but
   requires more layout work. Recommend sheet for v0.6.

3. **Re-roll behavior.** Each re-roll = new layer (proposed). Alternative:
   each re-roll replaces the current result and adds a "history" sibling.
   Recommend new layer per roll — simpler, matches user mental model.

4. **Cancel mid-generation.** Gemini's API doesn't support mid-flight
   cancellation; we just discard the response. Display "Cancelling…" so
   the user knows it'll finish in the background. OK?

5. **Audit log retention.** Append forever, or rotate? Recommend
   append-forever for v0.6 (file is tiny — ~150 bytes/line); add
   rotation only if it becomes a problem.

6. ~~**Free-quota tracking.**~~ **Decided 2026-05-11.** Local tracking
   via the new `QuotaTracker` actor + per-provider `costModel` declared
   in the protocol. Color-coded cost line in the Reimagine sheet (🟢🟡
   🔴💵💻❓). Disclaimer text makes clear it's an estimate, not
   authoritative — provider dashboards remain the source of truth. See
   §3 ("Cost-awareness via QuotaTracker").

---

## 11. Ship sequence

Total: ~1 day across two coding sessions.

**Phase 1 — Settings + Gemini + Reimagine** (~5 hours)

1. `Tiramisu/Rendering/AIProvider.swift` — protocol + `AIImageCapability` + `ProviderCostModel` enums + registry stub.
2. `Tiramisu/Rendering/QuotaTracker.swift` — actor, per-day call counter in UserDefaults, 3-day GC.
3. `Tiramisu/Rendering/GeminiProvider.swift` + `GeminiImageService.swift` — provider conformance + HTTP class. Records to `QuotaTracker` on success.
4. `Tiramisu/Rendering/ReplicateProvider.swift` + `LocalFluxProvider.swift` — wrap existing services with the protocol. No behavior change.
5. `Tiramisu/Rendering/CloudAudit.swift` — single-class audit log writer.
6. `Tiramisu/Views/AIProvidersSettings.swift` — Settings Scene pane. ProviderRow component, key fields, model dropdowns, Test buttons.
7. Wire `Settings { ... }` Scene in `TiramisuApp.swift`.
8. `Tiramisu/Tools/ReimagineService.swift` — orchestrator. Reads provider config, calls service, creates layer.
9. `Tiramisu/Views/ReimagineSheet.swift` — the prompt UI, including the color-coded cost line driven by provider.costModel + QuotaTracker.
10. Hook to AI menu (⌘⇧R) in `AppCommands.swift`.
11. Smoke test: paste Gemini key, drop in a photo, run Reimagine with prompt, confirm new layer + verify quota counter increments.

**Phase 2 — polish + tests** (~2 hours)

- Algorithmic test: GeminiImageService URL/body construction matches the documented endpoint format (snapshot test on serialized request, no actual API call).
- Test: ReimagineService creates a new layer above the active one with the correct name format.
- Manual test matrix: invalid key, expired key, quota exceeded, content policy block, network failure.
- Update `/docs/v0.6-roadmap.md` to reflect Reimagine v0 ships against Gemini first, FLUX/Replicate as fallback options.
- Commit + push.

**Out of scope for v0.6, queued for v0.6.1+:**

- Capability routing UI ("which provider serves Reimagine").
- Local Only master switch + status bar indicator.
- Audit log surfaced in Debug menu.
- Reimagine Selection (selection-scoped).
- Subject lock + style reference + depth lock (Reimagine Tier 2).
- OpenAI / Stability / Anthropic provider rows.

---

## Sources

- [Gemini API image generation docs](https://ai.google.dev/gemini-api/docs/image-generation)
- [Gemini API rate limits](https://ai.google.dev/gemini-api/docs/rate-limits)
- [Apple Settings Scene (SwiftUI)](https://developer.apple.com/documentation/swiftui/settings)
- [/docs/v0.6-roadmap.md](./v0.6-roadmap.md) — engineering plan this spec slots into
- [/docs/creator-workflows-2026.md](./creator-workflows-2026.md) — strategic thesis behind Reimagine
- [/internal/v0-6-creator-ai-2026.html](https://tiramisu.taiso.ai/internal/v0-6-creator-ai-2026.html) — intranet positioning page
