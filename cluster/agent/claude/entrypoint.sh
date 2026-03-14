#!/bin/bash
set -e

# Register files_mcp.py as a stdio MCP server wrapped by mcp-watchdog
claude mcp add fileserver --scope user -- \
    mcp-watchdog --verbose -- python /app/files_mcp.py

# Verify config was written before locking
if [ ! -f /home/appuser/.claude.json ]; then
    echo "ERROR: .claude.json was not written by claude mcp add"
    exit 1
fi

# Lock only the config file, not the directory
chmod 440 /home/appuser/.claude.json

exec python /app/server.py