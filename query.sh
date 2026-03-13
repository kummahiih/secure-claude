#!/bin/bash
set -e

# 1. Ensure the cluster is actually running and tokens exist
if [ ! -f .cluster_tokens.env ]; then
    echo "[$(date +'%H:%M:%S')] Error: .cluster_tokens.env not found."
    echo "Please start the cluster with ./run.sh first to generate the tokens."
    exit 1
fi

# 2. Load the tokens
source .cluster_tokens.env

# 3. Require a query argument
if [ -z "$1" ]; then
    echo "Usage: ./query.sh local|remote \"Your question here\""
    echo "Example: ./query.sh local \"Can you read the contents of test.txt in my workspace?\""
    exit 1
fi

MODEL=$1
QUERY=$2

echo "[$(date +'%H:%M:%S')] Sending query to secure Claude agent..."

# 4. Execute the authenticated request
curl -s -X POST https://localhost:8443/ask \
    --cacert ./cluster/certs/ca.crt \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $CLAUDE_API_TOKEN" \
    -d "{\"model\": \"$MODEL\",\"query\": \"$QUERY\"}" 

echo "" # Print a final newline for terminal readability