#!/bin/bash
set -euo pipefail

echo "[$(date +'%H:%M:%S')] Starting automated test suite..."

# Generate any missing files via setup
bash ./run.sh --setup-only 

# Provide completely fake tokens so the SDKs and Docker Compose don't crash on boot
export MCP_API_TOKEN="integration-test-mcp-token"
export CLAUDE_API_TOKEN="integration-test-langchain-token"
export ANTHROPIC_API_KEY="dummy-anthropic-key"

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 4/6: Running Dependency Security Scans..."

echo "[+] Scanning Go Fileserver (govulncheck)..."
(cd cluster/fileserver && go run golang.org/x/vuln/cmd/govulncheck@latest ./...)

echo "[+] Scanning Python Agent (pip-audit)..."
# Activates the environment, installs pip-audit, and scans the installed packages
echo "🔍 Auditing Python dependencies..."
(cd cluster && \
    docker run --rm \
    -e PIP_ROOT_USER_ACTION=ignore \
    -v "$(pwd)":/app \
    -w /app \
    python:3.11-slim /bin/bash -c \
    "pip install --quiet --upgrade pip && pip install --quiet pip-audit && pip-audit -r claude/requirements.txt"
)
DOCKERFILES=("Dockerfile.caddy" "Dockerfile.claude" "Dockerfile.mcp" "Dockerfile.proxy")

echo "[+] Lint Dockerfiles (Hadolint)"
for df in "${DOCKERFILES[@]}"; do
    echo "🛡️  Linting $df..."
    docker run --rm -i hadolint/hadolint:v2.12.0 < cluster/"$df"
    if [ $? -eq 0 ]; then echo "✅ $df follows best practices."; else echo "⚠️  Issues found in cluster/$df"; EXIT_CODE=1; fi
done

echo "[+] Scan Docker Compose Configuration (Trivy)"
echo "Scanning docker-compose.yml for misconfigurations..."
(cd cluster && docker run --rm -v "$(pwd)":/app -w /app aquasec/trivy config .)
if [ $? -eq 0 ]; then echo "✅ Infrastructure config looks solid."; else echo "❌ Issues found in Compose file."; EXIT_CODE=1; fi

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 1/6: Validating Caddy Edge Router..."
(bash ./cluster/caddy/caddy_test.sh)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 2/6: Running Golang MCP Server Tests..."
(cd cluster/fileserver && go test mcp_test.go main.go -v)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 3/6: Running Python LangChain Tests..."
(source ./venv/bin/activate && cd cluster/claude && pytest claude_tests.py -v)


echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 5/6: Preparing & Building Containers..."


echo "[$(date +'%H:%M:%S')] Building containers from scratch..."
(cd cluster && docker-compose build)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] 6/6: Running Docker Integration Tests..."

# 7. Launch the stack
(./cluster/start-cluster.sh)

echo "[$(date +'%H:%M:%S')] Waiting for Caddy and FastAPI to initialize (20s)..."
sleep 20

echo "[$(date +'%H:%M:%S')] Pinging the secured public Caddy endpoint..."
# The '|| echo "000"' prevents set -e from killing the script if the connection is refused
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST https://localhost:8443/ask -k \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $CLAUDE_API_TOKEN" \
    -d '{"query": "Hello"}' || echo "000")

if [ "$HTTP_STATUS" -eq 200 ]; then
    echo "[$(date +'%H:%M:%S')] Success! Caddy routed the request. Endpoint returned 200 OK."
else
    echo "[$(date +'%H:%M:%S')] Error: Endpoint returned HTTP $HTTP_STATUS."
    echo "[$(date +'%H:%M:%S')] Dumping container logs for debugging:"
    (cd cluster && docker-compose logs)
    (cd cluster && docker-compose down)
    exit 1
fi

echo "[$(date +'%H:%M:%S')] Tearing down integration containers..."
(cd cluster && docker-compose down)

echo "----------------------------------------"
echo "[$(date +'%H:%M:%S')] All unit, security, and integration tests passed successfully!"
