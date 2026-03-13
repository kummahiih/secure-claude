#!/bin/bash
set -e

cat > /home/appuser/.claude.json << EOF
{
  "mcpServers": {
    "secure-fileserver": {
      "type": "http",
      "url": "https://mcp-server:8443",
      "headers": {
        "Authorization": "Bearer ${MCP_API_TOKEN}"
      }
    }
  }
}
EOF

# Lock home directory so nothing else can be written after this point
chmod 550 /home/appuser

exec python /app/server.py