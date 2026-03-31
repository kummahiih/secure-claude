#!/bin/sh
set -e
# log-server isolation checks: refuse to start if any cross-service secret is present
for var in ANTHROPIC_API_KEY CLAUDE_API_TOKEN DYNAMIC_AGENT_KEY MCP_API_TOKEN PLAN_API_TOKEN TESTER_API_TOKEN GIT_API_TOKEN; do
  eval val=\$$var 2>/dev/null || val=""
  if [ -n "$val" ]; then
    echo "FATAL: $var present in log-server" >&2; exit 1
  fi
done
if [ -z "$LOG_API_TOKEN" ]; then
  echo "FATAL: LOG_API_TOKEN missing" >&2; exit 1
fi
# Verify logs mount is present
if [ ! -d "/logs" ]; then
  echo "FATAL: /logs not mounted" >&2; exit 1
fi
exec /app/log-server "$@"
