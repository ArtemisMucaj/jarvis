//! Binary entrypoint for the guardrail proxy. Thin wrapper around the library:
//! parse config, build the HTTP client, serve until shutdown. All behaviour
//! lives in [`guardrail`] so it can be exercised by integration tests.

use std::time::Duration;

use clap::Parser;
use guardrail::{build_app, AppState, Config};
use tracing::info;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // RUST_LOG overrides; default to info for our crate, warn elsewhere.
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "guardrail=info,warn".into()),
        )
        .with_writer(std::io::stderr)
        .init();

    let cfg = Config::parse();

    // No client-wide `timeout`: that is a deadline on the whole request/response
    // lifetime and would cut off long-lived SSE streams. Bound only the connect
    // phase and idle gaps between read chunks (read_timeout resets per chunk), so
    // a healthy stream can run indefinitely while a stalled backend still fails.
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(cfg.connect_timeout_secs))
        .read_timeout(Duration::from_secs(cfg.read_timeout_secs))
        .build()?;

    let state = AppState::new(client, &cfg.backend);
    let app = build_app(state);

    info!(listen = %cfg.listen, backend = %cfg.backend, "guardrail passthrough proxy starting");

    let listener = tokio::net::TcpListener::bind(cfg.listen).await?;
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

/// Resolve when the process receives Ctrl-C (SIGINT) or, on Unix, SIGTERM —
/// the signal process managers (systemd, Kubernetes, `kill`) send. Signal
/// registration failures are surfaced rather than silently swallowed.
async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(e) = tokio::signal::ctrl_c().await {
            tracing::error!(error = %e, "failed to listen for Ctrl-C");
        }
    };

    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut sig) => {
                sig.recv().await;
            }
            Err(e) => tracing::error!(error = %e, "failed to install SIGTERM handler"),
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }
    info!("shutdown signal received");
}
