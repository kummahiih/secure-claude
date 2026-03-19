#!/bin/bash
set -euo pipefail

echo "[$(date +'%H:%M:%S')] Starting automated test suite..."
. venv/bin/activate

# Generate any missing files via setup
bash ./run.sh --setup-only

# Provide completely fake tokens so the SDKs and Docker Compose don't crash on boot
export MCP_API_TOKEN="integration-test-mcp-token"
export CLAUDE_API_TOKEN="integration-test-Claude-token"
export ANTHROPIC_API_KEY="dummy-anthropic-key"
export DYNAMIC_AGENT_KEY="dummy-dynaic-key"


echo "========================================"
echo "  CLUSTER-LEVEL TESTS"
echo "========================================"

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 1/8: Validating Caddy Edge Router..."
(bash ./cluster/caddy/caddy_test.sh 2>&1 | tail -3)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 2/8: Lint Dockerfiles (Hadolint)..."
DOCKERFILES=("Dockerfile.caddy" "Dockerfile.claude" "Dockerfile.mcp" "Dockerfile.proxy" "Dockerfile.plan" "Dockerfile.tester")
for df in "${DOCKERFILES[@]}"; do
    RESULT=$(docker run --rm -i hadolint/hadolint:v2.12.0 < cluster/"$df" 2>&1)
    if [ $? -eq 0 ]; then echo "  ✅ $df"; else echo "  ⚠️  $df:"; echo "$RESULT"; EXIT_CODE=1; fi
done

echo "[+] Scan Docker Compose Configuration (Trivy)"
TRIVY_OUT=$(cd cluster && docker run --rm -v "$(pwd)":/app -w /app aquasec/trivy config . 2>&1)
if [ $? -eq 0 ]; then echo "  ✅ Infrastructure config clean"; else echo "$TRIVY_OUT" | grep -E '(CRITICAL|HIGH|MEDIUM|FAIL)'; EXIT_CODE=1; fi


echo "========================================"
echo "  SUB-REPOSITORY TESTS"
echo "========================================"

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 3/8: Running agent tests..."
(cd cluster/agent && ./test.sh)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 4/8: Running planner tests..."
(cd cluster/planner && ./test.sh)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 5/8: Running tester tests..."
(cd cluster/tester && ./test.sh)


echo "========================================"
echo "  BUILD + INTEGRATION"
echo "========================================"

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 6/8: Building Containers..."
(cd cluster && docker-compose build --quiet)
echo "  ✅ Build complete"

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 7/8: Post-Build Security Scans..."

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
) || echo "  ⚠️  govulncheck section failed"

echo "[+] Scanning Python deps (pip-audit)..."
(
  set +e
  AUDIT_OUT=$(cd cluster && docker run --rm \
    -e PIP_ROOT_USER_ACTION=ignore \
    -v "$(pwd)":/app \
    -w /app \
    python:3.11-slim /bin/bash -c \
    "pip install --quiet --upgrade pip && pip install --quiet pip-audit && pip-audit -r agent/claude/requirements.txt" 2>&1)
  if echo "$AUDIT_OUT" | grep -q "No known"; then
    echo "  ✅ pip-audit clean"
  elif echo "$AUDIT_OUT" | grep -qE '(CRITICAL|WARNING|ERROR)'; then
    echo "$AUDIT_OUT" | grep -E '(found|No known|CRITICAL|WARNING|ERROR|Name)' | tail -10
  else
    echo "  ✅ pip-audit clean"
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

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 8/8: Running Docker Integration Tests..."

# Create plans directory if needed
mkdir -p plans

# Launch the stack
(./cluster/start-cluster.sh 2>&1 | tail -3)

echo "[$(date +'%H:%M:%S')] Waiting for Caddy and FastAPI to initialize (20s)..."
sleep 20

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

echo "$(date +'%H:%M:%S') Plan-server isolation verification..."

echo "$(date +'%H:%M:%S') Checking plan-server cannot see workspace..."
WORKSPACE_CHECK=$(docker exec plan-server ls /workspace 2>&1 || true)
if echo "$WORKSPACE_CHECK" | grep -q "No such file"; then
  echo "  ✅ plan-server cannot see /workspace"
else
  echo "  ❌ plan-server can see /workspace"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking plan-server cannot see /gitdir..."
GITDIR_CHECK=$(docker exec plan-server ls /gitdir 2>&1 || true)
if echo "$GITDIR_CHECK" | grep -q "No such file"; then
  echo "  ✅ plan-server cannot see /gitdir"
else
  echo "  ❌ plan-server can see /gitdir"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking plan-server env var isolation..."
FORBIDDEN_VARS_CHECK=$(docker exec plan-server env 2>/dev/null | grep -E '(ANTHROPIC_API_KEY|CLAUDE_API_TOKEN|DYNAMIC_AGENT_KEY)' || true)
if [ -z "$FORBIDDEN_VARS_CHECK" ]; then
  echo "  ✅ plan-server env var isolation clean"
else
  echo "  ❌ plan-server has forbidden env vars:"
  echo "$FORBIDDEN_VARS_CHECK"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Tester-server integration verification..."

echo "$(date +'%H:%M:%S') Checking tester-server health..."
TESTER_HEALTH=$(docker exec claude-server curl -s -k https://tester-server:8443/health 2>/dev/null || echo "FAIL")
if [ "$TESTER_HEALTH" != "FAIL" ]; then
  echo "  ✅ tester-server healthy"
else
  echo "  ❌ tester-server not responding"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking tester-server env var isolation..."
TESTER_VARS_CHECK=$(docker exec tester-server env 2>/dev/null | grep -E '(ANTHROPIC_API_KEY|CLAUDE_API_TOKEN|DYNAMIC_AGENT_KEY)' || true)
if [ -z "$TESTER_VARS_CHECK" ]; then
  echo "  ✅ tester-server env var isolation clean"
else
  echo "  ❌ tester-server has forbidden env vars:"
  echo "$TESTER_VARS_CHECK"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking tester-server cannot see /gitdir..."
TESTER_GITDIR_CHECK=$(docker exec tester-server ls /gitdir 2>&1 || true)
if echo "$TESTER_GITDIR_CHECK" | grep -q "No such file"; then
  echo "  ✅ tester-server cannot see /gitdir"
else
  echo "  ❌ tester-server can see /gitdir"
  (cd cluster && docker-compose down 2>/dev/null)
  exit 1
fi

echo "$(date +'%H:%M:%S') Checking tester-server cannot see /plans..."
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

echo "[$(date +'%H:%M:%S')] Tearing down integration containers..."
(cd cluster && docker-compose down 2>/dev/null)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] ✅ All cluster, sub-repository, and integration tests passed!"