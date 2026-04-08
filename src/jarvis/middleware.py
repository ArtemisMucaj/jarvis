"""Middleware that surfaces auth failures from proxied tool calls.

When a proxied MCP server returns a 401/Unauthorized error inside a tool
result (e.g. "GitLab API error: 401 Unauthorized"), FastMCP's OAuth handler
never sees it because the MCP transport itself returned HTTP 200.  This
middleware detects those errors and re-raises them with an actionable hint,
so the user knows to run ``jarvis --auth <server>`` to refresh their token.

The stored OAuth token (including its refresh_token) is intentionally left
intact so that ``jarvis --auth`` can use the refresh token to silently obtain
a new access token rather than forcing a full browser-based re-auth flow.
"""

from __future__ import annotations

import mcp.types as mt
from fastmcp.exceptions import ToolError
from fastmcp.server.middleware import Middleware, MiddlewareContext
from fastmcp.tools.base import ToolResult

_AUTH_MARKERS = ("401", "unauthorized")


def _is_auth_error(text: str) -> bool:
    lower = text.lower()
    return any(marker in lower for marker in _AUTH_MARKERS)


class AuthErrorMiddleware(Middleware):
    """Re-raise 401/Unauthorized ToolErrors with an actionable re-auth hint.

    Only servers whose config includes ``"auth": "oauth"`` receive the
    ``jarvis --auth`` hint.  Other backends (e.g. stdio with an env-var
    token) get a generic message about checking their token configuration.
    """

    def __init__(self, raw_servers: dict[str, dict]) -> None:
        """
        Args:
            raw_servers: ``{server_name: server_config_dict}`` from
                :func:`jarvis.config.load_raw_config` (pre-OAuth-injection).
        """
        # Sort names longest-first to avoid prefix collisions
        # (e.g. "git" matching before "gitlab").
        self._servers_by_len = sorted(
            raw_servers.items(), key=lambda kv: len(kv[0]), reverse=True
        )

    async def on_call_tool(
        self,
        context: MiddlewareContext[mt.CallToolRequestParams],
        call_next,
    ) -> ToolResult:
        try:
            return await call_next(context)
        except ToolError as exc:
            error_text = str(exc)
            if not _is_auth_error(error_text):
                raise

            server_name, srv_config = self._find_server(context.message.name)
            if server_name is None:
                raise

            if srv_config.get("auth") == "oauth":
                raise ToolError(
                    f"{error_text}\n\n"
                    f"Authentication failed for '{server_name}'. "
                    f"Run 'jarvis --auth {server_name}' to refresh the OAuth token."
                ) from exc
            else:
                raise ToolError(
                    f"{error_text}\n\n"
                    f"Authentication failed for '{server_name}'. "
                    f"Check the token configuration for this server "
                    f"(e.g. the GITLAB_TOKEN environment variable)."
                ) from exc

    def _find_server(self, tool_name: str) -> tuple[str, dict] | tuple[None, None]:
        """Return ``(server_name, config)`` whose prefix matches *tool_name*."""
        for name, cfg in self._servers_by_len:
            if tool_name.startswith(f"{name}_"):
                return name, cfg
        return None, None
