import logging
import sys

from mcp import McpError
from fastmcp.mcp_config import MCPConfig
from fastmcp.server import create_proxy

from jarvis.config import configure_servers


# ── Logging ───────────────────────────────────────────────────────────────────


class SuppressMcpSessionWarning(logging.Filter):
    """Demote 'Failed to connect' warnings caused by McpError to DEBUG."""

    def filter(self, record: logging.LogRecord) -> bool:
        if record.levelno == logging.WARNING and record.exc_info:
            if isinstance(record.exc_info[1], McpError):
                record.levelno = logging.DEBUG
                record.levelname = "DEBUG"
        return True


logging.getLogger("fastmcp.client.transports.config").addFilter(
    SuppressMcpSessionWarning()
)


# ── Server probing ────────────────────────────────────────────────────────────


async def probe_server(name: str, raw: dict) -> list[dict[str, str]]:
    """Probe a single MCP server and return its tool list."""
    mini = MCPConfig.model_validate({"mcpServers": {name: raw}})
    configure_servers(mini)
    proxy = create_proxy(mini, name=f"probe_{name}")
    tools = await proxy.list_tools()
    prefix = f"{name}_"
    return [
        {"name": t.name.removeprefix(prefix), "description": t.description or ""}
        for t in tools
    ]


async def probe_all_servers(
    raw_servers: dict,
    timeout: float = 30,
) -> dict[str, list[dict[str, str]]]:
    """Probe all servers in parallel; failures produce empty lists."""
    import asyncio

    async def safe_probe(name: str, raw: dict) -> list[dict]:
        try:
            return await asyncio.wait_for(probe_server(name, raw), timeout=timeout)
        except Exception as exc:
            print(
                f"[{name}] probe failed: {type(exc).__name__}: {exc}",
                file=sys.stderr,
                flush=True,
            )
            return []

    names = list(raw_servers.keys())
    results = await asyncio.gather(*(safe_probe(n, raw_servers[n]) for n in names))
    return dict(zip(names, results))
