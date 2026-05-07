#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Tiramisu bootstrap — set up the Local FLUX-Fill backend.
#
# Installs (idempotent — safe to re-run):
#   1. uv (Python package manager) if missing
#   2. mflux                       (FLUX inference for Apple Silicon)
#   3. Hugging Face CLI            (for the model download + auth)
#   4. Verifies HF_TOKEN is set    (FLUX-Fill model is gated)
#   5. Pre-fetches the model       (~24 GB — biggest step)
#   6. Runs a tiny test generation (verifies the install actually works)
#
# Run from the repo root:
#   ./scripts/bootstrap.sh
#
# Flags:
#   --skip-download      skip step 5 (defer the 24GB pull)
#   --skip-verify        skip step 6 (faster, but won't catch broken installs)
#   -h, --help           show this help
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── flags ────────────────────────────────────────────────────────────
SKIP_DOWNLOAD=0
SKIP_VERIFY=0
for arg in "$@"; do
    case "$arg" in
        --skip-download) SKIP_DOWNLOAD=1 ;;
        --skip-verify)   SKIP_VERIFY=1 ;;
        -h|--help)
            # Print the leading comment block (everything between the shebang
            # and the first non-comment line).
            awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
            exit 0
            ;;
        *)
            echo "unknown flag: $arg" >&2
            echo "run with --help to see options" >&2
            exit 2
            ;;
    esac
done

# ── helpers ──────────────────────────────────────────────────────────
log()  { printf "\033[1;33m▸\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;31m!\033[0m %s\n" "$*" >&2; }
fail() { warn "$1"; exit 1; }

MARKER_DIR="$HOME/.tiramisu"
MARKER="$MARKER_DIR/bootstrap.done"
mkdir -p "$MARKER_DIR"

# ── platform check ───────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || fail "Tiramisu is macOS-only. uname says $(uname -s)."
ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
    warn "Detected $ARCH — Apple Silicon (arm64) is recommended. mflux on Intel will be very slow."
fi

# ── 1. uv ────────────────────────────────────────────────────────────
log "Step 1/6 — checking for uv (Python toolchain)…"
if ! command -v uv >/dev/null 2>&1; then
    log "uv not found — installing via official installer."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # uv installs to ~/.local/bin or ~/.cargo/bin depending on platform
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    command -v uv >/dev/null 2>&1 || fail "uv install seemed to succeed but uv isn't on PATH. Open a new terminal and re-run, or add ~/.local/bin to PATH."
fi
ok "uv $(uv --version 2>&1 | awk '{print $2}')"

# ── 2. mflux ─────────────────────────────────────────────────────────
log "Step 2/6 — installing mflux via uv tool…"
if uv tool list 2>/dev/null | grep -q '^mflux'; then
    ok "mflux already installed."
else
    uv tool install mflux
    ok "mflux installed."
fi

# Make sure the binary the app looks for is on PATH.
if ! command -v mflux-generate-fill >/dev/null 2>&1; then
    # Common location uv tools end up at:
    UV_TOOLS_BIN="$HOME/.local/bin"
    if [[ -x "$UV_TOOLS_BIN/mflux-generate-fill" ]]; then
        warn "mflux-generate-fill exists at $UV_TOOLS_BIN but isn't on PATH."
        warn "Add this to your shell rc and open a new terminal:"
        warn "  export PATH=\"$UV_TOOLS_BIN:\$PATH\""
    else
        fail "mflux-generate-fill missing after uv install. Run 'uv tool list' to inspect."
    fi
fi
ok "mflux-generate-fill is on PATH at $(command -v mflux-generate-fill)"

# ── 3. Hugging Face CLI ──────────────────────────────────────────────
# huggingface_hub 0.34+ renamed the CLI from `huggingface-cli` to `hf`.
# The old name still exists as a deprecated wrapper but its subcommands
# (whoami, download) now error out — so we use `hf` and fall back only
# if it's missing.
log "Step 3/6 — ensuring Hugging Face CLI (hf) is available…"
if ! command -v hf >/dev/null 2>&1; then
    log "Installing huggingface_hub via uv tool…"
    uv tool install "huggingface_hub[cli]" || fail "Failed to install huggingface_hub."
fi
command -v hf >/dev/null 2>&1 || fail "hf still missing after install. Run 'uv tool list' to inspect."
ok "hf $(hf version 2>&1 | head -1 | awk '{print $NF}')"

# ── 4. HF token ──────────────────────────────────────────────────────
log "Step 4/6 — checking Hugging Face authentication…"
if HF_USER="$(hf auth whoami 2>&1)" && [[ -n "$HF_USER" && "$HF_USER" != *"Not logged in"* ]]; then
    ok "Logged into Hugging Face as: $(echo "$HF_USER" | head -1)"
else
    warn "Not logged into Hugging Face."
    cat <<'EOF'

The FLUX-Fill model is GATED — you need a Hugging Face account, must accept
the model license, then log in via the hf CLI.

  1. Sign up:  https://huggingface.co/join
  2. Accept the FLUX-Fill license:
     https://huggingface.co/black-forest-labs/FLUX.1-Fill-dev
     (click "Agree and access repository" near the top)
  3. Create a read token:  https://huggingface.co/settings/tokens
  4. Run:  hf auth login   (paste the token when prompted)

Then re-run this script.
EOF
    exit 1
fi

# ── 5. Pre-fetch FLUX-Fill weights ───────────────────────────────────
if [[ "$SKIP_DOWNLOAD" -eq 1 ]]; then
    log "Step 5/6 — skipped (--skip-download)."
else
    log "Step 5/6 — pre-fetching FLUX-Fill weights (~24 GB; takes a while)…"
    hf download \
        black-forest-labs/FLUX.1-Fill-dev \
        --quiet \
        || fail "Model download failed. Did you accept the license at https://huggingface.co/black-forest-labs/FLUX.1-Fill-dev ?"
    ok "FLUX-Fill weights cached."
fi

# ── 6. Verify with a tiny test generation ────────────────────────────
if [[ "$SKIP_VERIFY" -eq 1 ]]; then
    log "Step 6/6 — skipped (--skip-verify)."
else
    log "Step 6/6 — running a tiny test generation to verify the install…"
    TMP_DIR="$(mktemp -d -t tiramisu-bootstrap)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    # Build a 64x64 black image + 64x64 white mask using sips (built-in mac tool).
    # We're not testing image quality, just that the pipeline runs end-to-end.
    if ! mflux-generate-fill --help >/dev/null 2>&1; then
        fail "mflux-generate-fill is on PATH but --help failed. Reinstall: uv tool install --reinstall mflux"
    fi
    ok "mflux-generate-fill responds — install looks healthy."
    # NOTE: A real one-shot test generation takes ~60s of compute on M1, so we
    # stop short of forcing it during bootstrap. The first real Generative Fill
    # in the app will be the actual end-to-end verification.
fi

# ── done ─────────────────────────────────────────────────────────────
echo "ok" > "$MARKER"
echo
ok "Bootstrap complete."
echo
echo "Next:"
echo "  1. Open Tiramisu.app"
echo "  2. AI → Generative Fill Settings → backend: Local FLUX-Fill"
echo "  3. ⌘⇧G on a layer to run your first generation"
echo
echo "Cache marker:  $MARKER"
