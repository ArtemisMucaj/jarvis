#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt `guardrail` proxy binary
# (https://github.com/ArtemisMucaj/guardrails) from GitHub Releases and drops
# it into the macOS app's Resources dir so Xcode can bundle it alongside the
# `jarvis` binary.
#
# Defaults to a pinned release, macOS arm64 asset. The version is pinned (rather
# than tracking `latest`) so the bundled binary is reproducible. Override the
# version or the specific macOS asset with:
#   GUARDRAILS_VERSION=latest  bash scripts/download_guardrails_binary.sh
#   GUARDRAILS_ASSET=guardrail-macos-x86_64  bash scripts/download_guardrails_binary.sh
#
# Only macOS assets are accepted: the binary is bundled into the macOS .app and
# launched by GuardrailsManager, so a non-macOS asset would ship a bundle that
# fails at runtime.
#
# Build order for the app mirrors the jarvis binary: fetch this first, then
# `xcodebuild` (see AGENTS.md → "macOS app").

REPO="ArtemisMucaj/guardrails"
GUARDRAILS_VERSION="${GUARDRAILS_VERSION:-v0.7.0}"
GUARDRAILS_ASSET="${GUARDRAILS_ASSET:-guardrail-macos-aarch64}"

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is not installed."; exit 1; }

# The bundled binary only ever runs inside the macOS app, so reject any asset
# that isn't a macOS build.
case "$GUARDRAILS_ASSET" in
  *macos*|*darwin*) ;;
  *)
    echo "ERROR: GUARDRAILS_ASSET='$GUARDRAILS_ASSET' is not a macOS asset."
    echo "       This binary is bundled into the macOS app; pick a guardrail-macos-* asset."
    exit 1
    ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/macOs/Jarvis/Jarvis/Resources"
mkdir -p "$OUT_DIR"

if [[ "$GUARDRAILS_VERSION" == "latest" ]]; then
  BASE="https://github.com/$REPO/releases/latest/download"
  echo "==> Using latest guardrails release"
else
  BASE="https://github.com/$REPO/releases/download/$GUARDRAILS_VERSION"
  echo "==> Using guardrails release $GUARDRAILS_VERSION"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading $GUARDRAILS_ASSET"
curl -fsSL "$BASE/$GUARDRAILS_ASSET" -o "$TMP/guardrail"

# Verify the SHA-256 checksum. This binary is bundled into the app, so fail
# closed: a missing manifest or missing entry aborts rather than shipping an
# unverified executable.
if ! curl -fsSL "$BASE/checksums-sha256.txt" -o "$TMP/checksums.txt"; then
  echo "ERROR: could not download checksums-sha256.txt for this release."
  echo "       Refusing to install an unverified binary."
  exit 1
fi

EXPECTED="$(awk -v a="$GUARDRAILS_ASSET" '$2 == a || $2 == "*"a {print $1}' "$TMP/checksums.txt" | head -n1)"
if [[ -z "$EXPECTED" ]]; then
  echo "ERROR: no checksum entry for $GUARDRAILS_ASSET in the release manifest."
  echo "       Refusing to install an unverified binary."
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "$TMP/guardrail" | awk '{print $1}')"
else
  ACTUAL="$(sha256sum "$TMP/guardrail" | awk '{print $1}')"
fi

if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "ERROR: checksum mismatch for $GUARDRAILS_ASSET"
  echo "  expected: $EXPECTED"
  echo "  actual:   $ACTUAL"
  exit 1
fi
echo "==> Checksum verified ($ACTUAL)"

install -m 0755 "$TMP/guardrail" "$OUT_DIR/guardrail"

echo "==> Done. Binary at: $OUT_DIR/guardrail"
ls -lh "$OUT_DIR/guardrail"
