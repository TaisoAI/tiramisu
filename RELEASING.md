# Releasing Tiramisu

Tag-based releases. Local-built (GitHub-hosted runners don't have macOS 26
SDK yet). One command: `./scripts/release.sh v<X.Y.Z>`.

## Cut a release

```bash
# 1. Make sure main is green
./scripts/ai-check.sh --with-ui

# 2. Tag the release commit
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0

# 3. Build, sign, notarize, package, publish
./scripts/release.sh v0.1.0
```

That's the whole flow. The script:

1. Pre-flight checks (clean tree, on the tag, tools available, cert in keychain, notarytool profile present)
2. `xcodebuild archive` (Release config, macOS 26 SDK)
3. Export `Tiramisu.app` from the `.xcarchive`
4. Codesign with Developer ID + hardened runtime + timestamp
5. Notarize via `xcrun notarytool submit --wait`, then `stapler staple`
6. Build the DMG with `create-dmg` (branded volume, app-drop link)
7. `gh release create` and upload the DMG asset
8. rsync the DMG to `/var/www/tiramisu.hanley.world/download/Tiramisu-vX.Y.Z.dmg` and update the `Tiramisu.dmg` symlink so the homepage button always points at the latest signed build

End-to-end on an M1 Max: roughly 3-6 minutes (notarization is the slowest step).

## Skip flags

```bash
./scripts/release.sh v0.1.0 --no-sign         # unsigned (dev / internal)
./scripts/release.sh v0.1.0 --no-notarize     # signed but not stapled
./scripts/release.sh v0.1.0 --no-mirror       # don't push to Lightsail
./scripts/release.sh v0.1.0 --draft           # GitHub Release as draft
```

`--no-sign` automatically implies `--no-notarize` (notarization requires a
signed binary).

## One-time setup (do once, lasts forever)

### 1. Developer ID Application cert in your keychain

You already have this:
```
Developer ID Application: Hanley Tze Ho Leung (FG5Y9SD7U6)
```
Confirm with `security find-identity -v -p codesigning`.

### 2. Stored notarytool profile

Notarization needs an Apple ID + app-specific password. Store them once
in the keychain so the script can pull them non-interactively:

```bash
# Generate an app-specific password at https://appleid.apple.com → Sign-In Security
xcrun notarytool store-credentials "tiramisu-notary" \
  --apple-id "<your apple id email>" \
  --team-id "FG5Y9SD7U6" \
  --password "<app-specific password from appleid.apple.com>"
```

Verify: `xcrun notarytool history --keychain-profile tiramisu-notary` should
list past submissions (or empty list — both are fine).

### 3. create-dmg + xcodegen + gh CLI

```bash
brew install create-dmg xcodegen gh
gh auth login   # active account = hanley-tech
```

### 4. Lightsail SSH key

`~/.ssh/lightsail-hanley-world.pem` — backed up at
`~/Documents/lightsail-hanley-world-keys-backup/`.

## Where the DMG lands

| Channel | URL |
|---|---|
| **GitHub Releases** (canonical, version-pinned) | `https://github.com/hanley-tech/tiramisu/releases/tag/v0.1.0` |
| **Direct download** (homepage button) | `https://tiramisu.hanley.world/download/Tiramisu.dmg` (latest, symlink) |
| **Direct download** (version-pinned) | `https://tiramisu.hanley.world/download/Tiramisu-v0.1.0.dmg` |

The marketing site's deploy workflow excludes `download/` from its rsync,
so the DMG mirror is never wiped by a site deploy.

## Versioning

Use SemVer:

- **0.x.y** — pre-1.0, breaking changes allowed in minor bumps
- **bug fix** → bump `y` (`v0.1.1`)
- **feature** → bump `x` (`v0.2.0`)
- **breaking** → bump major once we're past 1.0

The version comes from the git tag — no need to edit `project.yml` or any
plist. The DMG file gets named after the tag.

## Hotfix on a shipped tag

When `v0.1.0` is in users' hands and you need to ship a fix without
dragging in everything that's landed on `main` since:

```bash
git checkout -b hotfix/v0.1.1 v0.1.0
# Make the fix, test, commit
./scripts/ai-check.sh
git commit -am "fix: <thing>"
git tag -a v0.1.1 -m "v0.1.1 — hotfix: <thing>"
git push origin hotfix/v0.1.1 v0.1.1
./scripts/release.sh v0.1.1

# Get the fix back into main
git checkout main
git cherry-pick <hotfix-commit-sha>
git push
```

The hotfix branch can be deleted afterwards; the tag is the permanent
reference.

## Release notes

If `CHANGELOG.md` exists at the repo root, the script uses its contents
as the GitHub Release body. Otherwise it falls back to
`gh release create --generate-notes` (auto-built from commits since the
previous tag).

For a polished launch release, write `CHANGELOG.md` with:

- What's new (user-facing)
- Bug fixes (user-facing)
- Breaking changes (if any)
- Known issues

Skip internal refactors and CI tweaks — link to the PR/commit list for those.

## What about CI?

`.github/workflows/release.yml` is parked. GitHub-hosted macOS runners are
still on macOS 15 — they can't build a macOS 26 deployment-target app
until GitHub ships a `macos-26` runner image. Once they do, the workflow
will resume firing on tag pushes; until then, all releases are local
via `./scripts/release.sh`.

## What lives where

- `scripts/release.sh` — the local-build pipeline (the one you actually run)
- `.github/workflows/release.yml` — parked CI version (will work post-macOS-26)
- `scripts/ai-check.sh` — pre-release green-tests check
- `build/release/` — gitignored output: `.xcarchive`, exported `.app`, DMG
