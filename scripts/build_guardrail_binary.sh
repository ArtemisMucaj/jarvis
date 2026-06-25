#!/usr/bin/env bash
set -euo pipefail

# Build the guardrail proxy (Rust) and place it next to the jarvis binary in the
# macOS app's Resources dir so the menu bar app can bundle and supervise both.
# Build order in the Xcode flow: this + build_jarvis_binary.sh must run before
# xcodebuild (see AGENTS.md "build order matters" — now two artifacts).

command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo is not installed. See https://rustup.rs/"; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_DIR="$REPO_ROOT/rust"
OUT_DIR="$REPO_ROOT/macOs/Jarvis/Jarvis/Resources"

[[ -f "$RUST_DIR/guardrail/Cargo.toml" ]] || { echo "ERROR: rust/guardrail/Cargo.toml not found at $RUST_DIR"; exit 1; }

echo "==> Building guardrail binary with cargo (release)..."

mkdir -p "$OUT_DIR"
cargo build --locked --release --manifest-path "$RUST_DIR/Cargo.toml" -p guardrail

cp "$RUST_DIR/target/release/guardrail" "$OUT_DIR/guardrail"

echo "==> Done. Binary at: $OUT_DIR/guardrail"
ls -lh "$OUT_DIR/guardrail"
