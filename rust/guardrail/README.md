# guardrail

A transparent **OpenAI chat-completions proxy** that sits in front of an
OpenAI-compatible backend (LM Studio first) and applies small-model tool-call
reliability guardrails in the wire path. Ships as a Jarvis sidecar: a single
static binary the menu bar app launches and supervises alongside the jarvis MCP
proxy.

## Where it fits

Jarvis and guardrail operate at two different edges of the same agent and do not
call each other at runtime:

```
agent harness ──(MCP)──────────► jarvis ──(MCP)──► backend MCP servers
agent harness ──(OpenAI HTTP)──► guardrail ──(HTTP)──► LM Studio
```

Jarvis shrinks the tool surface the model sees to 3 synthetic tools; guardrail
makes the calls to those tools reliable on small models. Complementary, not
coupled.

## Status: Milestone 1 — transparent passthrough

Right now the proxy **only** forwards requests and responses verbatim, including
streaming. Behaviour through the proxy is byte-for-byte identical to talking to
the backend directly. This is the failure-isolation milestone: ship and verify
it before any guardrail logic exists, so "it didn't work" is never the
transport's fault. The `model` field is forwarded verbatim and never rewritten.

Later milestones (each toggle-off-able so the proxy can degrade to a zero-overhead
passthrough):

2. Typed+passthrough serde model — round-trip fidelity.
3. Validation + canonical re-emit (log-only).
4. Rescue parsing for the target model's format(s).
5. Synthetic `respond` tool + strip-to-text.
6. Retry loop + ErrorTracker with fallback-to-last-text.
7. Observability + per-guardrail config toggles.

## Run

```bash
cargo run -p guardrail -- --listen 127.0.0.1:8080 --backend http://127.0.0.1:1234
```

Config is also available via env: `GUARDRAIL_LISTEN`, `GUARDRAIL_BACKEND`,
`GUARDRAIL_TIMEOUT_SECS`. Logging via `RUST_LOG` (default `guardrail=info,warn`).

Point your OpenAI-compatible client's base URL at `http://127.0.0.1:8080/v1`.

## Test

```bash
cargo test          # from the rust/ workspace root
```

`tests/passthrough.rs` stands up a wiremock backend and asserts status, headers,
request body, and a streamed SSE body all round-trip unchanged — the Milestone 1
acceptance suite.

## Build a release binary

```bash
bash scripts/build_guardrail_binary.sh        # macOS → app Resources/
bash scripts/build_guardrail_binary_linux.sh  # Linux → dist/
```
