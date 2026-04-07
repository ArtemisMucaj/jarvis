import asyncio
import json
import sys
from pathlib import Path

from fastmcp.mcp_config import MCPConfig
from fastmcp.server import create_proxy
from fastmcp.experimental.transforms.code_mode import CodeMode
from fastmcp.server.transforms.search import BM25SearchTransform

from jarvis.config import (
    active_config_from_presets,
    configure_servers,
    get_disabled_tools,
    load_raw_config,
)
from jarvis.api import start_api_thread
from jarvis.probe import probe_all_servers


# Priority: --config flag  >  active preset in presets.json  >  ~/.jarvis/servers.json
config_path = active_config_from_presets()

# Preprocess argv to extract --config and filter it out before deriving subcommand
filtered_argv = []
skip_next = False
for i, arg in enumerate(sys.argv[1:], start=1):
    if skip_next:
        skip_next = False
        continue
    if arg == "--config":
        if i + 1 < len(sys.argv):
            override = Path(sys.argv[i + 1])
            if override.exists():
                config_path = override
            else:
                print(
                    f"Error: config file not found: {sys.argv[i + 1]}",
                    file=sys.stderr,
                )
                sys.exit(1)
            skip_next = True
        else:
            print("Error: --config requires a path argument", file=sys.stderr)
            sys.exit(1)
    else:
        filtered_argv.append(arg)

# Derive subcommand from filtered argv (first non-flag token)
subcmd = next((arg for arg in filtered_argv if not arg.startswith("-")), None)

if subcmd == "mcp":
    from jarvis.tui import MCPManagerApp

    MCPManagerApp(config_path).run()
    sys.exit(0)

if subcmd == "auth":
    from jarvis.tui import AuthManagerApp

    AuthManagerApp(config_path).run()
    sys.exit(0)

if "--list-tools" in sys.argv:
    _, raw_servers = load_raw_config(config_path)

    async def discover() -> None:
        json.dump(await probe_all_servers(raw_servers), sys.stdout, indent=2)

    try:
        asyncio.run(discover())
    except KeyboardInterrupt:
        pass
    sys.exit(0)

mcp_dict, _ = load_raw_config(config_path)
disabled_tools = get_disabled_tools(config_path)
code_mode = "--code-mode" in sys.argv

config = MCPConfig.model_validate(mcp_dict)
configure_servers(config)
mcp = create_proxy(config, name="jarvis")

if disabled_tools:
    mcp.disable(names=disabled_tools)

if "--auth" in sys.argv:
    # Scan filtered_argv for auth target (first non-flag after --auth)
    auth_idx = next(
        (i for i, arg in enumerate(filtered_argv) if arg == "--auth"), None
    )
    if auth_idx is not None:
        target = next(
            (
                filtered_argv[i]
                for i in range(auth_idx + 1, len(filtered_argv))
                if not filtered_argv[i].startswith("-")
            ),
            None,
        )
    else:
        target = None
    if target and target not in config.mcpServers:
        print(
            f"Unknown server '{target}'. Available: {', '.join(config.mcpServers)}"
        )
        sys.exit(1)

    mcp.add_transform(BM25SearchTransform(max_results=5))

    async def auth() -> None:
        tools = await mcp.list_tools()
        print(f"Authenticated. {len(tools)} tools available:")
        for t in tools:
            print(f"  - {t.name}")

    try:
        asyncio.run(auth())
    except KeyboardInterrupt:
        print("\nAuth cancelled.")

elif "--http" in sys.argv:
    idx = sys.argv.index("--http")
    port_arg = sys.argv[idx + 1] if idx + 1 < len(sys.argv) else ""
    # Validate port is < 65535 (need room for API port at port+1)
    if port_arg.isdigit():
        parsed_port = int(port_arg)
        port = parsed_port if parsed_port <= 65534 else 7070
    else:
        port = 7070

    mcp.add_transform(
        CodeMode() if code_mode else BM25SearchTransform(max_results=5)
    )

    async def _run_http() -> None:
        start_api_thread(config_path, port, port + 1)
        await mcp.run_async(
            transport="streamable-http",
            host="127.0.0.1",
            port=port,
            show_banner=False,
        )

    asyncio.run(_run_http())

else:
    mcp.add_transform(
        CodeMode() if code_mode else BM25SearchTransform(max_results=5)
    )
    mcp.run(show_banner=False)
