import json
import logging
import os
import re
import sys
from pathlib import Path

from mcp import McpError
from fastmcp.client.auth import OAuth
from fastmcp.mcp_config import MCPConfig
from fastmcp.server import create_proxy
from fastmcp.experimental.transforms.code_mode import CodeMode
from fastmcp.server.transforms.search import BM25SearchTransform
from key_value.aio.stores.disk import DiskStore


_ENV_VAR_RE = re.compile(r"\$\{(\w+)\}")


def _expand_env_vars(value: str) -> str:
    """Replace ${VAR} placeholders with their os.environ values."""
    return _ENV_VAR_RE.sub(lambda m: os.environ.get(m.group(1), m.group(0)), value)


class _SuppressMcpSessionWarning(logging.Filter):
    """Demote 'Failed to connect' warnings caused by McpError to DEBUG.

    Unexpected exceptions (non-McpError) are still shown at WARNING level.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        if record.levelno == logging.WARNING and record.exc_info:
            if isinstance(record.exc_info[1], McpError):
                record.levelno = logging.DEBUG
                record.levelname = "DEBUG"
        return True


logging.getLogger("fastmcp.client.transports.config").addFilter(
    _SuppressMcpSessionWarning()
)

# Persistent token storage — survives proxy restarts
TOKEN_DIR = Path.home() / ".jarvis"
token_storage = DiskStore(directory=str(TOKEN_DIR))

# Load base config: prefer ~/.jarvis/servers.json (shared with JarvisMCP.app),
# fall back to the bundled file next to this script (local dev).
# Filter disabled servers and strip the non-standard `enabled` / `disabledTools` fields.
_config_path = Path.home() / ".jarvis" / "servers.json"
if not _config_path.exists():
    _config_path = Path(__file__).parent / "servers.json"
_raw = json.loads(_config_path.read_text())

# Collect per-tool disable list before stripping non-standard fields.
_disabled_tools: set[str] = set()
for _name, _srv in _raw.get("mcpServers", {}).items():
    if _srv.get("enabled", True) is False:
        continue
    for _tool in _srv.get("disabledTools", []):
        _disabled_tools.add(f"{_name}_{_tool}")

_NON_STANDARD_KEYS = {"enabled", "disabledTools"}
_raw["mcpServers"] = {
    name: {k: v for k, v in srv.items() if k not in _NON_STANDARD_KEYS}
    for name, srv in _raw.get("mcpServers", {}).items()
    if srv.get("enabled", True) is not False
}

# Keep a copy of the cleaned raw dicts for parallel per-server probing.
_raw_servers: dict[str, dict] = dict(_raw["mcpServers"])


def _configure_servers(cfg: MCPConfig) -> None:
    """Apply OAuth auth and environment-variable expansion to every server."""
    for name, server in cfg.mcpServers.items():
        if getattr(server, "auth", None) == "oauth":
            server.auth = OAuth(
                token_storage=token_storage,
                callback_port=9876,
                client_name="Jarvis MCP Proxy",
            )
        env = getattr(server, "env", None)
        if env:
            server.env = {
                k: _expand_env_vars(v) if isinstance(v, str) else v
                for k, v in env.items()
            }


config = MCPConfig.model_validate(_raw)
_configure_servers(config)


mcp = create_proxy(
    config,
    name="jarvis",
)

# Disable individual tools BEFORE adding transforms so they are excluded
# from the BM25 search index.  Skip when discovering tools (--list-tools)
# so the full catalogue is returned.
_is_discovery = "--list-tools" in sys.argv
if _disabled_tools and not _is_discovery:
    mcp.disable(names=_disabled_tools)

if not _is_discovery:
    if "--code-mode" in sys.argv:
        mcp.add_transform(CodeMode())
    else:
        mcp.add_transform(BM25SearchTransform(max_results=5))

if __name__ == "__main__":
    import asyncio

    if "--auth" in sys.argv:
        target = next((a for a in sys.argv[2:] if not a.startswith("-")), None)
        if target and target not in config.mcpServers:
            print(
                f"Unknown server '{target}'. Available: {', '.join(config.mcpServers)}"
            )
            sys.exit(1)

        async def auth():
            tools = await mcp.list_tools()
            print(f"Authenticated. {len(tools)} tools available:")
            for t in tools:
                print(f"  - {t.name}")

        try:
            asyncio.run(auth())
        except KeyboardInterrupt:
            print("\nAuth cancelled.")
    elif "--list-tools" in sys.argv:
        # Parse optional --config override
        _probe_raw_servers = _raw_servers
        if "--config" in sys.argv:
            idx = sys.argv.index("--config")
            if idx + 1 < len(sys.argv):
                override_path = Path(sys.argv[idx + 1])
                if override_path.exists():
                    override_raw = json.loads(override_path.read_text())
                    # Build disabled_tools set from override config
                    override_disabled_tools: set[str] = set()
                    for _name, _srv in override_raw.get("mcpServers", {}).items():
                        if _srv.get("enabled", True) is False:
                            continue
                        for _tool in _srv.get("disabledTools", []):
                            override_disabled_tools.add(f"{_name}_{_tool}")
                    # Strip non-standard keys and filter disabled servers
                    override_raw["mcpServers"] = {
                        name: {k: v for k, v in srv.items() if k not in _NON_STANDARD_KEYS}
                        for name, srv in override_raw.get("mcpServers", {}).items()
                        if srv.get("enabled", True) is not False
                    }
                    _probe_raw_servers = dict(override_raw["mcpServers"])

        async def _probe(name: str, raw: dict) -> list[dict[str, str]]:
            mini = MCPConfig.model_validate({"mcpServers": {name: raw}})
            _configure_servers(mini)
            proxy = create_proxy(mini, name=f"_probe_{name}")
            tools = await proxy.list_tools()
            prefix = f"{name}_"
            return [
                {
                    "name": t.name.removeprefix(prefix),
                    "description": t.description or "",
                }
                for t in tools
            ]

        async def discover():
            async def safe_probe(name: str, raw: dict) -> list[dict[str, str]]:
                try:
                    return await asyncio.wait_for(_probe(name, raw), timeout=30)
                except Exception as exc:
                    print(f"[{name}] probe failed: {exc}", file=sys.stderr)
                    return []

            names = list(_probe_raw_servers.keys())
            results = await asyncio.gather(
                *(safe_probe(n, _probe_raw_servers[n]) for n in names)
            )
            json.dump(dict(zip(names, results)), sys.stdout, indent=2)

        try:
            asyncio.run(discover())
        except KeyboardInterrupt:
            pass
    elif "--http" in sys.argv:
        idx = sys.argv.index("--http")
        port_arg = sys.argv[idx + 1] if idx + 1 < len(sys.argv) else ""
        port = int(port_arg) if port_arg.isdigit() else 7070
        mcp.run(transport="streamable-http", host="127.0.0.1", port=port, show_banner=False)
    else:
        mcp.run(show_banner=False)