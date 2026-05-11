# Privacy

Tiramisu does not collect telemetry, analytics, crash reports, or "anonymous usage data."

There is no analytics SDK linked into the app. There is no server we phone home to. The default install runs offline — it only touches the network when you explicitly use a cloud backend.

## What runs locally (by default — everything except the cloud Replicate backend)

- **Layered editing, masks, transforms, exports** — entirely on your Mac.
- **Background removal** — Apple's `VNGenerateForegroundInstanceMaskRequest`, runs on the Neural Engine. Never leaves the machine.
- **Local FLUX-Fill generative fill** — runs via [mflux](https://github.com/filipstrand/mflux) on Apple Silicon. The model weights download once from Hugging Face on first setup; after that, no network traffic.
- **Recents, file bookmarks, settings** — UserDefaults / your filesystem. Not synced.

## What touches the network (only when you opt in)

### 1. Cloud Replicate backend
If you pick **AI → Generative Fill Settings → Replicate** and enter an API key, your image (cropped to the fill region) is sent to [replicate.com](https://replicate.com) for inference. Their privacy policy applies. We don't proxy or cache anything.

### 2. Hugging Face download (one-time)
If you choose Local FLUX-Fill, the bootstrap script downloads the model weights (~24 GB) from [huggingface.co](https://huggingface.co) using your Hugging Face token. After the download, no further network calls.

### 3. Auto-update check (planned, opt-in, v0.2+)
When Sparkle auto-updates land, the app will check for new releases on a schedule. This is a single GET to a static `appcast.xml` on `tiramisu.taiso.ai` — no body, no telemetry, just "is there a newer version." Opt-out from **Settings → Updates**.

## What we'd never do

- Train a model on your images.
- Sell, share, or aggregate any user data.
- Add a "free with ads" tier later.
- Add a tracking pixel or analytics SDK without an explicit opt-in toggle, default-off.

## Reach us

Privacy questions: open an [issue](https://github.com/TaisoAI/tiramisu/issues/new) or email `privacy@taiso.ai`.

This is the canonical statement. If anything changes, we'll update this file and note it in the release notes.

_Last updated 2026-05-07._
