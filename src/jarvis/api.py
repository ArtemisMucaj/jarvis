import json
import threading
import uuid
from pathlib import Path

from jarvis.config import (
    TOKEN_DIR,
    active_config_from_presets,
    load_presets,
    load_raw_config,
    save_presets,
)
from jarvis.probe import probe_all_servers


# ── REST API ──────────────────────────────────────────────────────────────────


def create_api_app(default_config_path: Path, mcp_port: int):
    """Build a Starlette REST API app that runs alongside the MCP server.

    Endpoints
    ---------
    GET  /api/health                       → server status
    GET  /api/tools[?config=PATH]          → probe servers, return tool catalogue
    GET  /api/config[?path=PATH]           → read servers.json
    PUT  /api/config[?path=PATH]           → overwrite servers.json
    POST /api/servers/{name}/toggle        → body {enabled: bool}
    POST /api/tools/toggle                 → body {server, tool, enabled: bool}
    GET  /api/presets                      → list presets + active
    POST /api/presets                      → create preset
    PATCH/DELETE /api/presets/{id}         → update / remove
    POST /api/presets/{id}/activate        → switch active preset
    POST /api/presets/default/activate     → revert to default
    """
    from starlette.applications import Starlette
    from starlette.exceptions import HTTPException
    from starlette.requests import Request
    from starlette.responses import JSONResponse
    from starlette.routing import Route

    def resolve_config(request: Request, param: str = "config") -> Path:
        override = request.query_params.get(param)
        if not override:
            return default_config_path

        # Only allow the default config or preset files in the config directory
        override_path = Path(override)
        config_dir = TOKEN_DIR

        # Resolve to absolute path and check it's within config directory
        try:
            resolved = override_path.resolve()
            # Allow default config path
            if resolved == default_config_path.resolve():
                return resolved
            # Allow files in the config directory (no traversal)
            if resolved.parent == config_dir and resolved.suffix == ".json":
                return resolved
        except Exception:
            pass

        raise HTTPException(status_code=400, detail="invalid config")

    async def health(request: Request) -> JSONResponse:
        return JSONResponse(
            {"status": "ok", "mcp_port": mcp_port, "api_port": mcp_port + 1}
        )

    async def get_tools(request: Request) -> JSONResponse:
        # Always probe each backend directly so the management UI gets the real
        # per-server tool lists.  Going through the running proxy's list_tools()
        # would return only the 2 synthetic BM25 tools, not the individual tools
        # needed for the enable/disable UI.
        config_path = resolve_config(request)
        try:
            _, raw_servers = load_raw_config(config_path)
            return JSONResponse(await probe_all_servers(raw_servers))
        except Exception as exc:
            return JSONResponse({"error": str(exc)}, status_code=500)

    async def config_endpoint(request: Request) -> JSONResponse:
        config_path = resolve_config(request, param="path")
        if request.method == "GET":
            try:
                return JSONResponse(json.loads(config_path.read_text()))
            except Exception as exc:
                return JSONResponse({"error": str(exc)}, status_code=500)
        try:
            config_path.write_text(json.dumps(await request.json(), indent=2))
            return JSONResponse({"status": "ok"})
        except Exception as exc:
            return JSONResponse({"error": str(exc)}, status_code=500)

    async def toggle_server(request: Request) -> JSONResponse:
        name = request.path_params["name"]
        config_path = resolve_config(request, param="path")
        try:
            enabled = (await request.json()).get("enabled", True)
            raw = json.loads(config_path.read_text())
            servers = raw.get("mcpServers", {})
            if name not in servers:
                return JSONResponse(
                    {"error": f"Server '{name}' not found"}, status_code=404
                )
            if enabled:
                servers[name].pop("enabled", None)
            else:
                servers[name]["enabled"] = False
            config_path.write_text(json.dumps(raw, indent=2))
            return JSONResponse({"status": "ok"})
        except Exception as exc:
            return JSONResponse({"error": str(exc)}, status_code=500)

    async def toggle_tool(request: Request) -> JSONResponse:
        config_path = resolve_config(request, param="path")
        try:
            body = await request.json()
            server_name, tool_name = body["server"], body["tool"]
            enabled = body.get("enabled", True)
            raw = json.loads(config_path.read_text())
            servers = raw.get("mcpServers", {})
            if server_name not in servers:
                return JSONResponse(
                    {"error": f"Server '{server_name}' not found"}, status_code=404
                )
            srv = servers[server_name]
            disabled = srv.get("disabledTools", [])
            if enabled:
                disabled = [t for t in disabled if t != tool_name]
            elif tool_name not in disabled:
                disabled.append(tool_name)
            if disabled:
                srv["disabledTools"] = disabled
            else:
                srv.pop("disabledTools", None)
            config_path.write_text(json.dumps(raw, indent=2))
            return JSONResponse({"status": "ok"})
        except Exception as exc:
            return JSONResponse({"error": str(exc)}, status_code=500)

    # ── Preset endpoints ──────────────────────────────────────────────────────

    async def list_presets(request: Request) -> JSONResponse:
        data = load_presets()
        return JSONResponse(
            {**data, "activeConfigPath": str(active_config_from_presets())}
        )

    async def create_preset(request: Request) -> JSONResponse:
        try:
            body = await request.json()
            preset_id = str(uuid.uuid4())
            preset = {
                "id": preset_id,
                "name": body["name"],
                "filePath": body["filePath"],
            }
            data = load_presets()
            data["presets"].append(preset)
            save_presets(data)
            return JSONResponse({"preset": preset}, status_code=201)
        except Exception as exc:
            return JSONResponse({"error": str(exc)}, status_code=400)

    async def update_preset(request: Request) -> JSONResponse:
        preset_id = request.path_params["id"]
        try:
            body = await request.json()
            data = load_presets()
            for p in data["presets"]:
                if p["id"] == preset_id:
                    p.update({k: body[k] for k in ("name", "filePath") if k in body})
                    save_presets(data)
                    return JSONResponse({"preset": p})
            return JSONResponse({"error": "Preset not found"}, status_code=404)
        except Exception as exc:
            return JSONResponse({"error": str(exc)}, status_code=400)

    async def delete_preset(request: Request) -> JSONResponse:
        preset_id = request.path_params["id"]
        data = load_presets()
        before = len(data["presets"])
        data["presets"] = [p for p in data["presets"] if p["id"] != preset_id]
        if len(data["presets"]) == before:
            return JSONResponse({"error": "Preset not found"}, status_code=404)
        if data.get("activePresetID") == preset_id:
            data["activePresetID"] = None
        save_presets(data)
        return JSONResponse({"status": "ok"})

    async def activate_preset(request: Request) -> JSONResponse:
        preset_id = request.path_params.get("id")
        data = load_presets()
        if preset_id and preset_id != "default":
            if not any(p["id"] == preset_id for p in data["presets"]):
                return JSONResponse({"error": "Preset not found"}, status_code=404)
            data["activePresetID"] = preset_id
        else:
            data["activePresetID"] = None
        save_presets(data)
        return JSONResponse({"status": "ok", "activePresetID": data["activePresetID"]})

    return Starlette(
        routes=[
            Route("/api/health", health),
            Route("/api/tools", get_tools),
            Route("/api/config", config_endpoint, methods=["GET", "PUT"]),
            Route("/api/servers/{name}/toggle", toggle_server, methods=["POST"]),
            Route("/api/tools/toggle", toggle_tool, methods=["POST"]),
            Route("/api/presets", list_presets, methods=["GET"]),
            Route("/api/presets", create_preset, methods=["POST"]),
            Route("/api/presets/{id}", update_preset, methods=["PATCH"]),
            Route("/api/presets/{id}", delete_preset, methods=["DELETE"]),
            Route("/api/presets/{id}/activate", activate_preset, methods=["POST"]),
        ]
    )


def start_api_thread(config_path: Path, mcp_port: int, api_port: int) -> None:
    """Start the REST API server in a daemon thread alongside the MCP server."""
    import uvicorn

    app = create_api_app(config_path, mcp_port)
    threading.Thread(
        target=uvicorn.run,
        kwargs={
            "app": app,
            "host": "127.0.0.1",
            "port": api_port,
            "log_level": "error",
        },
        daemon=True,
    ).start()
