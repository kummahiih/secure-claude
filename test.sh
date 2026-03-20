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
export CLAUDE_API_TOKEN="${CLAUDE_API_TOKEN:-dummy-claude-token}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-dummy-anthropic-key}"
export DYNAMIC_AGENT_KEY="${DYNAMIC_AGENT_KEY:-dummy-dynamic-key}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://proxy:4000}"

echo "========================================"
echo "  SUB-REPOSITORY UNIT TESTS"
echo "========================================"

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 1/3: Running agent tests..."
(cd cluster/agent && ./test.sh)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 2/3: Running planner tests..."
(cd cluster/planner && ./test.sh)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 3/3: Running tester tests..."
(cd cluster/tester && ./test.sh)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] ✅ All unit tests passed!"
echo ""
echo "To run CVE audits, Docker builds, and integration tests:"
echo "  ./test-integration.sh"
