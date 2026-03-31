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

SUBCOMMAND=$1

case "$SUBCOMMAND" in
  sessions)
    LIMIT=${2:-20}
    curl -s --cacert ./cluster/certs/ca.crt \
      -H "Authorization: Bearer $LOG_API_TOKEN" \
      "https://localhost:8443/logs/sessions?limit=$LIMIT" | python3 -m json.tool
    ;;

  summary)
    SESSION_ID=$2
    if [ -z "$SESSION_ID" ]; then
      echo "Usage: ./log.sh summary <session_id>"
      exit 1
    fi
    curl -s --cacert ./cluster/certs/ca.crt \
      -H "Authorization: Bearer $LOG_API_TOKEN" \
      "https://localhost:8443/logs/sessions/$SESSION_ID/summary" | python3 -m json.tool
    ;;

  query)
    SESSION_ID=$2
    EVENT_TYPE=${3:-""}
    if [ -z "$SESSION_ID" ]; then
      echo "Usage: ./log.sh query <session_id> [event_type]"
      echo "  event_type: llm_call | tool_call | file_read | test_run"
      exit 1
    fi
    BODY=$(jq -n --arg et "$EVENT_TYPE" 'if $et != "" then {event_type: $et} else {} end')
    curl -s -X POST --cacert ./cluster/certs/ca.crt \
      -H "Authorization: Bearer $LOG_API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$BODY" \
      "https://localhost:8443/logs/sessions/$SESSION_ID/query" | python3 -m json.tool
    ;;

  tokens)
    SESSION_ID=$2
    if [ -z "$SESSION_ID" ]; then
      echo "Usage: ./log.sh tokens <session_id>"
      exit 1
    fi
    curl -s --cacert ./cluster/certs/ca.crt \
      -H "Authorization: Bearer $LOG_API_TOKEN" \
      "https://localhost:8443/logs/sessions/$SESSION_ID/tokens" | python3 -m json.tool
    ;;

  *)
    echo "Usage: ./log.sh <subcommand> [args]"
    echo ""
    echo "Subcommands:"
    echo "  sessions [limit]              List recent sessions (default: 20)"
    echo "  summary <session_id>          Aggregate stats for a session"
    echo "  query <session_id> [type]     Query events (llm_call|tool_call|file_read|test_run)"
    echo "  tokens <session_id>           Per-call token breakdown"
    exit 1
    ;;
esac
