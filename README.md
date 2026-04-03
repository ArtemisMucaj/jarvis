# Jarvis

MCP proxy that aggregates multiple MCP servers behind 2 synthetic tools (`search_tools` + `call_tool`) using [FastMCP](https://gofastmcp.com). This eliminates context bloat in LLM agents.

## Install

### macOS app (recommended)

Download `Jarvis-<version>.dmg` from the [latest release](https://github.com/ArtemisMucaj/jarvis-mcp/releases/latest), open it, and drag **Jarvis** to `/Applications`.

The app is ad-hoc signed. On first launch macOS may show a Gatekeeper warning — right-click the app and choose **Open** to bypass it.

No Python or `uv` installation required. The app bundles its own self-contained `jarvis` binary.

### Standalone binary (Linux / headless macOS)

Download the binary for your platform from the [latest release](https://github.com/ArtemisMucaj/jarvis-mcp/releases/latest):

| Platform | File |
|---|---|
| macOS (Apple Silicon) | `jarvis-<version>-macos-arm64` |
| Linux (x86_64) | `jarvis-<version>-linux-x86_64` |

```bash
chmod +x jarvis-<version>-linux-x86_64
./jarvis-<version>-linux-x86_64 --http 7070
```

### From source (requires Python 3.11+ and uv)

```bash
uv run python jarvis.py --http 7070
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

Servers with `"enabled": false` are loaded but not started.

## macOS app

Jarvis ships as a native macOS menu bar app (SwiftUI). It keeps the proxy running as a persistent HTTP server, eliminating cold-start latency.

### Features

- **Menu bar icon** — coloured when running, dimmed when stopped; quick access to start/stop, copy endpoint, and open the main window
- **Server list** — browse, enable/disable, and inspect all configured MCP servers
- **One-click start/stop** — launch the proxy from the toolbar or the menu bar popover
- **Preset config switcher** — save and switch between multiple `servers.json` files (e.g. work, personal, testing)
- **Inline log viewer** — tail `~/.jarvis/jarvis.log` in real-time directly in the Presets panel
- **System notifications** — notified when the server becomes ready
- **Settings** — configure the HTTP port (default: `7070`)

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

The port is configurable in Settings.

## CLI usage

You can run Jarvis directly from the command line (requires `uv`).

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

Tokens are persisted to `~/.jarvis/` and reused automatically on subsequent runs.

## How it works

```
Agent sees: search_tools + call_tool (2 tools, ~50 tokens)

Agent wants to create a GitLab MR:
  -> search_tools("create merge request")
  -> BM25 returns top 5 matching tools with full schemas
  -> call_tool("gitlab_create_merge_request", {...})
  -> Jarvis proxies the call to the GitLab MCP server
```

## File locations

| Item | Path |
|---|---|
| Server config | `~/.jarvis/servers.json` |
| OAuth tokens | `~/.jarvis/` |
| Logs | `~/.jarvis/jarvis.log` |

## Building from source

### macOS app

```bash
# Build the bundled jarvis binary first
bash scripts/build_jarvis_binary.sh

# Then build the Xcode project
xcodebuild -project macOs/Jarvis/Jarvis.xcodeproj -scheme Jarvis -configuration Debug build
```

### Standalone binary

```bash
# macOS
bash scripts/build_jarvis_binary.sh        # output: macOs/Jarvis/Jarvis/Resources/jarvis

# Linux
bash scripts/build_jarvis_binary_linux.sh  # output: dist/jarvis
```

Requires `uv` (build-time only). PyInstaller 6.19.0 is fetched automatically via `uv run --with`.
