#!/bin/bash
set -e
(
    . .env && \
    . .cluster_tokens.env && \
    . .secrets.env && \
    cd cluster && \
    echo "=== caddy-sidecar ===" && \
    docker-compose logs --tail 200 caddy-sidecar && \
    echo "" && \
    echo "=== litellm-proxy ===" && \
    docker-compose logs --tail 200 proxy && \
    echo "" && \
    echo "=== mcp-server ===" && \
    docker-compose logs --tail 100 mcp-server && \
    echo "" && \
    echo "=== plan-server ===" && \
    docker-compose logs --tail 100 plan-server && \
    echo "" && \
    echo "=== claude-server ===" && \
    docker-compose logs --tail 300 claude-server && \
    echo "" && \
    echo "=== MCP fileserver logs (from Claude Code) ===" && \
    docker exec claude-server sh -c \
      'for f in $(find /home/appuser/.cache/claude-cli-nodejs -path "*mcp-logs-fileserver*" -name "*.jsonl" 2>/dev/null | sort | tail -3); do
        echo "--- $f ---"
        tail -20 "$f" 2>/dev/null
      done' 2>/dev/null || echo "  (no MCP logs found)" && \
    echo "" && \
    echo "=== MCP planner logs (from Claude Code) ===" && \
    docker exec claude-server sh -c \
      'for f in $(find /home/appuser/.cache/claude-cli-nodejs -path "*mcp-logs-planner*" -name "*.jsonl" 2>/dev/null | sort | tail -3); do
        echo "--- $f ---"
        tail -20 "$f" 2>/dev/null
      done' 2>/dev/null || echo "  (no MCP planner logs found)"
)