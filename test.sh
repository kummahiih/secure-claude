#!/bin/bash
set -euo pipefail

# test.sh — Offline unit tests only
#
# Runs all sub-repository unit tests. Does NOT require:
#   - Docker socket access
#   - Network connectivity
#   - Real API keys or secrets
#   - A running cluster instance
#
# For CVE audits, Docker builds, and integration tests, see test-integration.sh.

echo "[$(date +'%H:%M:%S')] Starting unit test suite..."

# Activate venv if present (CI or local dev)
if [ -f venv/bin/activate ]; then
    # shellcheck disable=SC1091
    . venv/bin/activate
fi

# Provide dummy tokens so the test harnesses don't crash on missing env vars
export MCP_API_TOKEN="${MCP_API_TOKEN:-dummy-mcp-token}"
export PLAN_API_TOKEN="${PLAN_API_TOKEN:-dummy-plan-token}"
export TESTER_API_TOKEN="${TESTER_API_TOKEN:-dummy-tester-token}"
export CLAUDE_API_TOKEN="${CLAUDE_API_TOKEN:-dummy-claude-token}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-dummy-anthropic-key}"
export DYNAMIC_AGENT_KEY="${DYNAMIC_AGENT_KEY:-dummy-dynamic-key}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://proxy:4000}"
export GIT_API_TOKEN="${GIT_API_TOKEN:-dummy-git-token}"
export GIT_SERVER_URL="${GIT_SERVER_URL:-https://git-server:8443}"
export LOG_API_TOKEN="${LOG_API_TOKEN:-dummy-log-token}"

echo "========================================"
echo "  SUB-REPOSITORY UNIT TESTS"
echo "========================================"

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 1/5: Running agent tests..."
(cd cluster/agent && ./test.sh)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 2/5: Running planner tests..."
(cd cluster/planner && ./test.sh)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 3/5: Running tester tests..."
(cd cluster/tester && ./test.sh)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 4/5: Running log-server tests..."
(cd cluster/log-server && bash ./test.sh)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 5/5: Running client tests..."
(cd cluster/client && bash ./test.sh)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] ✅ All unit tests passed!"
echo ""
echo "To run CVE audits, Docker builds, and integration tests:"
echo "  ./test-integration.sh"
