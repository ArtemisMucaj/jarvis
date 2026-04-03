#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/macOs/Jarvis/Jarvis/Resources"

echo "==> Building jarvis binary with PyInstaller..."

mkdir -p "$OUT_DIR"

cd "$REPO_ROOT"

uv run --with pyinstaller pyinstaller \
  --onefile \
  --name jarvis \
  --distpath "$OUT_DIR" \
  --workpath /tmp/jarvis-pyinstaller-build \
  --specpath /tmp/jarvis-pyinstaller-spec \
  --clean \
  jarvis.py

echo "==> Done. Binary at: $OUT_DIR/jarvis"
ls -lh "$OUT_DIR/jarvis"
