import asyncio
import contextlib
import logging
import socket
import sys

from fastmcp.client.auth import OAuth
from mcp import McpError
from fastmcp.mcp_config import MCPConfig
from fastmcp.server import create_proxy

from jarvis.config import DATA_DIR, configure_servers, token_storage


def free_port() -> int:
    """Return an available TCP port on localhost."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]



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


@contextlib.contextmanager
def silence():
    """Redirect logging and stderr to the jarvis log file during probing."""
    with open(DATA_DIR / "jarvis.log", "a") as log_file:
        old_stderr = sys.stderr
        sys.stderr = log_file
        handler = logging.StreamHandler(log_file)
        handler.setLevel(logging.DEBUG)
        logging.root.addHandler(handler)
        try:
            yield
        finally:
            sys.stderr = old_stderr
            logging.root.removeHandler(handler)


async def probe_server(name: str, raw: dict) -> list[dict[str, str]]:
    """Probe a single MCP server and return its tool list."""
    mini = MCPConfig.model_validate({"mcpServers": {name: raw}})
    server = mini.mcpServers.get(name)
    # Use a free port instead of the shared 9876 so probing works even when the
    # main Jarvis HTTP server already owns that port.
    if getattr(server, "auth", None) == "oauth":
        server.auth = OAuth(
            token_storage=token_storage,
            callback_port=free_port(),
            client_name="Jarvis Proxy",
        )
    else:
        configure_servers(mini)
    proxy = create_proxy(mini, name=f"probe_{name}")
    with silence():
        try:
            tools = await proxy.list_tools()
        except SystemExit as exc:
            raise OSError(f"probe_server: uvicorn exited ({exc.code})") from exc
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

    async def safe_probe(name: str, raw: dict) -> list[dict]:
        try:
            return await asyncio.wait_for(probe_server(name, raw), timeout=timeout)
        except (SystemExit, KeyboardInterrupt, GeneratorExit):
            raise
        except BaseException as exc:
            print(
                f"[{name}] probe failed: {type(exc).__name__}: {exc}",
                file=sys.stderr,
                flush=True,
            )
            return []

    names = list(raw_servers.keys())
    results = await asyncio.gather(*(safe_probe(n, raw_servers[n]) for n in names))
    return dict(zip(names, results))
