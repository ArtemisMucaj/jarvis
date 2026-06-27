#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt `guardrail` proxy binary
# (https://github.com/ArtemisMucaj/guardrails) from GitHub Releases and drops
# it into the macOS app's Resources dir so Xcode can bundle it alongside the
# `jarvis` binary.
#
# Defaults to the latest release, macOS arm64 asset. Override with:
#   GUARDRAILS_VERSION=v0.6.0  bash scripts/download_guardrails_binary.sh
#   GUARDRAILS_ASSET=guardrail-linux-x86_64  bash scripts/download_guardrails_binary.sh
#
# Build order for the app mirrors the jarvis binary: fetch this first, then
# `xcodebuild` (see AGENTS.md → "macOS app").

REPO="ArtemisMucaj/guardrails"
GUARDRAILS_VERSION="${GUARDRAILS_VERSION:-latest}"
GUARDRAILS_ASSET="${GUARDRAILS_ASSET:-guardrail-macos-aarch64}"

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is not installed."; exit 1; }

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

# Verify the SHA-256 checksum if the release ships a manifest.
if curl -fsSL "$BASE/checksums-sha256.txt" -o "$TMP/checksums.txt" 2>/dev/null; then
  EXPECTED="$(awk -v a="$GUARDRAILS_ASSET" '$2 == a || $2 == "*"a {print $1}' "$TMP/checksums.txt" | head -n1)"
  if [[ -n "$EXPECTED" ]]; then
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
  else
    echo "==> No checksum entry for $GUARDRAILS_ASSET; skipping verification"
  fi
else
  echo "==> No checksums manifest in release; skipping verification"
fi

install -m 0755 "$TMP/guardrail" "$OUT_DIR/guardrail"

echo "==> Done. Binary at: $OUT_DIR/guardrail"
ls -lh "$OUT_DIR/guardrail"
