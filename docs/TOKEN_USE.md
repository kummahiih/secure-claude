# Token Consumption Model

**Date:** 2026-04-11
**Scope:** secure-claude v1.x — autonomous AI coding agent cluster
**Data source:** Sessions 4b5af5a1, 9fcb0a3e, 1ab3c0cd, f1a5d59a, b9d7c64e, 92bcb6f3, 636605bb, bd481448, 5c249f89, d7fd07b4 (2026-04-10–11); plus 35 prior sessions from 2026-04-03–06 analyses.

---

## 1. Context Minimization Audit

### 1.1 Project Decomposition ✅ COMPLIANT

Monorepo-with-submodules: `secure-claude` (parent) contains three submodules (`cluster/agent`, `cluster/planner`, `cluster/tester`). Only **one submodule** is mounted as `/workspace` at a time — cross-project context bleed is architecturally impossible.

### 1.2 Documentation Scoping ✅ COMPLIANT

Architecture docs split into overview (~3k tok) + detail (~7k tok). Detail doc gated to security/infra tasks. TOKEN_USE.md excluded from routine reads via system prompt directive. Historical tables archived to TOKEN_USE_ARCHIVE.md.

### 1.3 Session Isolation ✅ COMPLIANT

Subagent-per-task (`claude --print` per task) confirmed across all 45 sessions analyzed. No cross-task context accumulation.

### 1.4 Tool Description Bloat ✅ RESOLVED

Shortened in commit f205653. ~500 tokens of redundancy removed.

### 1.5 File Read Discipline ⚠️ PARTIAL

`tool_counts` remains `{}` in all 10 new sessions — MCP backend tool counting not yet wired into summary aggregation. No duplicate file reads detected in sessions 4b5af5a1 or f1a5d59a (dedup endpoint works).

**Context debt:** Unquantifiable until tool_counts aggregation is implemented. Estimated engineering effort: Low.

### 1.7 Turn Count Regression 🔴 HIGH

Average LLM calls rose from 21.3 (2026-04-06) to **32.6** (2026-04-10–11). Session 4b5af5a1 hit **61 LLM calls**, exceeding the `--max-turns 16` cap (which allows 32 LLM calls). This suggests the turn cap was raised or removed for some sessions.

---

## 2. Token Flow Map

### 2.1 Per-Session Token Profile (2026-04-10–11, 10 sessions)

| Session | LLM Calls | Cache Read | Output | Duration |
|---------|-----------|------------|--------|----------|
| f1a5d59a | 41 | 2,208,569 | 1,344 | 258s |
| 4b5af5a1 | 61 | 1,801,513 | 811 | 156s |
| b9d7c64e | 43 | 1,776,183 | 500 | 137s |
| 1ab3c0cd | 36 | 981,210 | 610 | 394s |
| 9fcb0a3e | 27 | 866,715 | 525 | 204s |
| 5c249f89 | 26 | 735,861 | 764 | 57s |
| 636605bb | 26 | 723,705 | 775 | 68s |
| d7fd07b4 | 24 | 703,346 | 636 | 50s |
| bd481448 | 24 | 694,868 | 692 | 66s |
| 92bcb6f3 | 18 | 445,926 | 373 | 37s |
| **Average** | **32.6** | **1,093,790** | **703** | **143s** |
| **Median** | **26.5** | **750,783** | **663** | **103s** |

### 2.2 Context Growth Curve (Session 4b5af5a1, 61 turns)

```
Turn  1-3:   ~22,400 tok (system prompt + tool schemas — cache creation)
Turn  4-6:   ~27,900 tok (plan + initial reads)
Turn  7-10:  ~37,200 tok (doc reads)
Turn 11-16:  ~41,700 tok (file edits + test cycle)
Turn 17-21:  ~42,000 tok (git operations)
Turn 22-30:  ~19,700 tok (context reset — new subprocess?)
Turn 31-45:  ~44,500 tok (second edit cycle)
Turn 46-54:  ~46,300 tok (continued edits)
Turn 55-61:  ~71,500 tok (large file reads near end)
```

Context peaked at 71.5k tokens — significantly higher than the 39.5k peak observed on 2026-04-06. The 61-turn session exceeds the expected --max-turns 16 cap.

### 2.3 Component → Token Cost Map

| Component | Operation | Token Impact | Notes |
|-----------|-----------|-------------|-------|
| System prompt + tools | Fixed overhead | ~22,000 tok (cached) | Sent every turn; cache hit after turn 1 |
| `plan-server` | `plan_current` | ~300–800 tok | Task JSON |
| `docs_mcp.py` | `read_doc(CONTEXT.md)` | ~3,000 tok | Read once per session |
| `docs_mcp.py` | `read_doc(ARCHITECTURE_OVERVIEW.md)` | ~3,000 tok | Read once per session |
| `mcp-server` | `read_workspace_file` | 100–50,000 tok/file | Largest variable cost |
| `tester-server` | `run_tests` + `get_test_results` | ~50 tok (pass) | Truncated output; blocking wait |
| `git-server` | `git_add` + `git_commit` | ~100–200 tok | Low cost |

---

## 3. Session Analysis

### 3.1 Aggregate Statistics (2026-04-10–11)

| Metric | Value | Change from 2026-04-06 |
|--------|-------|------------------------|
| Sessions analyzed | 10 | — |
| Avg LLM calls/session | 32.6 | 🔴 +53% (was 21.3) |
| Avg cache read/session | 1,093,790 tok | 🔴 +99% (was 550,985) |
| Avg output/session | 703 tok | ~same (was 620) |
| Avg duration/session | 143s | +123% (was 64s) |
| Max cache read | 2,208,569 tok (f1a5d59a) | 🔴 +126% (was 976k) |
| Sessions >1M cache | 3/10 (30%) | 🔴 was 0/10 |

### 3.3 Comparison Table

| Date | Avg Cache/Session | Avg Calls | Runaways (>1M) | Avg Cost/Session |
|------|-------------------|-----------|-----------------|------------------|
| 2026-04-03 | ~800k | ~25 | 2/5 (40%) | ~$1.50 |
| 2026-04-05 | ~550k | ~21 | 3/10 (30%) | ~$0.50 |
| 2026-04-06 | 551k | 21.3 | 0/10 (0%) | **$0.17** |
| **2026-04-11** | **1,094k** | **32.6** | **3/10 (30%)** | **$1.69** |

The cost reduction achieved by 2026-04-06 has been **fully reversed**. Current per-session cost is higher than the 2026-04-03 baseline, driven by turn count inflation and elevated cache volume.

_Historical session tables: [TOKEN_USE_ARCHIVE.md](TOKEN_USE_ARCHIVE.md)_

---

## 4. Waste Taxonomy

### 4.2 Turn Count Inflation — 🟡 HIGH

Average 32.6 calls vs 21.3 on 2026-04-06 (+53%). Session 4b5af5a1 hit 61 calls (exceeds --max-turns 16 = 32 calls cap).

| Metric | Value |
|--------|-------|
| Extra cache per session | ~543k tok (1,094k − 551k) |
| **Root cause** | --max-turns may have been raised/removed; complex tasks generating more turns |
| **Fix** | Verify --max-turns 16 enforcement; audit sessions with >32 calls |
| **Effort** | Low |

### 4.3 Heavy Session Runaway — 🟡 REGRESSED

3/10 sessions exceeded 1M cache tokens (was 0/10 on 2026-04-06). Session f1a5d59a hit 2.2M.

| Metric | Value |
|--------|-------|
| Waste per runaway | ~$1.50 extra cache per session |
| **Root cause** | High turn counts + large file reads |
| **Fix** | Re-enforce --max-turns 16 |
| **Effort** | Low |

### 4.4 Test Output Bloat — ✅ RESOLVED

Pass returns `{"status":"pass","exit_code":0}`; fail returns last 50 lines.

### 4.5 Polling Waste — ✅ RESOLVED

Blocking `wait=true` on `get_test_results`. Zero poll round-trips observed.

### 4.6 Tool Count Aggregation Gap — ⚠️ LOW PRIORITY

`tool_counts` is `{}` in all sessions. Individual events emitted but not aggregated.

### 4.7 Context Accumulation — ✅ RESOLVED

Subagent-per-task architecture. No cross-task bleed.

### 4.8 Documentation Self-Growth — ✅ RESOLVED

TOKEN_USE.md excluded from routine reads. Historical data archived.

---

## 5. Optimization Plan

### 5.2 Verify --max-turns 16 Enforcement [P0 — Low Effort] ✅ DONE (2026-04-19)

Session 4b5af5a1 hit 61 LLM calls, which exceeds the 32-call limit from `--max-turns 16`. Audit found the flag present in `_run_subagent` (used by `/ask`) but **missing** from the `/plan` endpoint's subprocess invocation, which could explain turn-count inflation for plan-heavy workloads.

**Resolution:** Added `--max-turns 16` to the `/plan` endpoint's `subprocess.run` argv. Added three regression tests in `cluster/agent/claude/claude_tests.py` that assert `--max-turns 16` appears (and precedes the `--` query terminator) in every claude invocation from `/ask` (ad-hoc branch), `/ask` (plan-loop branch, every iteration), and `/plan`.

**Files:** `cluster/agent/claude/server.py`, `cluster/agent/claude/claude_tests.py`
**Impact:** Caps worst-case sessions at 32 LLM calls (~1M cache). Regression guard prevents future removal.

### 5.3 Aggregate tool_counts in get_session_summary [P2 — Low Effort]

Roll up `file_read`, `test_run`, `git_op` event counts into `tool_counts` field.

**Files:** `cluster/log-server/main.go`
**Impact:** Enables per-tool waste measurement. No direct token savings.

### 5.4 Fast-path Prompt for Trivial Tasks [P3 — Medium Effort]

Average 32.6 calls/session is high even for complex tasks. A lightweight system prompt variant that skips doc reads for tasks marked trivial could halve call counts for simple edits.

**Files:** `cluster/agent/prompts/system/ask-adhoc.md`, `cluster/agent/claude/server.py`
**Impact:** Could reduce simple-task sessions from 30+ → 10–15 calls (~50% cache savings).

---

## 6. Infrastructure Requirements

### 6.2 Turn Cap Verification

| Change | File | Description |
|--------|------|-------------|
| Verify `--max-turns 16` | `cluster/agent/claude/server.py` | Audit subprocess command construction; ensure flag is always present |

### 6.3 Log Aggregation Enhancement

| Change | File | Description |
|--------|------|-------------|
| Aggregate tool events | log-server query logic | Count `file_read`/`test_run`/`git_op` per session in `tool_counts` |

---

## 7. Prioritized Action Items

| Priority | Item | Category | Current Waste | Expected Savings | Effort | Status |
|----------|------|----------|---------------|------------------|--------|--------|
| P0 | Verify --max-turns 16 enforcement | Runaway Prevention | 61 calls observed (cap=32) | Caps at 32 calls | Low | **Done** (2026-04-19: added `--max-turns 16` to `/plan` subprocess in `cluster/agent/claude/server.py`; regression tests `test_ask_adhoc_enforces_max_turns_16`, `test_ask_plan_loop_enforces_max_turns_16`, `test_plan_endpoint_enforces_max_turns_16` guard all three invocation sites) |
| P0 | Add `--max-turns 16` to `claude --print` | Runaway Prevention | Up to 7.1M cache/session | Caps at ~1M cache | Low | **Done** (verify) |
| P1 | Truncate test output (pass: minimal JSON; fail: 50 lines) | Infrastructure | 2k–15k tok/task | 2k–15k tok/task | Low | **Done** |
| P1 | Instrument MCP backends (file_read, test_run, git_op events) | Observability | Unquantifiable waste | Full visibility | Medium | **Done** |
| P2 | Blocking `wait=true` on get_test_results | Infrastructure | 1–2 poll round-trips | 30k–78k cache/poll | Medium | **Done** |
| P2 | Split ARCHITECTURE.md → overview + detail | Documentation | 7k–9k tok/routine task | 7k–9k tok/task | Low | **Done** |
| P2 | Archive TOKEN_USE history; exclude from routine reads | Context Hygiene | 11k tok on non-analysis | 11k tok/read | Low | **Done** |
| P2 | Aggregate tool_counts in get_session_summary | Observability | Visibility gap | Enables per-tool analysis | Low | Open |
| P3 | Pre-spawn plan check (skip if no pending task) | Infrastructure | 22k tok/DONE-call | 22k tok/no-op | Low | **Done** |
| P3 | Per-turn LLM event logging | Observability | Turn-level blind spot | Full turn visibility | Medium | **Done** |
| P3 | Fast-path prompt for trivial tasks | Turn Reduction | ~10 extra turns on simple tasks | ~50% cache on simple tasks | Medium | Open |
| P4 | Shorten tool descriptions | Tool Descriptions | ~500 tok/call (cached) | ~500 tok/call | Low | **Done** |
| P4 | SHA256 dedup detection endpoint | Observability | Unknown dup waste | Per-session dedup report | Low | **Done** |

### Status Legend

| Status | Meaning |
|--------|---------|
| **Open** | Not started |
| **Done** | Implemented and verified |
| **Done** (verify) | Previously implemented; needs re-verification due to regression |

### Cost Trend

| Date | Avg Cache/Session | Avg Calls/Session | Runaways (>1M) | Avg Cost/Session |
|------|-------------------|-------------------|-----------------|------------------|
| 2026-04-03 | ~800k | ~25 | 2/5 (40%) | ~$1.50 |
| 2026-04-05 | ~550k | ~21 | 3/10 (30%) | ~$0.50 |
| 2026-04-06 | 551k | 21.3 | 0/10 (0%) | **$0.17** |
| **2026-04-11** | **1,094k** | **32.6** | **3/10 (30%)** | **$1.69** 🔴 |

**Summary:** The cost reduction achieved by 2026-04-06 ($0.17/session) has been reversed (now $1.69/session). Regression is attributable to turn count inflation (21.3 → 32.6 avg calls) and elevated cache volume (551k → 1,094k avg). Fixable by re-verifying `--max-turns 16` enforcement and auditing sessions with >32 calls.
