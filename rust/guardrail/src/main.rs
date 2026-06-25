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

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(cfg.timeout_secs))
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

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    info!("shutdown signal received");
}
