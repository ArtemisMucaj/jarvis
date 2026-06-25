# AGENTS.md

## What this is

Jarvis is an MCP proxy that aggregates multiple MCP servers behind 3 synthetic tools (`load_tools` → `search_tools` → `call_tool`). Python 3.11+, managed with **uv**.

## Layout

```
src/jarvis/        # the package (7 modules)
  __main__.py      # CLI entrypoint — arg parsing, server startup
  config.py        # DATA_DIR, presets, config loading, OAuth wiring
  proxy.py         # builds FastMCP proxy (stdio vs HTTP client selection)
  search.py        # JarvisSearchTransform (BM25 + load_tools/search_tools/call_tool descriptions)
  api.py           # REST management API (runs on port+1)
  probe.py         # server/tool discovery
  tui.py           # Textual TUIs (mcp manager, auth manager)
tests/unit/        # pure unit tests
tests/integration/ # API endpoint + TUI tests
scripts/           # PyInstaller + cargo build scripts
macOs/             # Xcode project for the menu bar app
rust/              # cargo workspace — guardrail proxy (sidecar, see below)
  guardrail/       # transparent OpenAI chat-completions proxy + tool-call guardrails
```

## Commands

```bash
# Install deps (no separate install step — uv handles it)
uv sync --group dev

# Run locally
uv run python -m jarvis --http 7070

# Run all tests
uv run --group dev pytest tests

# Run a single test file or test
uv run --group dev pytest tests/unit/test_config.py
uv run --group dev pytest tests/unit/test_config.py::test_name -k test_name

# Build standalone binary (macOS arm64)
bash scripts/build_jarvis_binary.sh

# Build standalone binary (Linux x86_64)
bash scripts/build_jarvis_binary_linux.sh

# Guardrail proxy (Rust sidecar) — test + build
cargo test --manifest-path rust/Cargo.toml
bash scripts/build_guardrail_binary.sh        # macOS → app Resources/
bash scripts/build_guardrail_binary_linux.sh  # Linux → dist/
```

## Testing quirks

- **pytest-asyncio `auto` mode** is on (`asyncio_mode = "auto"` in pyproject.toml). Do not add `@pytest.mark.asyncio` to async tests.
- **`conftest.py` sets `JARVIS_DATA_DIR` at import time** before any jarvis module is imported. This isolates tests from `~/.jarvis`. If you add a new conftest or rearrange imports, preserve this ordering — the module-level `DATA_DIR` and `token_storage` in `config.py` bind once on first import.
- Use the `data_dir` fixture for per-test isolation. It monkeypatches `DATA_DIR`, `PRESETS_PATH`, and `token_storage` across `config`, `api`, and `probe` modules.
- Use the `servers_json` fixture when you need a pre-populated `servers.json` in the isolated data dir.

## Architecture notes

- `config.py` resolves `DATA_DIR` and creates `token_storage` (DiskStore) **at module level**. The env var `JARVIS_DATA_DIR` overrides the default `~/.jarvis` — this is the only mechanism for test isolation.
- `proxy.py` chooses `StatefulProxyClient` (persistent subprocess) for stdio servers and `ProxyClient` (fresh connection) for HTTP/SSE. The stateful clients are pinned to `mcp._stateful_clients` to avoid GC.
- The hatchling build uses `packages = ["src/jarvis"]` — the wheel package is `jarvis`, not `jarvis_mcp`.
- `search.py` contains `JarvisSearchTransform`, applied in `build_mcp` — a subclass of `BM25SearchTransform` that exposes three always-visible synthetic tools instead of two:
  - `load_tools` — STEP 1. Returns a cheap overview of which backend servers are proxied and what each is for, sourced from the per-server `description` field in `servers.json` (via `config.get_server_descriptions`). The server-level analog of how skills always expose their one-line descriptions; lets an agent orient before searching.
  - `search_tools` / `call_tool` — STEPS 2 and 3, with rewritten descriptions that make the load → search → call workflow explicit and include DO/DON'T examples to prevent small models from pasting full task text into the search query.

## macOS app

The menu bar app (`macOs/Jarvis/`) is a Swift/Xcode project that embeds two
binaries: the PyInstaller `jarvis` binary and the Rust `guardrail` binary.
**Build order matters** — both binaries must exist in `Resources/` before Xcode
can bundle them:

```bash
# 1. Build both binaries into the Xcode Resources dir
bash scripts/build_jarvis_binary.sh      # → macOs/Jarvis/Jarvis/Resources/jarvis
bash scripts/build_guardrail_binary.sh   # → macOs/Jarvis/Jarvis/Resources/guardrail

# 2. Build the app
xcodebuild -project macOs/Jarvis/Jarvis.xcodeproj -scheme Jarvis -configuration Debug build
```

## Guardrail proxy (Rust sidecar)

`rust/guardrail/` is a transparent OpenAI chat-completions proxy in front of an
OpenAI-compatible backend (LM Studio), applying small-model tool-call guardrails
in the wire path. It is a **separate process at a different layer** from the MCP
proxy — jarvis sits on the tool-discovery (MCP) edge, guardrail on the inference
(OpenAI HTTP) edge — and they do not call each other at runtime. They co-ship as
one product: the menu bar app launches and supervises both. The guardrail loop
(rescue → validate → retry, synthetic `respond`, strip-to-text) is implemented
and on by default; each guardrail is individually toggleable
(`--rescue/--respond/--retry`), so the proxy degrades to a transparent
passthrough. Streaming and non-OpenAI wire formats remain deferred. See
`rust/guardrail/README.md`.

## CI

- Every push/PR: pytest + `cargo test` + binary builds (jarvis macOS arm64 &
  Linux x86_64; guardrail Linux x86_64; both embedded in the macOS app build).
- No lint or typecheck step in CI. Ruff cache exists locally but there is no enforced config.
- Releases trigger on `v*` tags and produce binaries + a macOS `.dmg`.
