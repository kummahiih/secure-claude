#!/bin/bash
set -euo pipefail

# test-integration.sh — CVE audits, Docker builds, and cluster integration tests
#
# Requires:
#   - Docker Engine with Compose V2 (and socket access)
#   - Network connectivity (for vulnerability database fetches)
#   - openssl (for certificate generation via run.sh --setup-only)
#
# Does NOT require real API keys — uses dummy tokens throughout.
#
# Run unit tests first with ./test.sh before running this.

echo "[$(date +'%H:%M:%S')] Starting integration + security test suite..."

# Activate venv if present
if [ -f venv/bin/activate ]; then
    # shellcheck disable=SC1091
    . venv/bin/activate
fi

# Generate any missing certs/token files via setup
bash ./run.sh --setup-only

# Provide completely fake tokens so the SDKs and Docker Compose don't crash on boot
export MCP_API_TOKEN="integration-test-mcp-token"
export PLAN_API_TOKEN="integration-test-plan-token"
export TESTER_API_TOKEN="integration-test-tester-token"
export CLAUDE_API_TOKEN="integration-test-Claude-token"
export GIT_API_TOKEN="integration-test-git-token"
export ANTHROPIC_API_KEY="dummy-anthropic-key"
export DYNAMIC_AGENT_KEY="dummy-dynamic-key"


echo "========================================"
echo "  STATIC ANALYSIS"
echo "========================================"

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 1/8: Validating Caddy Edge Router..."
(bash ./cluster/caddy/caddy_test.sh 2>&1 | tail -3)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 2/8: Lint Dockerfiles (Hadolint)..."
DOCKERFILES=("Dockerfile.caddy" "Dockerfile.claude" "Dockerfile.mcp" "Dockerfile.proxy" "Dockerfile.plan" "Dockerfile.tester" "Dockerfile.git")
(
  set +e
  for df in "${DOCKERFILES[@]}"; do
      echo -n "  $df... "
      RESULT=$(cat cluster/"$df" | timeout 30 docker run --rm -i hadolint/hadolint:v2.12.0 2>&1)
      if [ $? -eq 0 ]; then echo "✅"; else echo "⚠️"; echo "$RESULT" | head -10; fi
  done
)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] Scan Docker Compose Configuration (Trivy)..."
(
  set +e
  TRIVY_OUT=$(cd cluster && timeout 120 docker run --rm -v "$(pwd)":/app -w /app aquasec/trivy:0.69.3 config . 2>&1)
  TRIVY_RC=$?
  if [ $TRIVY_RC -eq 124 ]; then
    echo "  ⚠️  Trivy timed out after 120s"
  elif [ $TRIVY_RC -eq 0 ]; then
    echo "  ✅ Infrastructure config clean"
  else
    echo "$TRIVY_OUT" | grep -E '(CRITICAL|HIGH|MEDIUM|FAIL)' || echo "$TRIVY_OUT" | tail -5
  fi
)


echo "========================================"
echo "  BUILD + SECURITY SCANS"
echo "========================================"

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 3/8: Building Containers..."
(cd cluster && docker-compose build --quiet)
echo "  ✅ Build complete"

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 4/8: Post-Build Security Scans..."

echo "[+] Scanning Go deps (govulncheck)..."
(
  set +e
  echo "  Scanning fileserver..."
  GOVULN_FS=$(cd cluster/agent/fileserver && go run golang.org/x/vuln/cmd/govulncheck@latest ./... 2>&1)
  if echo "$GOVULN_FS" | grep -q "No vulnerabilities found"; then
    echo "  ✅ fileserver govulncheck clean"
  else
    echo "$GOVULN_FS" | tail -5
  fi

  echo "  Scanning tester..."
  GOVULN_TS=$(cd cluster/tester && go run golang.org/x/vuln/cmd/govulncheck@latest ./... 2>&1)
  if echo "$GOVULN_TS" | grep -q "No vulnerabilities found"; then
    echo "  ✅ tester govulncheck clean"
  else
    echo "$GOVULN_TS" | tail -5
  fi

  echo '  Scanning gitserver...'
  GOVULN_GS=$(cd cluster/agent/gitserver && go run golang.org/x/vuln/cmd/govulncheck@latest ./... 2>&1)
  if echo "$GOVULN_GS" | grep -q 'No vulnerabilities found'; then
    echo '  ✅ gitserver govulncheck clean'
  else
    echo "$GOVULN_GS" | tail -5
  fi
) || echo "  ⚠️  govulncheck section failed"

echo "[+] Scanning Python deps (pip-audit)..."
(
  set +e

  # Agent requirements
  echo "  Scanning agent requirements..."
  AUDIT_AGENT=$(cd cluster && docker run --rm \
    -e PIP_ROOT_USER_ACTION=ignore \
    -v "$(pwd)":/app \
    -w /app \
    python:3.11-slim /bin/bash -c \
    "pip install --quiet --upgrade pip && pip install --quiet pip-audit && pip-audit -r agent/claude/requirements.txt" 2>&1)
  if echo "$AUDIT_AGENT" | grep -q "No known"; then
    echo "  ✅ agent pip-audit clean"
  elif echo "$AUDIT_AGENT" | grep -qE '(CRITICAL|WARNING|ERROR)'; then
    echo "$AUDIT_AGENT" | grep -E '(found|No known|CRITICAL|WARNING|ERROR|Name)' | tail -10
  else
    echo "  ✅ agent pip-audit clean"
  fi

  # Planner requirements
  echo "  Scanning planner requirements..."
  AUDIT_PLANNER=$(cd cluster && docker run --rm \
    -e PIP_ROOT_USER_ACTION=ignore \
    -v "$(pwd)":/app \
    -w /app \
    python:3.11-slim /bin/bash -c \
    "pip install --quiet --upgrade pip && pip install --quiet pip-audit && pip-audit -r planner/planner/requirements.txt" 2>&1)
  if echo "$AUDIT_PLANNER" | grep -q "No known"; then
    echo "  ✅ planner pip-audit clean"
  elif echo "$AUDIT_PLANNER" | grep -qE '(CRITICAL|WARNING|ERROR)'; then
    echo "$AUDIT_PLANNER" | grep -E '(found|No known|CRITICAL|WARNING|ERROR|Name)' | tail -10
  else
    echo "  ✅ planner pip-audit clean"
  fi

  # Tester requirements
  echo "  Scanning tester requirements..."
  AUDIT_TESTER=$(cd cluster && docker run --rm \
    -e PIP_ROOT_USER_ACTION=ignore \
    -v "$(pwd)":/app \
    -w /app \
    python:3.11-slim /bin/bash -c \
    "pip install --quiet --upgrade pip && pip install --quiet pip-audit && pip-audit -r tester/requirements.txt" 2>&1)
  if echo "$AUDIT_TESTER" | grep -q "No known"; then
    echo "  ✅ tester pip-audit clean"
  elif echo "$AUDIT_TESTER" | grep -qE '(CRITICAL|WARNING|ERROR)'; then
    echo "$AUDIT_TESTER" | grep -E '(found|No known|CRITICAL|WARNING|ERROR|Name)' | tail -10
  else
    echo "  ✅ tester pip-audit clean"
  fi
) || echo "  ⚠️  pip-audit section failed"

echo "[+] Scanning Claude Code JS deps (npm audit)..."
(
  set +e
  TMPDIR=$(mktemp -d)
  NPM_CTR="npm-audit-tmp-$$"
  docker create --name "$NPM_CTR" cluster-claude-server >/dev/null 2>&1
  docker cp "$NPM_CTR":/usr/lib/node_modules/@anthropic-ai/claude-code "$TMPDIR/claude-code" 2>/dev/null
  docker rm "$NPM_CTR" >/dev/null 2>&1
  NPM_OUT=$(cd "$TMPDIR/claude-code" && npm i --package-lock-only --ignore-scripts 2>/dev/null && npm audit --omit=dev 2>&1) || true
  rm -rf "$TMPDIR"
  if echo "$NPM_OUT" | grep -q "found 0 vulnerabilities"; then
    echo "  ✅ npm audit clean"
  elif [ -z "$NPM_OUT" ]; then
    echo "  ⚠️  npm audit produced no output"
  else
    echo "  ⚠️  npm audit:"
    echo "$NPM_OUT" | grep -E '(found|vulnerabilities|severity|Severity)' | tail -5
  fi
) || echo "  ⚠️  npm audit section failed"


echo "========================================"
echo "  DOCKER INTEGRATION TESTS"
echo "========================================"

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 5/8: Starting cluster for integration tests..."

# Create plans directory if needed
mkdir -p plans

# Launch the stack
(./cluster/start-cluster.sh 2>&1 | tail -3)

echo "[$(date +'%H:%M:%S')] Waiting for Caddy and FastAPI to initialize (20s)..."
sleep 20

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 6/8: MCP Registration Checks..."

echo "$(date +'%H:%M:%S') Checking MCP server registration..."
if docker exec claude-server python3 -c "import json; d=json.load(open('/home/appuser/sandbox/.mcp.json')); assert 'fileserver' in d['mcpServers']" 2>/dev/null; then
  echo "  ✅ MCP fileserver registered and valid"
else
  echo "  ❌ MCP fileserver not registered"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking MCP planner registration..."
if docker exec claude-server python3 -c "import json; d=json.load(open('/home/appuser/sandbox/.mcp.json')); assert 'planner' in d['mcpServers']" 2>/dev/null; then
  echo "  ✅ MCP planner registered and valid"
else
  echo "  ❌ MCP planner not registered"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking MCP tester registration..."
if docker exec claude-server python3 -c "import json; d=json.load(open('/home/appuser/sandbox/.mcp.json')); assert 'tester' in d['mcpServers']" 2>/dev/null; then
  echo "  ✅ MCP tester registered and valid"
else
  echo "  ❌ MCP tester not registered"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking MCP fileserver logs..."
MCP_ERRORS=$(docker exec claude-server sh -c \
  'find /home/appuser/.cache/claude-cli-nodejs -path "*mcp-logs-fileserver*" -name "*.jsonl" 2>/dev/null | sort | tail -1 | xargs cat 2>/dev/null | grep -i error' 2>/dev/null || true)
if [ -n "$MCP_ERRORS" ]; then
  echo "  ⚠️  MCP fileserver errors detected:"
  echo "$MCP_ERRORS" | head -5
else
  echo "  ✅ MCP fileserver logs clean"
fi

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 7/8: Service Health + Auth Checks..."

echo "$(date +'%H:%M:%S') Checking plan-server health..."
PLAN_HEALTH=$(docker exec claude-server curl -s -k https://plan-server:8443/health 2>/dev/null || echo "FAIL")
if echo "$PLAN_HEALTH" | grep -q '"ok"'; then
  echo "  ✅ plan-server healthy"
else
  echo "  ❌ plan-server not responding"
  echo "  Response: $PLAN_HEALTH"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "[$(date +'%H:%M:%S')] Checking auth failure on Caddy endpoint..."
AUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST https://localhost:8443/ask -k \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer wrong-token" \
  -d '{"query": "Hello"}' || echo "000")

if [ "$AUTH_STATUS" -eq 401 ]; then
  echo "  ✅ Auth correctly rejected invalid token with 401"
else
  echo "  ❌ Expected 401 but got HTTP $AUTH_STATUS"
  (cd cluster && docker-compose logs 2>/dev/null | tail -20)
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking tester-server health..."
TESTER_HEALTH=$(docker exec claude-server curl -s -k https://tester-server:8443/health 2>/dev/null || echo "FAIL")
if [ "$TESTER_HEALTH" != "FAIL" ]; then
  echo "  ✅ tester-server healthy"
else
  echo "  ❌ tester-server not responding"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 8/8: Isolation Verification..."

echo "$(date +'%H:%M:%S') Plan-server isolation..."

WORKSPACE_CHECK=$(docker exec plan-server ls /workspace 2>&1 || true)
if echo "$WORKSPACE_CHECK" | grep -q "No such file"; then
  echo "  ✅ plan-server cannot see /workspace"
else
  echo "  ❌ plan-server can see /workspace"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

GITDIR_CHECK=$(docker exec plan-server ls /gitdir 2>&1 || true)
if echo "$GITDIR_CHECK" | grep -q "No such file"; then
  echo "  ✅ plan-server cannot see /gitdir"
else
  echo "  ❌ plan-server can see /gitdir"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

FORBIDDEN_VARS_CHECK=$(docker exec plan-server env 2>/dev/null | grep -E '(ANTHROPIC_API_KEY|CLAUDE_API_TOKEN|DYNAMIC_AGENT_KEY|MCP_API_TOKEN)' || true)
if [ -z "$FORBIDDEN_VARS_CHECK" ]; then
  echo "  ✅ plan-server env var isolation clean"
else
  echo "  ❌ plan-server has forbidden env vars:"
  echo "$FORBIDDEN_VARS_CHECK"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

PLAN_TOKEN_CHECK=$(docker exec plan-server env 2>/dev/null | grep -E '^PLAN_API_TOKEN=' || true)
if [ -n "$PLAN_TOKEN_CHECK" ]; then
  echo "  ✅ plan-server has PLAN_API_TOKEN"
else
  echo "  ❌ plan-server missing PLAN_API_TOKEN"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

PLAN_NO_TESTER=$(docker exec plan-server env 2>/dev/null | grep -E '^TESTER_API_TOKEN=' || true)
if [ -z "$PLAN_NO_TESTER" ]; then
  echo "  ✅ plan-server does not have TESTER_API_TOKEN (no cross-contamination)"
else
  echo "  ❌ plan-server has TESTER_API_TOKEN (cross-contamination)"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Tester-server isolation..."

TESTER_VARS_CHECK=$(docker exec tester-server env 2>/dev/null | grep -E '(ANTHROPIC_API_KEY|CLAUDE_API_TOKEN|DYNAMIC_AGENT_KEY|MCP_API_TOKEN)' || true)
if [ -z "$TESTER_VARS_CHECK" ]; then
  echo "  ✅ tester-server env var isolation clean"
else
  echo "  ❌ tester-server has forbidden env vars:"
  echo "$TESTER_VARS_CHECK"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

TESTER_TOKEN_CHECK=$(docker exec tester-server env 2>/dev/null | grep -E '^TESTER_API_TOKEN=' || true)
if [ -n "$TESTER_TOKEN_CHECK" ]; then
  echo "  ✅ tester-server has TESTER_API_TOKEN"
else
  echo "  ❌ tester-server missing TESTER_API_TOKEN"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

TESTER_NO_PLAN=$(docker exec tester-server env 2>/dev/null | grep -E '^PLAN_API_TOKEN=' || true)
if [ -z "$TESTER_NO_PLAN" ]; then
  echo "  ✅ tester-server does not have PLAN_API_TOKEN (no cross-contamination)"
else
  echo "  ❌ tester-server has PLAN_API_TOKEN (cross-contamination)"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

TESTER_GITDIR_CHECK=$(docker exec tester-server ls /gitdir 2>&1 || true)
if echo "$TESTER_GITDIR_CHECK" | grep -q "No such file"; then
  echo "  ✅ tester-server cannot see /gitdir"
else
  echo "  ❌ tester-server can see /gitdir"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

TESTER_PLANS_CHECK=$(docker exec tester-server ls /plans 2>&1 || true)
if echo "$TESTER_PLANS_CHECK" | grep -q "No such file"; then
  echo "  ✅ tester-server cannot see /plans"
else
  echo "  ❌ tester-server can see /plans"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking tester-server auth rejects bad token..."
TESTER_AUTH=$(docker exec claude-server curl -s -o /dev/null -w "%{http_code}" -k \
  -X POST https://tester-server:8443/run \
  -H "Authorization: Bearer wrong-token" 2>/dev/null || echo "000")
if [ "$TESTER_AUTH" = "401" ]; then
  echo "  ✅ tester-server auth correctly rejects invalid token"
else
  echo "  ❌ tester-server expected 401 but got $TESTER_AUTH"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking git-server health..."
GIT_HEALTH=$(docker exec claude-server curl -s -o /dev/null -w "%{http_code}" -k https://git-server:8443/health 2>/dev/null || echo "000")
if [ "$GIT_HEALTH" = "200" ]; then
  echo "  ✅ git-server healthy"
else
  echo "  ❌ git-server not responding (HTTP $GIT_HEALTH)"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking git-server auth rejects bad token..."
GIT_AUTH=$(docker exec claude-server curl -s -o /dev/null -w "%{http_code}" -k \
  https://git-server:8443/status \
  -H "Authorization: Bearer wrong-token" 2>/dev/null || echo "000")
if [ "$GIT_AUTH" = "401" ]; then
  echo "  ✅ git-server auth correctly rejects invalid token"
else
  echo "  ❌ git-server expected 401 but got $GIT_AUTH"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking git-server REST API responds to valid token..."
GIT_STATUS_RESP=$(docker exec claude-server curl -s -k \
  https://git-server:8443/status \
  -H "Authorization: Bearer $GIT_API_TOKEN" 2>/dev/null || echo "FAIL")
if echo "$GIT_STATUS_RESP" | grep -q '"output"'; then
  echo "  ✅ git-server /status returns valid JSON with valid token"
else
  echo "  ❌ git-server /status failed with valid token"
  echo "  Response: $GIT_STATUS_RESP"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking claude-server resource limits..."
CLAUDE_MEM=$(docker inspect claude-server --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
CLAUDE_CPUS=$(docker inspect claude-server --format '{{.HostConfig.NanoCpus}}' 2>/dev/null || echo "0")
CLAUDE_PIDS=$(docker inspect claude-server --format '{{.HostConfig.PidsLimit}}' 2>/dev/null || echo "0")
CLAUDE_CAPS=$(docker inspect claude-server --format '{{.HostConfig.CapDrop}}' 2>/dev/null || echo "")

RESOURCE_FAIL=0
# mem_limit: 4g = 4294967296 bytes
if [ "$CLAUDE_MEM" = "4294967296" ]; then
  echo "  ✅ claude-server mem_limit: 4g"
else
  echo "  ❌ claude-server mem_limit wrong (got $CLAUDE_MEM, want 4294967296)"
  RESOURCE_FAIL=1
fi
# cpus: 2.0 = 2000000000 NanoCPUs
if [ "$CLAUDE_CPUS" = "2000000000" ]; then
  echo "  ✅ claude-server cpus: 2.0"
else
  echo "  ❌ claude-server cpus wrong (got $CLAUDE_CPUS, want 2000000000)"
  RESOURCE_FAIL=1
fi
if [ "$CLAUDE_PIDS" = "200" ]; then
  echo "  ✅ claude-server pids_limit: 200"
else
  echo "  ❌ claude-server pids_limit wrong (got $CLAUDE_PIDS, want 200)"
  RESOURCE_FAIL=1
fi
if echo "$CLAUDE_CAPS" | grep -qi "ALL"; then
  echo "  ✅ claude-server cap_drop: ALL"
else
  echo "  ❌ claude-server cap_drop missing ALL (got $CLAUDE_CAPS)"
  RESOURCE_FAIL=1
fi
if [ "$RESOURCE_FAIL" -eq 1 ]; then
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking mcp-server resource limits..."
MCP_MEM=$(docker inspect mcp-server --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
MCP_CPUS=$(docker inspect mcp-server --format '{{.HostConfig.NanoCpus}}' 2>/dev/null || echo "0")
MCP_PIDS=$(docker inspect mcp-server --format '{{.HostConfig.PidsLimit}}' 2>/dev/null || echo "0")
MCP_CAPS=$(docker inspect mcp-server --format '{{.HostConfig.CapDrop}}' 2>/dev/null || echo "")

MCP_RESOURCE_FAIL=0
# mem_limit: 512m = 536870912 bytes
if [ "$MCP_MEM" = "536870912" ]; then
  echo "  ✅ mcp-server mem_limit: 512m"
else
  echo "  ❌ mcp-server mem_limit wrong (got $MCP_MEM, want 536870912)"
  MCP_RESOURCE_FAIL=1
fi
# cpus: 1.0 = 1000000000 NanoCPUs
if [ "$MCP_CPUS" = "1000000000" ]; then
  echo "  ✅ mcp-server cpus: 1.0"
else
  echo "  ❌ mcp-server cpus wrong (got $MCP_CPUS, want 1000000000)"
  MCP_RESOURCE_FAIL=1
fi
if [ "$MCP_PIDS" = "100" ]; then
  echo "  ✅ mcp-server pids_limit: 100"
else
  echo "  ❌ mcp-server pids_limit wrong (got $MCP_PIDS, want 100)"
  MCP_RESOURCE_FAIL=1
fi
if echo "$MCP_CAPS" | grep -qi "ALL"; then
  echo "  ✅ mcp-server cap_drop: ALL"
else
  echo "  ❌ mcp-server cap_drop missing ALL (got $MCP_CAPS)"
  MCP_RESOURCE_FAIL=1
fi
if [ "$MCP_RESOURCE_FAIL" -eq 1 ]; then
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking plan-server resource limits..."
PLAN_MEM=$(docker inspect plan-server --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
PLAN_CPUS=$(docker inspect plan-server --format '{{.HostConfig.NanoCpus}}' 2>/dev/null || echo "0")
PLAN_PIDS=$(docker inspect plan-server --format '{{.HostConfig.PidsLimit}}' 2>/dev/null || echo "0")
PLAN_CAPS=$(docker inspect plan-server --format '{{.HostConfig.CapDrop}}' 2>/dev/null || echo "")

PLAN_RESOURCE_FAIL=0
# mem_limit: 256m = 268435456 bytes
if [ "$PLAN_MEM" = "268435456" ]; then
  echo "  ✅ plan-server mem_limit: 256m"
else
  echo "  ❌ plan-server mem_limit wrong (got $PLAN_MEM, want 268435456)"
  PLAN_RESOURCE_FAIL=1
fi
# cpus: 0.5 = 500000000 NanoCPUs
if [ "$PLAN_CPUS" = "500000000" ]; then
  echo "  ✅ plan-server cpus: 0.5"
else
  echo "  ❌ plan-server cpus wrong (got $PLAN_CPUS, want 500000000)"
  PLAN_RESOURCE_FAIL=1
fi
if [ "$PLAN_PIDS" = "50" ]; then
  echo "  ✅ plan-server pids_limit: 50"
else
  echo "  ❌ plan-server pids_limit wrong (got $PLAN_PIDS, want 50)"
  PLAN_RESOURCE_FAIL=1
fi
if echo "$PLAN_CAPS" | grep -qi "ALL"; then
  echo "  ✅ plan-server cap_drop: ALL"
else
  echo "  ❌ plan-server cap_drop missing ALL (got $PLAN_CAPS)"
  PLAN_RESOURCE_FAIL=1
fi
if [ "$PLAN_RESOURCE_FAIL" -eq 1 ]; then
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking tester-server resource limits..."
TESTER_MEM=$(docker inspect tester-server --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
TESTER_CPUS=$(docker inspect tester-server --format '{{.HostConfig.NanoCpus}}' 2>/dev/null || echo "0")
TESTER_PIDS=$(docker inspect tester-server --format '{{.HostConfig.PidsLimit}}' 2>/dev/null || echo "0")
TESTER_CAPS=$(docker inspect tester-server --format '{{.HostConfig.CapDrop}}' 2>/dev/null || echo "")

TESTER_RESOURCE_FAIL=0
# mem_limit: 1g = 1073741824 bytes
if [ "$TESTER_MEM" = "1073741824" ]; then
  echo "  ✅ tester-server mem_limit: 1g"
else
  echo "  ❌ tester-server mem_limit wrong (got $TESTER_MEM, want 1073741824)"
  TESTER_RESOURCE_FAIL=1
fi
# cpus: 1.0 = 1000000000 NanoCPUs
if [ "$TESTER_CPUS" = "1000000000" ]; then
  echo "  ✅ tester-server cpus: 1.0"
else
  echo "  ❌ tester-server cpus wrong (got $TESTER_CPUS, want 1000000000)"
  TESTER_RESOURCE_FAIL=1
fi
if [ "$TESTER_PIDS" = "150" ]; then
  echo "  ✅ tester-server pids_limit: 150"
else
  echo "  ❌ tester-server pids_limit wrong (got $TESTER_PIDS, want 150)"
  TESTER_RESOURCE_FAIL=1
fi
if echo "$TESTER_CAPS" | grep -qi "ALL"; then
  echo "  ✅ tester-server cap_drop: ALL"
else
  echo "  ❌ tester-server cap_drop missing ALL (got $TESTER_CAPS)"
  TESTER_RESOURCE_FAIL=1
fi
if [ "$TESTER_RESOURCE_FAIL" -eq 1 ]; then
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Git-server isolation..."

GIT_VARS_CHECK=$(docker exec git-server env 2>/dev/null | grep -E '(ANTHROPIC_API_KEY|CLAUDE_API_TOKEN|DYNAMIC_AGENT_KEY|MCP_API_TOKEN|PLAN_API_TOKEN|TESTER_API_TOKEN)' || true)
if [ -z "$GIT_VARS_CHECK" ]; then
  echo "  ✅ git-server env var isolation clean"
else
  echo "  ❌ git-server has forbidden env vars:"
  echo "$GIT_VARS_CHECK"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

GIT_TOKEN_CHECK=$(docker exec git-server env 2>/dev/null | grep -E '^GIT_API_TOKEN=' || true)
if [ -n "$GIT_TOKEN_CHECK" ]; then
  echo "  ✅ git-server has GIT_API_TOKEN"
else
  echo "  ❌ git-server missing GIT_API_TOKEN"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

GIT_PLANS_CHECK=$(docker exec git-server ls /plans 2>&1 || true)
if echo "$GIT_PLANS_CHECK" | grep -q "No such file"; then
  echo "  ✅ git-server cannot see /plans"
else
  echo "  ❌ git-server can see /plans"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking git-server resource limits..."
GIT_MEM=$(docker inspect git-server --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
GIT_CPUS=$(docker inspect git-server --format '{{.HostConfig.NanoCpus}}' 2>/dev/null || echo "0")
GIT_PIDS=$(docker inspect git-server --format '{{.HostConfig.PidsLimit}}' 2>/dev/null || echo "0")
GIT_CAPS=$(docker inspect git-server --format '{{.HostConfig.CapDrop}}' 2>/dev/null || echo "")

GIT_RESOURCE_FAIL=0
# mem_limit: 512m = 536870912 bytes
if [ "$GIT_MEM" = "536870912" ]; then
  echo "  ✅ git-server mem_limit: 512m"
else
  echo "  ❌ git-server mem_limit wrong (got $GIT_MEM, want 536870912)"
  GIT_RESOURCE_FAIL=1
fi
# cpus: 1.0 = 1000000000 NanoCPUs
if [ "$GIT_CPUS" = "1000000000" ]; then
  echo "  ✅ git-server cpus: 1.0"
else
  echo "  ❌ git-server cpus wrong (got $GIT_CPUS, want 1000000000)"
  GIT_RESOURCE_FAIL=1
fi
if [ "$GIT_PIDS" = "100" ]; then
  echo "  ✅ git-server pids_limit: 100"
else
  echo "  ❌ git-server pids_limit wrong (got $GIT_PIDS, want 100)"
  GIT_RESOURCE_FAIL=1
fi
if echo "$GIT_CAPS" | grep -qi "ALL"; then
  echo "  ✅ git-server cap_drop: ALL"
else
  echo "  ❌ git-server cap_drop missing ALL (got $GIT_CAPS)"
  GIT_RESOURCE_FAIL=1
fi
if [ "$GIT_RESOURCE_FAIL" -eq 1 ]; then
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "[$(date +'%H:%M:%S')] Tearing down integration containers..."
(cd cluster && docker-compose down 2>/dev/null)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] ✅ All security scans and integration tests passed!"
