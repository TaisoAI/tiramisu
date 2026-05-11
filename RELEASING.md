# Releasing Tiramisu

Tag-based releases, local-built (GitHub Actions runners don't have macOS 26
SDK yet). One command for the build itself: `./scripts/release.sh v<X.Y.Z>`.
The full *ship-a-version* flow — pre-flight, version bump, build, site
updates — is the procedure below.

---

## TL;DR — ship a version

```bash
# 1. Pre-flight: green tests on a clean tree
./scripts/ai-check.sh

# 2. Bump the version in project.yml + regenerate
#    (CFBundleShortVersionString is the user-facing version,
#     CFBundleVersion is the integer build number — increment both)
$EDITOR project.yml
xcodegen generate
git add project.yml Tiramisu/Resources/Info.plist
git commit -m "vX.Y.Z: bump version"

# 3. Merge feature branch → main (if applicable), push
git checkout main
git merge --no-ff <branch> -m "Merge <branch> — vX.Y.Z release"
git push origin main

# 4. Tag and push the tag
git tag -a v0.2.0 -m "v0.2.0 — short summary"
git push origin v0.2.0

# 5. Build, sign, notarize, package, publish
./scripts/release.sh v0.2.0

# 6. Update the marketing site — roadmap + releases + visual snapshots
cd ../tiramisu_www
$EDITOR roadmap.html         # mark items shipped, bump shipped counter
$EDITOR releases.html        # add a new <div class="release latest"> block at the top
                             # (and remove the .latest class from the previous one)
./scripts/sync-snapshots.sh  # mirror passing test goldens to tests/snapshots/
                             # (LFS-tracked — doesn't bloat git history)
git add -A
git commit -m "Site: vX.Y.Z roadmap + release notes + snapshots"
git push origin main         # rsync→Lightsail picks it up

# Done. tiramisu.taiso.ai/download now serves the new DMG.
```

---

## Detailed steps

### 1. Pre-flight tests

`./scripts/ai-check.sh` runs `xcodegen generate` → `xcodebuild build` →
`xcodebuild test` → writes `build/test-report.html`. Fail-fast on any
breakage. Add `--with-ui` to include the slower UI test pass.

If you've added new features, add light tests for them under
`TiramisuTests/` before bumping the version. Examples from v0.2.0:
`LayerArrangeTextTests.swift`, `AdjustPresetTests.swift` — each ~150 LOC,
cover the public surface of the new code without snapshot churn.

### 1b. Manual smoke test (don't skip)

**Snapshot tests pin pipeline behavior on a specific fixture — they
don't prove the pipeline is right in all cases.** Two bugs slipped
through the v0.2.1 release because the test fixture happened to fill
the canvas, masking layer-alpha bleed bugs that surfaced immediately
on a smaller smart-object placement.

Before tagging, do this 30-second manual pass:

1. Build Debug (`xcodebuild build`) so the post-build hook installs to
   `~/Applications/Tiramisu.app`
2. Open the app, place an image as a smart object on a 1280×720+ canvas
   *where the image clearly does NOT fill the canvas* (transparent
   borders matter for catching alpha-related bugs)
3. Touch every new feature you added: drag each new slider end-to-end,
   click each new button, toggle each new option
4. Specifically verify:
   - Per-layer effects stay within the layer's content, not the canvas
   - Bounding boxes / handles track when the layer moves
   - Backward-compat: open an old `.tiramisu` file from a previous
     version and confirm it loads without errors
5. Only after this passes, bump the version + tag + release

### 2. Version bump

Edit `project.yml`:

```yaml
CFBundleShortVersionString: "0.2.0"   # bump per semver
CFBundleVersion: "3"                  # monotonically increasing integer
```

Run `xcodegen generate` to regenerate the Xcode project + propagate the
version into `Info.plist`. Commit both files together.

**Versioning judgment:** UX overhauls, new feature surfaces, or anything
that changes how users *interact* with the app deserves a minor bump
(0.1.x → 0.2.0). Bug fixes, copy tweaks, single-file polish stay on
patch (0.2.0 → 0.2.1).

### 3. Merge + tag

If shipping from a feature branch, merge with `--no-ff` so the merge
commit captures the release boundary. Then tag the merge commit with
the same version.

```bash
git tag -a v0.2.0 -m "v0.2.0 — inspector redesign + Adjust presets + …"
git push origin v0.2.0
```

The release script enforces that the tag exists on the current HEAD.

### 4. The release script

`./scripts/release.sh v0.2.0` does:

1. Pre-flight (clean tree, tag exists, tools available, cert in
   keychain, `tiramisu-notary` notarytool profile present)
2. `xcodebuild archive` (Release config, macOS 26 SDK)
3. Export `Tiramisu.app` from the `.xcarchive`
4. Codesign the app (Developer ID + hardened runtime + timestamp)
5. Notarize + staple the app (silent first launch even if extracted
   from the DMG)
6. Build the DMG with `create-dmg` (branded volume, app-drop link)
7. Codesign the DMG (notarization requires a signed artifact)
8. Notarize + staple the DMG (silent first mount)
9. `gh release create` and upload `Tiramisu.dmg` (always-latest URL
   serves it without per-release config)

Notarization runs in ~1–3 minutes; the script polls until accepted.

### 5. Marketing-site roadmap update

`tiramisu_www/roadmap.html` is the canonical "what shipped" checklist —
public-facing, links from the homepage. After every release:

1. Find each newly-shipped item in the relevant section
   (Adjustments, Effects, etc.)
2. Change `<li class="planned">` → `<li class="shipped">` and swap the
   `☐` glyph for `✓`
3. Tag the entry with a dim version suffix:
   `<span style="opacity:0.6;font-size:0.85em">· v0.2</span>`
4. Update the section's `<p class="group-stats">N shipped · M planned</p>`
5. Update the top counter
   (`<div class="summary-cell shipped"><div class="n">…</div></div>`)

### 5b. Visual snapshot gallery (quality.html)

`tiramisu_www/quality.html` displays every passing snapshot golden as a
live gallery — proof of pipeline stability, doubles as marketing.
Snapshots are LFS-tracked under `tiramisu_www/tests/snapshots/`; the
sync script mirrors them from the app repo's `__Snapshots__` dir.

```bash
./scripts/sync-snapshots.sh   # in tiramisu_www
```

The script writes `tests/snapshots/index.json` with the file list +
generation timestamp + source git commit. `quality.html` fetches that
manifest at runtime and renders the grid, grouped by test class. No
manual HTML edit needed per release — adding new snapshot tests
automatically populates the page after the next sync.

### 5c. Release notes page

`tiramisu_www/releases.html` tells the *story* of each version (the
roadmap shows current state — this shows how we got here). After every
release:

1. Add a new `<div class="release latest reveal">` block at the **top**
   of `<section class="releases">`
2. Remove the `.latest` class from the previous block (only one release
   carries the green "Latest" dot)
3. Fill in `<h2>vX.Y.Z</h2>` + date + a one-line tagline
4. Group bullets under `<h3>` labels: `New`, `Fixed`, `Under the hood`
   (skip the empty ones)
5. Add the GitHub-release + DMG links in the `release-footer`
6. Commit + push. The Lightsail deployment runs on push.

### 6. Distribution

Distribution is GitHub Releases only. The branded URL
`tiramisu.taiso.ai/download` is an nginx 302 to
`github.com/TaisoAI/tiramisu/releases/latest/download/Tiramisu.dmg`,
so a new release auto-promotes — no DNS or homepage edits required.

---

## What this procedure does *not* cover yet

- **Sparkle in-app auto-updates** — deferred to v0.3+. The `appcast.xml`
  feed and signing key aren't set up; users have to download the new
  DMG manually for now.
- **Homebrew Cask** — submission to homebrew/cask is a one-time setup
  for the formula, then auto-updates from GitHub Releases. Worth doing
  before a public-launch tweet.
- **Internal site (`tiramisu_www/internal/`)** — strategic docs, not
  per-release. Update when *strategy* shifts, not when *features* ship.
- **Newsletter announcement** — Listmonk on `lists.hanley.world` is
  pending separate setup; the homepage signup form is HTML-commented
  until the LIST_UUID is populated.

---

## Manual one-time setup (already done as of v0.1)

These don't need to run per release, but the scripts assume they
exist:

- `xcrun notarytool store-credentials "tiramisu-notary"` with an
  app-specific password from appleid.apple.com
- `Developer ID Application: Hanley Tze Ho Leung (FG5Y9SD7U6)`
  certificate in the login keychain
- `gh` CLI signed in as `hanley-taiso` (TaisoAI org member)
- `brew install xcodegen create-dmg` for the build tools
