//! Guardrail proxy library — Milestone 1: transparent passthrough.
//!
//! A thin OpenAI-compatible reverse proxy in front of an OpenAI-compatible
//! backend (LM Studio first). At this milestone it does **nothing** but forward
//! requests and responses verbatim — including streaming — so that behaviour
//! through the proxy is byte-for-byte identical to talking to the backend
//! directly. This is the failure-isolation milestone: ship and verify it before
//! any guardrail logic exists, so that "it didn't work" can never be blamed on
//! the transport.
//!
//! Guardrails (rescue / validate / retry / synthetic `respond`) land in later
//! milestones as separate modules gated behind config toggles; until then every
//! path is pure passthrough. [`build_app`] is the single entrypoint both the
//! binary and the integration tests use.

use std::net::SocketAddr;

use axum::{
    body::Body,
    extract::{Request, State},
    http::{HeaderMap, HeaderName, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::any,
    Router,
};
use clap::Parser;
use tracing::{debug, error, info_span, Instrument};

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

    /// Per-request timeout to the backend, in seconds.
    #[arg(long, env = "GUARDRAIL_TIMEOUT_SECS", default_value_t = 600)]
    pub timeout_secs: u64,
}

#[derive(Clone)]
pub struct AppState {
    pub client: reqwest::Client,
    /// Backend base URL with any trailing slash removed.
    pub backend: String,
}

impl AppState {
    pub fn new(client: reqwest::Client, backend: impl Into<String>) -> Self {
        Self {
            client,
            backend: backend.into().trim_end_matches('/').to_string(),
        }
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
        let body_bytes = match axum::body::to_bytes(body, usize::MAX).await {
            Ok(b) => b,
            Err(e) => {
                error!(error = %e, "failed to read request body");
                return (StatusCode::BAD_REQUEST, "failed to read request body").into_response();
            }
        };

        let backend_req = state
            .client
            .request(parts.method, &target)
            .headers(forward_headers(&parts.headers))
            .body(body_bytes);

        match backend_req.send().await {
            Ok(resp) => relay_response(resp),
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

/// Copy client → backend headers, dropping hop-by-hop headers.
fn forward_headers(src: &HeaderMap) -> HeaderMap {
    let mut out = HeaderMap::with_capacity(src.len());
    for (name, value) in src.iter() {
        if is_hop_by_hop(name) {
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

    let mut headers = HeaderMap::with_capacity(resp.headers().len());
    for (name, value) in resp.headers().iter() {
        // Drop hop-by-hop and length/framing headers: we re-stream the body and
        // let the HTTP server set framing. content-length on a streamed body
        // would risk a mismatch.
        if is_hop_by_hop(name) || name == "content-length" {
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

fn is_hop_by_hop(name: &HeaderName) -> bool {
    HOP_BY_HOP
        .iter()
        .any(|h| name.as_str().eq_ignore_ascii_case(h))
}
