#!/bin/bash
set -e

# Thin wrapper: preserves the CLI contract of the original plan.sh but
# delegates the actual work (token loading, HTTPS POST, plan rendering)
# to the Go binary at cluster/client/cmd/plan. The usage fast-path
# stays in bash so `./plan.sh` with no args avoids launching Go.

if [ -z "$1" ]; then
  echo "Usage: ./plan.sh model \"Describe what you want to build\""
  echo "  Example: ./plan.sh claude-sonnet-4-6 \"add input validation to the read endpoint\""
  echo ""
  echo "This creates a plan without writing code. Review with: cat plans/*.json | python3 -m json.tool"
  exit 1
fi

exec go run ./cluster/client/cmd/plan "$@"
