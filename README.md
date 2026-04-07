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
uv run python -m jarvis --http 7070
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

Use `"disabledTools"` to suppress individual tools from a server without disabling it entirely:

```json
{
  "mcpServers": {
    "my-tool": {
      "command": "npx",
      "args": ["-y", "@some/mcp-server"],
      "transport": "stdio",
      "disabledTools": ["dangerous_tool", "another_tool"]
    }
  }
}
```

Disabled tools are excluded from BM25 search results and cannot be called through Jarvis. You can also manage enabled servers and disabled tools interactively with `jarvis mcp` (see [TUI](#tui)).

## macOS app

Jarvis ships as a native macOS menu bar app (SwiftUI). It keeps the proxy running as a persistent HTTP server, eliminating cold-start latency.

### Features

- **Menu bar icon** — coloured when running, dimmed when stopped; quick access to start/stop, copy endpoint, and open the main window
- **Server list** — browse, enable/disable, and inspect all configured MCP servers
- **One-click start/stop** — launch the proxy from the toolbar or the menu bar popover
- **Preset config switcher** — save and switch between multiple `servers.json` files (e.g. work, personal, testing)
- **Inline log viewer** — tail `~/.jarvis/jarvis.log` in real-time directly in the Presets panel
- **System notifications** — notified when the server becomes ready
- **Settings** — configure the HTTP port (default: `7070`) and toggle **Code Mode**

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
uv run python -m jarvis
```

### HTTP server

```bash
uv run python -m jarvis --http 7070
```

### Specifying a config file

Override the active config file with `--config`:

```bash
uv run python -m jarvis --config /path/to/servers.json --http 7070
```

When `--config` is omitted, Jarvis resolves the config in this priority order:
1. Active preset from `~/.jarvis/presets.json`
2. `~/.jarvis/servers.json`
3. `servers.json` in the repo root directory

### List available tools

Probe all configured servers and print every tool as JSON, then exit:

```bash
uv run python -m jarvis --list-tools
```

### Code Mode

By default Jarvis uses BM25 search to surface relevant tools. Pass `--code-mode` to switch to FastMCP's Code Mode, where the LLM writes sandboxed Python scripts that batch multiple tool calls in a single step:

```bash
uv run python -m jarvis --http 7070 --code-mode
```

Code Mode can also be toggled in the macOS app under **Settings**.

### OAuth authentication

Servers with `"auth": "oauth"` require a one-time browser login. Authenticate all OAuth servers at once:

```bash
uv run python -m jarvis --auth
```

Or target a specific server by name:

```bash
uv run python -m jarvis --auth my-server
```

Tokens are persisted to `~/.jarvis/` and reused automatically on subsequent runs.

## TUI

Jarvis ships a terminal UI (powered by [Textual](https://textual.textualize.io/)) for interactive management.

### Manage servers and tools

```bash
uv run python -m jarvis mcp
```

Opens a tree view of all configured servers and their tools. Use **Space** to enable/disable a server or an individual tool, **r** to re-probe servers, and **q** to save changes and quit.

### Manage OAuth authentication

```bash
uv run python -m jarvis auth
```

Opens a table of all configured servers and their auth type. Use **l** to trigger the OAuth login flow for the selected server (opens the browser) and **x** to clear all cached tokens.

## How it works

Jarvis exposes only 2 tools to the agent regardless of how many MCP servers are configured. Two modes are available:

### Default mode (BM25 search)

```
Agent sees: search_tools + call_tool (2 tools, ~50 tokens)

Agent wants to create a GitLab MR:
  -> search_tools("create merge request")
  -> BM25 returns top 5 matching tools with full schemas
  -> call_tool("gitlab_create_merge_request", {...})
  -> Jarvis proxies the call to the GitLab MCP server
```

### Code Mode (`--code-mode`)

Instead of searching and calling tools one at a time, the LLM writes a sandboxed Python script that batches multiple tool calls in a single step. Useful when a task requires many sequential tool interactions.

```
Agent sees: run_python_code (1 tool)

Agent wants to create a GitLab MR and post a comment:
  -> run_python_code("""
       result = gitlab_create_merge_request(title="feat: ...", ...)
       gitlab_create_note(mr_iid=result["iid"], body="Ready for review")
     """)
  -> Jarvis executes both calls and returns the combined result
```

## REST API

When running in HTTP mode (`--http PORT`), Jarvis starts a companion REST API on `PORT + 1` (default `7071`). All endpoints are bound to `127.0.0.1`.

| Method | Path | Description |
|---|---|---|
| GET | `/api/health` | Returns `{"status":"ok","mcp_port":…,"api_port":…}` |
| GET | `/api/tools[?config=PATH]` | Probe all servers and return the full tool catalogue |
| GET | `/api/config[?path=PATH]` | Read the active `servers.json` |
| PUT | `/api/config[?path=PATH]` | Overwrite `servers.json` with the request body |
| POST | `/api/servers/{name}/toggle` | Enable/disable a server — body `{"enabled": bool}` |
| POST | `/api/tools/toggle` | Enable/disable a tool — body `{"server": "…", "tool": "…", "enabled": bool}` |
| GET | `/api/presets` | List all presets and the active preset ID |
| POST | `/api/presets` | Create a preset — body `{"name": "…", "filePath": "…"}` |
| PATCH | `/api/presets/{id}` | Rename or change the file path of a preset |
| DELETE | `/api/presets/{id}` | Delete a preset |
| POST | `/api/presets/{id}/activate` | Switch to a preset |
| POST | `/api/presets/default/activate` | Revert to the default `~/.jarvis/servers.json` |

The macOS app uses this API internally for its server list and preset switcher.

## File locations

| Item | Path |
|---|---|
| Server config | `~/.jarvis/servers.json` |
| Preset list | `~/.jarvis/presets.json` |
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
