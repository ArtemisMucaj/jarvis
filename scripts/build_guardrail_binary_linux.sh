#!/usr/bin/env bash
set -euo pipefail

# Build the guardrail proxy (Rust) for Linux x86_64 into dist/, mirroring
# build_jarvis_binary_linux.sh.

command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo is not installed. See https://rustup.rs/"; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_DIR="$REPO_ROOT/rust"
OUT_DIR="$REPO_ROOT/dist"

[[ -f "$RUST_DIR/guardrail/Cargo.toml" ]] || { echo "ERROR: rust/guardrail/Cargo.toml not found at $RUST_DIR"; exit 1; }

echo "==> Building guardrail binary with cargo (release, Linux)..."

mkdir -p "$OUT_DIR"
cargo build --locked --release --manifest-path "$RUST_DIR/Cargo.toml" -p guardrail

cp "$RUST_DIR/target/release/guardrail" "$OUT_DIR/guardrail"

echo "==> Done. Binary at: $OUT_DIR/guardrail"
ls -lh "$OUT_DIR/guardrail"
