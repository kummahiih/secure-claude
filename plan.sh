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
  echo "Usage: ./plan.sh model \"Describe what you want to build\""
  echo "  Example: ./plan.sh claude-sonnet-4-6 \"add input validation to the read endpoint\""
  echo ""
  echo "This creates a plan without writing code. Review with: cat plans/*.json | python3 -m json.tool"
  exit 1
fi

MODEL=$1
QUERY=$2

echo "[$(date +'%H:%M:%S')] Sending planning query to secure Claude agent..."

# 4. Execute the authenticated request
RESPONSE=$(curl -s -X POST https://localhost:8443/plan \
  --cacert ./cluster/certs/ca.crt \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CLAUDE_API_TOKEN" \
  -d "$(jq -n --arg model "$MODEL" --arg query "$QUERY" '{model: $model, query: $query}')")

# 5. Show Claude's response
echo ""
echo "=== Claude's Planning Response ==="
echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('response', json.dumps(data, indent=2)))
except:
    print(sys.stdin.read())
" 2>/dev/null || echo "$RESPONSE"

# 6. Pretty-print the current plan
echo ""
echo "=== Current Plan ==="
# Find the most recent plan file
LATEST=$(ls -t plans/plan-*.json 2>/dev/null | head -1)
if [ -n "$LATEST" ]; then
  python3 - "$LATEST" <<'EOF'
import json, sys
plan = json.load(open(sys.argv[1]))
print(f"Plan: {plan['id']}")
print(f"Goal: {plan['goal']}")
print(f"Status: {plan['status']}")
print()
for t in plan['tasks']:
    marker = {'completed': '✓', 'current': '→', 'pending': ' ', 'blocked': '✗', 'in_progress': '…'}.get(t['status'], '?')
    print(f"  [{marker}] {t['id']}: {t['name']} ({t['status']})")
    if t.get('files'):
        print(f"      files: {', '.join(t['files'])}")
EOF
else
  echo "No plan files found in plans/"
fi

echo ""
