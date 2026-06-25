//! Guardrail proxy library — a thin OpenAI-compatible reverse proxy in front of
//! an OpenAI-compatible backend (LM Studio first).
//!
//! Requests without tools, and any streamed request, take the **verbatim
//! passthrough** path (M1): forwarded byte-for-byte, including the response
//! stream. Tool-enabled, non-streamed requests additionally take a **log-only
//! inspection** path (M3): the response is buffered and run through
//! [`decode`] + [`validate`] so we can confirm the backend's native `tool_calls`
//! are detected and well-formed — but the original body is still forwarded
//! unchanged. [`inspect_response`] is the seam where rescue (M4) and the retry
//! loop (M6) will hook in.
//!
//! Remaining guardrails land as separate modules gated behind config toggles.
//! [`build_app`] is the single entrypoint both the binary and the integration
//! tests use.
//!
//! [`decode`]: crate::decode
//! [`validate`]: crate::validate

pub mod decode;
pub mod model;
pub mod rescue;
pub mod validate;

use std::net::SocketAddr;

use axum::{
    body::Body,
    extract::{Request, State},
    http::{header::CONNECTION, HeaderMap, HeaderName, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::any,
    Router,
};
use clap::{ArgAction, Parser};
use serde_json::Value;
use tracing::{debug, error, info, info_span, warn, Instrument};

use crate::decode::{decode_response, ModelOutput};
use crate::model::ChatRequest;
use crate::validate::{validate, Validation};

/// Headers that are connection-specific and must not be forwarded across a
/// proxy hop (RFC 9110 §7.6.1). `host` is dropped so reqwest sets it for the
/// backend; `content-length`/`transfer-encoding` are dropped on the response
/// path because we re-stream the body and let the server framing layer decide.
const HOP_BY_HOP: &[&str] = &[
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
];

/// Upper bound on a request body we will buffer before forwarding. Chat-
/// completions payloads are small; this caps memory so a client cannot force the
/// proxy to read an unbounded body. Exceeding it yields `413 Payload Too Large`.
const MAX_REQUEST_BODY: usize = 32 * 1024 * 1024;

#[derive(Parser, Debug, Clone)]
#[command(
    name = "guardrail",
    about = "Transparent OpenAI chat-completions proxy (Jarvis sidecar)"
)]
pub struct Config {
    /// Address the proxy listens on.
    #[arg(long, env = "GUARDRAIL_LISTEN", default_value = "127.0.0.1:8080")]
    pub listen: SocketAddr,

    /// Base URL of the OpenAI-compatible backend (e.g. LM Studio).
    /// Forwarded verbatim; the `model` field is never rewritten.
    #[arg(
        long,
        env = "GUARDRAIL_BACKEND",
        default_value = "http://127.0.0.1:1234"
    )]
    pub backend: String,

    /// Timeout for establishing the TCP/TLS connection to the backend, in
    /// seconds. Does not bound the response — streams may run indefinitely.
    #[arg(long, env = "GUARDRAIL_CONNECT_TIMEOUT_SECS", default_value_t = 10)]
    pub connect_timeout_secs: u64,

    /// Maximum idle gap between read chunks of the backend response, in seconds.
    /// Resets on every chunk, so a steadily-streaming SSE response is never cut
    /// off; only a stalled backend trips it.
    #[arg(long, env = "GUARDRAIL_READ_TIMEOUT_SECS", default_value_t = 300)]
    pub read_timeout_secs: u64,

    /// Rescue malformed tool calls from model text. On by default; pass
    /// `--rescue false` (or `GUARDRAIL_RESCUE=false`) to disable.
    #[arg(long, env = "GUARDRAIL_RESCUE", default_value_t = true, action = ArgAction::Set)]
    pub rescue: bool,

    /// Inject the synthetic `respond` tool and unwrap it to text. On by default;
    /// `--respond false` disables.
    #[arg(long, env = "GUARDRAIL_RESPOND", default_value_t = true, action = ArgAction::Set)]
    pub respond: bool,

    /// Retry the backend with a corrective nudge when a tool call fails
    /// validation. On by default; `--retry false` disables.
    #[arg(long, env = "GUARDRAIL_RETRY", default_value_t = true, action = ArgAction::Set)]
    pub retry: bool,

    /// Maximum corrective retries before falling back to the model's last text.
    #[arg(long, env = "GUARDRAIL_MAX_RETRIES", default_value_t = 2)]
    pub max_retries: u32,
}

impl Config {
    /// Collect the per-guardrail toggles into the runtime [`Guardrails`] set.
    pub fn guardrails(&self) -> Guardrails {
        Guardrails {
            rescue: self.rescue,
            respond: self.respond,
            retry: self.retry,
            max_retries: self.max_retries,
        }
    }
}

/// Runtime on/off state for each guardrail, plus the retry budget. Every
/// guardrail is independently toggleable so the proxy can degrade to a
/// zero-overhead passthrough; all default on.
#[derive(Clone, Copy, Debug)]
pub struct Guardrails {
    pub rescue: bool,
    pub respond: bool,
    pub retry: bool,
    pub max_retries: u32,
}

impl Default for Guardrails {
    fn default() -> Self {
        Self {
            rescue: true,
            respond: true,
            retry: true,
            max_retries: 2,
        }
    }
}

impl Guardrails {
    /// Whether any guardrail is enabled. When false the tool-enabled path is a
    /// plain passthrough.
    pub fn any_active(&self) -> bool {
        self.rescue || self.respond || self.retry
    }
}

#[derive(Clone)]
pub struct AppState {
    pub client: reqwest::Client,
    /// Backend base URL with any trailing slash removed.
    pub backend: String,
    /// Which guardrails are active. Defaults to all-on via [`AppState::new`];
    /// override with [`AppState::with_guardrails`].
    pub guardrails: Guardrails,
}

impl AppState {
    pub fn new(client: reqwest::Client, backend: impl Into<String>) -> Self {
        Self {
            client,
            backend: backend.into().trim_end_matches('/').to_string(),
            guardrails: Guardrails::default(),
        }
    }

    /// Override the guardrail toggle set (builder style).
    pub fn with_guardrails(mut self, guardrails: Guardrails) -> Self {
        self.guardrails = guardrails;
        self
    }
}

/// Build the axum router. Everything is passthrough at this milestone. The two
/// endpoints we care about are routed explicitly (so intent is documented and
/// future per-route guardrail wiring has a home); a catch-all proxies anything
/// else the backend would otherwise serve so nothing 404s spuriously.
pub fn build_app(state: AppState) -> Router {
    Router::new()
        .route("/v1/chat/completions", any(proxy))
        .route("/v1/models", any(proxy))
        .fallback(any(proxy))
        .with_state(state)
}

/// Forward a request to the backend verbatim and stream the response back.
async fn proxy(State(state): State<AppState>, req: Request) -> Response {
    let method = req.method().clone();
    let path_and_query = req
        .uri()
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or("/")
        .to_string();
    let target = format!("{}{}", state.backend, path_and_query);

    let span = info_span!("proxy", %method, path = %path_and_query);
    async move {
        debug!(target = %target, "forwarding to backend");

        let (parts, body) = req.into_parts();

        // Buffer the request body. Chat-completions requests are small; this
        // keeps the hop simple and is the same buffering the guardrail loop will
        // need later anyway (it must see the whole response before validating).
        let body_bytes = match axum::body::to_bytes(body, MAX_REQUEST_BODY).await {
            Ok(b) => b,
            Err(e) => {
                // to_bytes fails when the body exceeds the cap or the stream
                // errors; both are client-side, surfaced as 413 to be explicit
                // about the bound.
                error!(error = %e, "failed to read request body (or exceeded cap)");
                return (StatusCode::PAYLOAD_TOO_LARGE, "request body too large").into_response();
            }
        };

        // Best-effort parse so we can inspect tool-enabled, non-streamed
        // responses (M3, log-only). Anything that does not parse, has no tools,
        // or is streamed stays on the verbatim streaming path untouched.
        let inspect = serde_json::from_slice::<ChatRequest>(&body_bytes)
            .ok()
            .filter(|r| r.has_tools() && !r.stream());

        let backend_req = state
            .client
            .request(parts.method, &target)
            .headers(forward_headers(&parts.headers))
            .body(body_bytes);

        match backend_req.send().await {
            Ok(resp) => match inspect {
                Some(request) => {
                    relay_buffered_with_inspection(resp, &request, state.guardrails).await
                }
                None => relay_response(resp),
            },
            Err(e) => {
                error!(error = %e, target = %target, "backend request failed");
                (
                    StatusCode::BAD_GATEWAY,
                    format!("backend request failed: {e}"),
                )
                    .into_response()
            }
        }
    }
    .instrument(span)
    .await
}

/// Copy client → backend headers, dropping hop-by-hop headers (both the static
/// set and any header named in this message's own `Connection` header).
fn forward_headers(src: &HeaderMap) -> HeaderMap {
    let connection = connection_header_names(src);
    let mut out = HeaderMap::with_capacity(src.len());
    for (name, value) in src.iter() {
        if should_strip_header(name, &connection) {
            continue;
        }
        out.append(name.clone(), value.clone());
    }
    out
}

/// Stream the backend response back to the client, preserving status and
/// headers. The body is streamed (not buffered) so SSE / chunked responses pass
/// through with no added latency.
fn relay_response(resp: reqwest::Response) -> Response {
    let status =
        StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);

    let connection = connection_header_names(resp.headers());
    let mut headers = HeaderMap::with_capacity(resp.headers().len());
    for (name, value) in resp.headers().iter() {
        // Drop hop-by-hop (static + Connection-named) and length/framing headers:
        // we re-stream the body and let the HTTP server set framing.
        // content-length on a streamed body would risk a mismatch.
        if should_strip_header(name, &connection) || name == "content-length" {
            continue;
        }
        if let (Ok(n), Ok(v)) = (
            HeaderName::from_bytes(name.as_ref()),
            HeaderValue::from_bytes(value.as_ref()),
        ) {
            headers.append(n, v);
        }
    }

    let body = Body::from_stream(resp.bytes_stream());

    let mut response = Response::new(body);
    *response.status_mut() = status;
    *response.headers_mut() = headers;
    response
}

/// Buffer a tool-enabled, non-streamed response, run log-only guardrail
/// inspection over it (M3), then forward the original bytes unchanged. Decoding
/// is best-effort: a non-JSON or undecodable body is forwarded unverified rather
/// than failing the request.
async fn relay_buffered_with_inspection(
    resp: reqwest::Response,
    request: &ChatRequest,
    guardrails: Guardrails,
) -> Response {
    let status =
        StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);

    let connection = connection_header_names(resp.headers());
    let mut headers = HeaderMap::with_capacity(resp.headers().len());
    for (name, value) in resp.headers().iter() {
        if should_strip_header(name, &connection) || name == "content-length" {
            continue;
        }
        if let (Ok(n), Ok(v)) = (
            HeaderName::from_bytes(name.as_ref()),
            HeaderValue::from_bytes(value.as_ref()),
        ) {
            headers.append(n, v);
        }
    }

    let bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(e) => {
            error!(error = %e, "failed to read backend response body");
            return (StatusCode::BAD_GATEWAY, "failed to read backend response").into_response();
        }
    };

    match serde_json::from_slice::<Value>(&bytes) {
        Ok(body) => inspect_response(&body, request, guardrails),
        Err(e) => warn!(error = %e, "tool-enabled response was not JSON; forwarding unverified"),
    }

    let mut response = Response::new(Body::from(bytes));
    *response.status_mut() = status;
    *response.headers_mut() = headers;
    response
}

/// Decode and validate the backend response, logging the outcome. This is the
/// log-only seam where rescue (M4) and the retry loop (M6) will hook in; for now
/// it only observes and never alters the response.
fn inspect_response(body: &Value, request: &ChatRequest, guardrails: Guardrails) {
    match decode_response(body) {
        ModelOutput::ToolCalls(calls) => {
            let names: Vec<&str> = calls.iter().map(|c| c.name.as_str()).collect();
            info!(count = calls.len(), tool_calls = ?names, "decoded native tool_calls");
            match validate(&calls, &request.tool_names()) {
                Validation::Valid => info!("tool calls valid"),
                Validation::NeedsRetry(nudge) => {
                    warn!(%nudge, "tool calls invalid (log-only; retry lands in a later milestone)")
                }
            }
        }
        // Rescue is gated by its toggle; when off, malformed text is left as-is.
        ModelOutput::Text(text) if guardrails.rescue => match rescue::rescue(&text) {
            Some((parser, calls)) => {
                let names: Vec<&str> = calls.iter().map(|c| c.name.as_str()).collect();
                info!(
                    parser,
                    count = calls.len(),
                    tool_calls = ?names,
                    "rescued tool calls from text (log-only; re-emit lands in a later milestone)"
                );
                match validate(&calls, &request.tool_names()) {
                    Validation::Valid => info!("rescued tool calls valid"),
                    Validation::NeedsRetry(nudge) => {
                        warn!(%nudge, "rescued tool calls invalid")
                    }
                }
            }
            None => debug!(
                len = text.len(),
                "model returned text, no tool calls (native or rescuable)"
            ),
        },
        ModelOutput::Text(_) => debug!("model returned text; rescue disabled"),
    }
}

fn is_hop_by_hop(name: &HeaderName) -> bool {
    HOP_BY_HOP
        .iter()
        .any(|h| name.as_str().eq_ignore_ascii_case(h))
}

/// The header names listed in a message's `Connection` header. Per RFC 9110
/// §7.6.1 these are hop-by-hop for *this* message and must not be forwarded
/// (e.g. `Connection: x-internal` makes `x-internal` hop-specific).
fn connection_header_names(headers: &HeaderMap) -> Vec<HeaderName> {
    headers
        .get_all(CONNECTION)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .filter_map(|name| HeaderName::from_bytes(name.trim().as_bytes()).ok())
        .collect()
}

/// Whether a header should be dropped on a proxy hop: either in the static
/// hop-by-hop set or named by this message's `Connection` header.
fn should_strip_header(name: &HeaderName, connection: &[HeaderName]) -> bool {
    is_hop_by_hop(name) || connection.iter().any(|h| h == name)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn header_map(pairs: &[(&str, &str)]) -> HeaderMap {
        let mut m = HeaderMap::new();
        for (k, v) in pairs {
            m.append(
                HeaderName::from_bytes(k.as_bytes()).unwrap(),
                HeaderValue::from_str(v).unwrap(),
            );
        }
        m
    }

    #[test]
    fn forward_headers_strips_static_hop_by_hop() {
        let src = header_map(&[
            ("host", "example.com"),
            ("connection", "keep-alive"),
            ("authorization", "Bearer t"),
            ("content-type", "application/json"),
        ]);
        let out = forward_headers(&src);
        assert!(out.get("host").is_none());
        assert!(out.get("connection").is_none());
        // Non-hop headers survive.
        assert_eq!(out.get("authorization").unwrap(), "Bearer t");
        assert_eq!(out.get("content-type").unwrap(), "application/json");
    }

    #[test]
    fn forward_headers_strips_connection_named_headers() {
        // `Connection: x-internal, x-trace` marks those headers hop-by-hop.
        let src = header_map(&[
            ("connection", "x-internal, x-trace"),
            ("x-internal", "secret"),
            ("x-trace", "abc"),
            ("x-keep", "kept"),
        ]);
        let out = forward_headers(&src);
        assert!(out.get("x-internal").is_none());
        assert!(out.get("x-trace").is_none());
        assert_eq!(out.get("x-keep").unwrap(), "kept");
    }

    #[test]
    fn connection_token_matching_is_case_insensitive() {
        let headers = header_map(&[("connection", "X-Internal")]);
        let names = connection_header_names(&headers);
        let lower = HeaderName::from_static("x-internal");
        assert!(should_strip_header(&lower, &names));
    }
}
