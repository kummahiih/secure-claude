#!/bin/bash
set -e

echo "[$(date +'%H:%M:%S')] Starting cluster initialization..."

# 1. Load Secrets
if [ -f .secrets.env ]; then
    echo "[$(date +'%H:%M:%S')] Loading secrets from .secrets.env..."
    # We use 'allexport' to make sure these are available for the key validation loop
    set -a
    source .secrets.env
    set +a
else
    echo "[$(date +'%H:%M:%S')] Error: .secrets.env not found."
    exit 1
fi

# 2. Validate Keys
REQUIRED_KEYS=("ANTHROPIC_API_KEY" "HOST_DOMAIN")
for key in "${REQUIRED_KEYS[@]}"; do
    if [ -z "${!key}" ]; then
        echo "[$(date +'%H:%M:%S')] Error: $key is not set in .secrets.env."
        exit 1
    fi
done

if ! echo "$HOST_DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$'; then
    echo "[$(date +'%H:%M:%S')] Error: HOST_DOMAIN '$HOST_DOMAIN' is not a valid domain name."
    exit 1
fi

# 3. Generate and Save Secure API Tokens
echo "[$(date +'%H:%M:%S')] Cleaning up old token files..."
rm -f .env .cluster_tokens.env

echo "[$(date +'%H:%M:%S')] Generating fresh cluster tokens..."
export DYNAMIC_AGENT_KEY="sk-$(openssl rand -hex 16)"
export MCP_API_TOKEN=$(openssl rand -hex 32)
export PLAN_API_TOKEN=$(openssl rand -hex 32)
export TESTER_API_TOKEN=$(openssl rand -hex 32)
export CLAUDE_API_TOKEN=$(openssl rand -hex 32)
export GIT_API_TOKEN=$(openssl rand -hex 32)
export LOG_API_TOKEN=$(openssl rand -hex 32)
export CODEX_API_TOKEN=$(openssl rand -hex 32)

# Create the standard .env file for Docker Compose
{
    echo "DYNAMIC_AGENT_KEY=$DYNAMIC_AGENT_KEY"
    echo "MCP_API_TOKEN=$MCP_API_TOKEN"
    echo "PLAN_API_TOKEN=$PLAN_API_TOKEN"
    echo "TESTER_API_TOKEN=$TESTER_API_TOKEN"
    echo "CLAUDE_API_TOKEN=$CLAUDE_API_TOKEN"
    echo "GIT_API_TOKEN=$GIT_API_TOKEN"
    echo "LOG_API_TOKEN=$LOG_API_TOKEN"
    echo "CODEX_API_TOKEN=$CODEX_API_TOKEN"
} > .env

# Also keep the export-style file for query.sh compatibility
{
    echo "export DYNAMIC_AGENT_KEY=\"$DYNAMIC_AGENT_KEY\""
    echo "export MCP_API_TOKEN=\"$MCP_API_TOKEN\""
    echo "export PLAN_API_TOKEN=\"$PLAN_API_TOKEN\""
    echo "export TESTER_API_TOKEN=\"$TESTER_API_TOKEN\""
    echo "export CLAUDE_API_TOKEN=\"$CLAUDE_API_TOKEN\""
    echo "export GIT_API_TOKEN=\"$GIT_API_TOKEN\""
    echo "export LOG_API_TOKEN=\"$LOG_API_TOKEN\""
    echo "export CODEX_API_TOKEN=\"$CODEX_API_TOKEN\""
} > .cluster_tokens.env

# Ensure directories exist
mkdir -p cluster/certs cluster/workspace cluster/logs

# 4. Generate the Root Certificate Authority (CA)
if [ ! -f cluster/certs/ca.crt ]; then
    echo "[$(date +'%H:%M:%S')] Generating Root CA..."
    openssl genrsa -out cluster/certs/ca.key 4096

    # CA must declare basicConstraints and keyUsage extensions.
    # OpenSSL 3.x (Python/aiohttp) rejects CA certs without keyUsage: keyCertSign.
    openssl req -x509 -new -nodes -key cluster/certs/ca.key -sha256 -days 3650 \
        -out cluster/certs/ca.crt \
        -subj "/C=FI/ST=Uusimaa/L=Espoo/O=LocalCluster/CN=ClusterRootCA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "subjectKeyIdentifier=hash"
fi


# 6. Prepare mounted directories
echo "[$(date +'%H:%M:%S')] Setting strict local directory permissions..."

# 750: You can do all, Group can read/enter, Others are completely blocked.
chmod 750 cluster/certs cluster/workspace

# 640: You can read/write, Group can read, Others get NOTHING.
chmod 640 cluster/certs/*


# --- NEW: Check for setup-only flag ---
if [[ "$1" == "--setup-only" ]]; then
    echo "[$(date +'%H:%M:%S')] Setup complete. Exiting due to --setup-only flag."
    exit 0
fi

# 7. Launch the stack
(./cluster/start-cluster.sh)