#!/bin/sh
set -e
# Caddy isolation checks
# Caddy only needs HOST_DOMAIN for egress proxy.
# It must never see any backend credentials.
for var in ANTHROPIC_API_KEY DYNAMIC_AGENT_KEY MCP_API_TOKEN CLAUDE_API_TOKEN AGENT_API_TOKEN; do
  eval val=\$$var 2>/dev/null || val=""
  if [ -n "$val" ]; then
    echo "FATAL: $var present in caddy-sidecar" >&2; exit 1
  fi
done
# No .env files should be in the image
if find /etc/caddy -name '*.env' 2>/dev/null | grep -q .; then
  echo "FATAL: .env file found in /etc/caddy" >&2; exit 1
fi
echo "Caddy isolation checks passed"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile "$@"