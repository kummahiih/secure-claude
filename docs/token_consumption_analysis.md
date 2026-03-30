# Token Consumption Analysis & Optimization Report

## Session Analysis (2026-03-30 logs)

### LLM call count
- **Planning phase** (Opus): 6 calls — reasonable for reading docs + creating a 3-task plan
- **Execution phase** (Sonnet): ~45 calls for 3 tasks — **~15 calls per task, nearly 2x the target**

### Where the tokens burn

#### 1. Test polling loop (worst offender)
The first test cycle shows **7 consecutive `get_test_results` polls** at ~2–3 second intervals
(19:51:35 → 19:51:38 → 19:51:41 → 19:51:44 → 19:51:46 → 19:51:49 → 19:51:52),
while the actual test completed at 19:51:58. Each poll is a full LLM round-trip re-sending
the entire conversation history just for the model to say "still running, I'll check again."

**Cost**: 7 round-trips × growing context = significant token waste per test cycle.
**Fix in new prompt**: "Wait 15 seconds, then call get_test_results. If still running, wait 30s
and retry. Max 3 polls total." Cuts 7 polls to 2–3.

#### 2. Git commit failure + retry
At 19:52:00 `git_commit` failed because the agent didn't pass `submodule_path` for a file
inside `cluster/agent/`. It then had to retry with the correct parameter at 19:52:07.
This wasted 2 round-trips (failed commit + re-add + successful commit).

**Cost**: 2 extra round-trips with full context.
**Fix in new prompt**: Step 5c now includes error-recovery logic: if `git_commit` fails
mentioning a submodule with modified content, retry with the `submodule_path` from the error.
This handles any repo's submodule layout without hardcoding paths.

#### 3. Duplicate file reads
The MCP fileserver logs show `server.py` read twice (19:49:47 and 19:50:56) and
`test_server.py` read twice (19:49:47 and 19:52:12) with identical SHA256 hashes both times.

**Cost**: 2 unnecessary round-trips + file content bloating the context.
**Fix in new prompt**: "Plan your edits before reading files. Read and edit in the same turn."

#### 4. Context accumulation across tasks
All 3 tasks ran in a single Claude Code session (session bbab9f81). By task 3,
the context includes all file reads, test outputs, git operations, and reasoning from
tasks 1 and 2 — none of which is relevant to writing `docs/THREAT_MODEL.md`.

**Cost**: Task 3 pays for task 1+2 context on every round-trip.
**Fix (architectural)**: See "Sub-agent architecture" below.

#### 5. Planning phase used Opus
The planning call used `claude-opus-4-6` (6 LLM calls). Opus input/output tokens are
significantly more expensive than Sonnet. For a task that just reads docs and creates
a JSON plan, Sonnet is sufficient.

**Fix**: Route `/plan` to Sonnet instead of Opus. Save the Opus budget for complex debugging.

## Prompt changes summary

### ask.md changes
| Change | Reason | Expected savings |
|--------|--------|-----------------|
| Increased poll delays (15s/30s, max 3) | Eliminates 5+ wasted poll round-trips per test cycle | ~30% per-task |
| Added submodule commit error-recovery | Prevents commit failures + retries (generic, works with any repo) | 2 round-trips per submodule task |
| "Read and edit in same turn" | Prevents duplicate file reads | 1–2 round-trips per task |
| "Batch git_add + git_commit" | Combines two calls into one response | 1 round-trip per commit |
| Removed "Read project docs" as unconditional | Docs already read in planning phase; skip if context has them | 1–2 round-trips |
| Kept ≤8 round-trip budget | Hard ceiling prevents runaway sessions | Caps worst case |

### plan.md changes
| Change | Reason |
|--------|--------|
| Added "≤8 round-trips" size constraint | Planner creates tasks sized to the executor's budget |
| Trimmed redundant prose | Fewer input tokens on every planning call |

## Recommended architectural changes (beyond prompts)

### 1. Sub-agent per task (highest impact)
Currently `claude-server` spawns one Claude Code session for all tasks.
Change to: spawn a fresh session per task, passing only system prompt + task description.

```
POST /ask  →  for each pending task:
                spawn claude --print (fresh context)
                  → execute task
                  → return result
                capture: pass/block/fail + one-line summary
```

**Expected savings**: 40–60% total tokens. Task 3 no longer carries task 1+2 baggage.

### 2. Make run_tests blocking
The tester server runs `test.sh` as a subprocess. Instead of the async run + poll pattern,
make `run_tests` wait for completion and return the result directly.
Eliminates the poll loop entirely — zero wasted round-trips on test waiting.

If the tool API can't be made blocking, at minimum make `get_test_results` accept a
`wait=true` parameter that blocks server-side until done (with a timeout).

### 3. Truncate test output on success
Change `get_test_results` to return only `{"status": "pass"}` on success.
Only include stdout/stderr on failure (and even then, truncate to last 50 lines).
Keeps successful test output from bloating context for subsequent operations.

### 4. Route planning to Sonnet
The `/plan` endpoint doesn't need Opus. It reads docs, creates a JSON structure,
and returns it. Sonnet handles this well at a fraction of the cost.

### 5. Trim tool descriptions
Every MCP tool description is re-sent on every LLM call. If your tool descriptions
are verbose (common with auto-generated MCP schemas), shortening them saves tokens
multiplied by the number of round-trips.