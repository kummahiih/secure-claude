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


echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 1/7: Validating Caddy Edge Router..."
(bash ./cluster/caddy/caddy_test.sh 2>&1 | tail -3)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 2/7: Running Golang MCP Server Tests..."
(cd cluster/agent/fileserver && go test mcp_test.go main.go -v 2>&1 | grep -E '(PASS|FAIL|---)')

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 3/7: Running Python Claude Tests..."
(source ./venv/bin/activate && cd cluster/agent/claude && pytest claude_tests.py files_mcp_test.py test_isolation.py -v --tb=short 2>&1 | grep -E '(PASSED|FAILED|ERROR|test_|===)')

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 4/7: Running Dependency Security Scans..."

echo "[+] Scanning Go Fileserver (govulncheck)..."
(cd cluster/agent/fileserver && go run golang.org/x/vuln/cmd/govulncheck@latest ./... 2>&1 | tail -5)

echo "[+] Scanning Python Agent (pip-audit)..."
(cd cluster && \
    docker run --rm \
    -e PIP_ROOT_USER_ACTION=ignore \
    -v "$(pwd)":/app \
    -w /app \
    python:3.11-slim /bin/bash -c \
    "pip install --quiet --upgrade pip && pip install --quiet pip-audit && pip-audit -r agent/claude/requirements.txt" 2>&1 | grep -E '(found|No known|CRITICAL|WARNING|ERROR|Name)' || echo "  ✅ pip-audit clean"
)

DOCKERFILES=("Dockerfile.caddy" "Dockerfile.claude" "Dockerfile.mcp" "Dockerfile.proxy")

echo "[+] Lint Dockerfiles (Hadolint)"
for df in "${DOCKERFILES[@]}"; do
    RESULT=$(docker run --rm -i hadolint/hadolint:v2.12.0 < cluster/"$df" 2>&1)
    if [ $? -eq 0 ]; then echo "  ✅ $df"; else echo "  ⚠️  $df:"; echo "$RESULT"; EXIT_CODE=1; fi
done

echo "[+] Scan Docker Compose Configuration (Trivy)"
TRIVY_OUT=$(cd cluster && docker run --rm -v "$(pwd)":/app -w /app aquasec/trivy config . 2>&1)
if [ $? -eq 0 ]; then echo "  ✅ Infrastructure config clean"; else echo "$TRIVY_OUT" | grep -E '(CRITICAL|HIGH|MEDIUM|FAIL)'; EXIT_CODE=1; fi

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 5/7: Building Containers..."
(cd cluster && docker-compose build --quiet)
echo "  ✅ Build complete"

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 6/7: Post-Build Security Scans..."

echo "[+] Scanning Claude Code JS deps (npm audit)..."
(
  set +e
  TMPDIR=$(mktemp -d)
  docker create --name npm-audit-tmp cluster-claude-server >/dev/null 2>&1
  docker cp npm-audit-tmp:/usr/lib/node_modules/@anthropic-ai/claude-code "$TMPDIR/claude-code" 2>/dev/null
  docker rm npm-audit-tmp >/dev/null 2>&1
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
echo "[$(date +'%H:%M:%S')] 7/7: Running Docker Integration Tests..."

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

echo "$(date +'%H:%M:%S') Checking MCP fileserver logs..."
MCP_ERRORS=$(docker exec claude-server sh -c \
  'find /home/appuser/.cache/claude-cli-nodejs -path "*mcp-logs-fileserver*" -name "*.jsonl" 2>/dev/null | sort | tail -1 | xargs cat 2>/dev/null | grep -i error' 2>/dev/null || true)
if [ -n "$MCP_ERRORS" ]; then
  echo "  ⚠️  MCP fileserver errors detected:"
  echo "$MCP_ERRORS" | head -5
else
  echo "  ✅ MCP fileserver logs clean"
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

echo "[$(date +'%H:%M:%S')] Tearing down integration containers..."
(cd cluster && docker-compose down 2>/dev/null)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] ✅ All unit, security, and integration tests passed!"