#!/bin/bash
set -euo pipefail

# dev-loop.sh — automated plan-then-execute loop
# Usage: ./dev-loop.sh MODEL MAX_ITERATIONS [POLL_INTERVAL]

# ---------------------------------------------------------------------------
# 1. Argument validation
# ---------------------------------------------------------------------------
if [ "${1:-}" = "" ] || [ "${2:-}" = "" ]; then
  echo "Usage: ./dev-loop.sh MODEL MAX_ITERATIONS [POLL_INTERVAL]"
  echo ""
  echo "  MODEL           Model name passed to query.sh (e.g. claude-sonnet-4-6)"
  echo "  MAX_ITERATIONS  Maximum number of query iterations before giving up"
  echo "  POLL_INTERVAL   Seconds to sleep between iterations (default: 5)"
  echo ""
  echo "Example: ./dev-loop.sh claude-sonnet-4-6 10 5"
  exit 1
fi

MODEL="$1"
MAX_ITERATIONS="$2"
POLL_INTERVAL="${3:-5}"

# ---------------------------------------------------------------------------
# 2. Verify cluster tokens exist
# ---------------------------------------------------------------------------
if [ ! -f .cluster_tokens.env ]; then
  echo "[$(date +'%H:%M:%S')] Error: .cluster_tokens.env not found."
  echo "Please start the cluster with ./run.sh first to generate the tokens."
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Main loop
# ---------------------------------------------------------------------------
ITERATION=0

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))
  echo ""
  echo "============================================================"
  echo "[$(date +'%H:%M:%S')] Iteration $ITERATION / $MAX_ITERATIONS"
  echo "============================================================"

  # -------------------------------------------------------------------------
  # 3a. Pre-check: skip query.sh if the plan is already exhausted
  # -------------------------------------------------------------------------
  PRE_LATEST=$(ls -t plans/plan-*.json 2>/dev/null | head -1)
  if [ -n "$PRE_LATEST" ]; then
    PRE_STATUS=$(python3 - "$PRE_LATEST" <<'PYEOF'
import json, sys
plan = json.load(open(sys.argv[1]))
top_status = plan.get("status", "")
if top_status == "completed":
    print("completed")
    sys.exit(0)
# No pending/current task?
has_active = any(t.get("status") not in ("completed", "blocked") for t in plan.get("tasks", []))
if not has_active:
    print("exhausted")
    sys.exit(0)
print("in_progress")
PYEOF
    )
    if [ "$PRE_STATUS" = "completed" ] || [ "$PRE_STATUS" = "exhausted" ]; then
      echo "[$(date +'%H:%M:%S')] ✓ Plan already completed — no further iterations needed."
      exit 0
    fi
  fi

  # Build the prompt for the agent
  PROMPT='Call plan_current to get the current task from the active plan. Read every file listed in the task using the fileserver tools, then carry out the work described in the action field. After making any code change, call run_tests followed by get_test_results to verify the tests pass; if tests fail, fix the failures before proceeding. When the verify criteria are satisfied and the done condition is met, call plan_complete with the current task id. If you encounter a blocker you cannot resolve on your own, call plan_block with a clear reason describing what is needed.'

  # Invoke the agent
  ./query.sh "$MODEL" "$PROMPT"

  # -------------------------------------------------------------------------
  # 4. Parse the most recent plan JSON to detect completion or blockage
  # -------------------------------------------------------------------------
  LATEST=$(ls -t plans/plan-*.json 2>/dev/null | head -1)

  if [ -z "$LATEST" ]; then
    echo "[$(date +'%H:%M:%S')] Warning: no plan files found in plans/ — cannot detect status."
  else
    PLAN_STATUS=$(python3 - "$LATEST" <<'PYEOF'
import json, sys

plan = json.load(open(sys.argv[1]))
top_status = plan.get("status", "")

if top_status == "completed":
    print("completed")
    sys.exit(0)

# Check for any blocked task
for t in plan.get("tasks", []):
    if t.get("status") == "blocked":
        reason = t.get("blocked_reason") or t.get("reason") or "(no reason given)"
        print(f"blocked\t{t['id']}\t{t['name']}\t{reason}")
        sys.exit(0)

print("in_progress")
PYEOF
    )

    case "$PLAN_STATUS" in
      completed)
        echo ""
        echo "[$(date +'%H:%M:%S')] ✓ Plan completed successfully after $ITERATION iteration(s)."
        exit 0
        ;;
      blocked*)
        BLOCKED_ID=$(echo "$PLAN_STATUS"   | cut -f2)
        BLOCKED_NAME=$(echo "$PLAN_STATUS" | cut -f3)
        BLOCKED_REASON=$(echo "$PLAN_STATUS" | cut -f4)
        echo ""
        echo "[$(date +'%H:%M:%S')] ✗ Task blocked: [$BLOCKED_ID] $BLOCKED_NAME"
        echo "  Reason: $BLOCKED_REASON"
        exit 1
        ;;
      *)
        echo "[$(date +'%H:%M:%S')] Plan still in progress."
        ;;
    esac
  fi

  # -------------------------------------------------------------------------
  # 5. Sleep before next iteration (skip after last iteration)
  # -------------------------------------------------------------------------
  if [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; then
    echo "[$(date +'%H:%M:%S')] Sleeping ${POLL_INTERVAL}s before next iteration..."
    sleep "$POLL_INTERVAL"
  fi
done

# ---------------------------------------------------------------------------
# 6. Exhausted MAX_ITERATIONS without completion
# ---------------------------------------------------------------------------
echo ""
echo "[$(date +'%H:%M:%S')] Warning: reached maximum iterations ($MAX_ITERATIONS) without plan completion."
exit 1
