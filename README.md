# Jarvis

MCP proxy that aggregates multiple MCP servers behind 2 synthetic tools (`search_tools` + `call_tool`) using [FastMCP](https://gofastmcp.com). This eliminates context bloat in LLM agents.

## Setup

```bash
# Requires Python 3.11+ and uv
brew install uv
```

## Configuration

Jarvis reads server config from `~/.jarvis/servers.json`. The format follows the standard MCP config:

```json
{
  "mcpServers": {
    "my-server": {
      "url": "https://example.com/mcp",
      "transport": "http"
    }
  }
}
```

For stdio servers:

```json
{
  "mcpServers": {
    "my-tool": {
      "command": "npx",
      "args": ["-y", "@some/mcp-server"],
      "transport": "stdio"
    }
  }
}
```

For OAuth servers (e.g. Atlassian, GitLab), add `"auth": "oauth"` — Jarvis automatically wires in persistent token storage.

Environment variables can be referenced with `${VAR}` syntax in `env` values (e.g. `"${GITLAB_TOKEN}"`).

## macOS app

Jarvis MCP ships as a native macOS menu bar app (built with SwiftUI). It keeps the proxy running as a persistent HTTP server, eliminating cold-start latency.

### Install & run

Open the Xcode project at `macOs/Jarvis/Jarvis.xcodeproj` and build/run, or install a pre-built release.

On first launch the app:

1. Auto-detects `uv` from your shell environment
2. Creates `~/.jarvis/servers.json` with example servers if it doesn't exist
3. Shows the main window and a menu bar icon

### Features

- **Server list** — browse, enable/disable, and inspect all configured MCP servers
- **One-click start/stop** — launch the proxy from the toolbar or menu bar
- **Menu bar icon** — green when running, grey when stopped; quick access to start/stop, copy endpoint URL, and open the main window
- **OAuth authentication** — authenticate OAuth servers directly from the server detail view with live output
- **Log viewer** — tail `~/.jarvis/jarvis.log` in real-time with auto-refresh
- **Settings** — configure `uv` path (auto-detect or browse), HTTP port, and server source
- **System notifications** — get notified when the server is ready

### Server source

By default the app runs the proxy directly from GitHub:

```
uv run --with git+https://github.com/ArtemisMucaj/jarvis-mcp python -m jarvis --http 7070
```

For local development, set a **Local Project Path** in Settings pointing to your checkout. The app will use `uv run --project <path>` instead, picking up local changes immediately.

### Connecting agents

Once the app is running, point your agent at the HTTP endpoint:

```json
{
  "mcp": {
    "jarvis": {
      "type": "http",
      "url": "http://127.0.0.1:7070/mcp"
    }
  }
}
```

The port is configurable in Settings (default: `7070`).

## CLI usage

You can also run Jarvis directly from the command line without the macOS app.

### stdio (default)

```bash
uv run python jarvis.py
```

### HTTP server

```bash
uv run python jarvis.py --http 7070
```

### OAuth authentication

Servers with `"auth": "oauth"` require a one-time browser login:

```bash
uv run python jarvis.py --auth
```

This opens your browser for each OAuth server. Once authenticated, tokens are persisted to `~/.jarvis/` and reused automatically.

## How it works

```
Agent sees: search_tools + call_tool (2 tools, ~50 tokens)

Agent wants to create a GitLab MR:
  -> search_tools("create merge request")
  -> BM25 returns top 5 matching tools with full schemas
  -> call_tool("gitlab_create_merge_request", {...})
  -> Jarvis proxies the call to the GitLab server
```

## File locations

| Item | Path |
|------|------|
| Server config | `~/.jarvis/servers.json` |
| OAuth tokens | `~/.jarvis/` |
| Logs | `~/.jarvis/jarvis.log` |
