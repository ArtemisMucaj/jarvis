#!/bin/bash
# Launch the Jarvis MCP tray app.
set -e

cd "$(dirname "$0")"
uv sync --quiet

# Create Info.plist for the venv Python so macOS notifications work.
PLIST=".venv/bin/Info.plist"
if [ ! -f "$PLIST" ]; then
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string "com.jarvis-mcp.tray"' "$PLIST"
fi

exec .venv/bin/python tray.py "$@"
