# Jarvis

MCP proxy that aggregates multiple MCP servers behind 2 synthetic tools (`search_tools` + `call_tool`) using [FastMCP](https://gofastmcp.com). This eliminates context bloat in LLM agents like opencode.

## Setup

```bash
# Requires Python 3.11+ and uv
brew install uv

# Install dependencies
uv sync
```

## Running

```bash
uv run python jarvis.py
```

This starts the proxy over **stdio**. It reads `servers.json` for the list of backend MCP servers.

## First-time OAuth authentication

Servers with `"auth": "oauth"` (currently **Atlassian** and **GitLab**) require a one-time browser login.

```bash
uv run python jarvis.py --auth
```

This connects to all configured servers. For each OAuth server, Jarvis will:

1. Print an authorization URL in the terminal
2. Open your browser to the provider's login page
3. Start a local callback server (e.g. `http://localhost:<port>/callback`)
4. Wait for you to complete the login flow

Once authenticated, tokens are persisted to `.tokens/` on disk. Subsequent runs reuse them automatically — no browser needed unless a token expires and can't be refreshed.

If the browser doesn't open automatically, copy the printed URL and open it manually.

## Adding a new server

Edit `servers.json`. The format follows the standard MCP config:

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

For OAuth servers, add `"auth": "oauth"` — Jarvis automatically wires in persistent token storage.

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

## macOS tray app

`tray.py` is a menu bar app that keeps Jarvis running as a persistent HTTP server, eliminating cold-start latency for agents.

```bash
uv run python tray.py
```

The app auto-starts the proxy on launch and shows its status in the menu bar. From the menu you can start/stop/restart the server, copy the endpoint URL, and open the log file.

The server listens on `http://127.0.0.1:7070/mcp` by default. Override the port with the `JARVIS_PORT` environment variable.

Logs are written to `~/.jarvis-mcp/jarvis.log`.

### Connecting agents via HTTP

Once the tray app is running, point your agent at the HTTP endpoint instead of spawning Jarvis as a subprocess:

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

### Opencode integration (stdio, original)

Add this to your `opencode.json`:

```json
{
  "mcp": {
    "jarvis": {
      "type": "local",
      "command": ["uv", "run", "--project", "/path/to/mcps", "python", "/path/to/mcps/jarvis.py"],
      "enabled": true
    }
  }
}
```

## How it works

```
Agent sees: search_tools + call_tool (2 tools, ~50 tokens)

Agent wants to create a GitLab MR:
  -> search_tools("create merge request")
  -> BM25 returns top 5 matching tools with full schemas
  -> call_tool("gitlab_create_merge_request", {...})
  -> Jarvis proxies the call to the GitLab server
```
