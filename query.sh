#!/bin/bash
set -e

# Thin wrapper: preserves the CLI contract of the original query.sh but
# delegates the actual work (token loading, HTTPS POST, response
# formatting) to the Go binary at cluster/client/cmd/ask. The usage
# fast-path stays in bash so `./query.sh` with no args avoids launching
# Go.

if [ -z "$1" ]; then
  echo "Usage: ./query.sh model \"Your question here\" [--raw]"
  echo "  Example: ./query.sh local \"Can you read the contents of test.txt in my workspace?\""
  exit 1
fi

exec go run ./cluster/client/cmd/ask "$@"
