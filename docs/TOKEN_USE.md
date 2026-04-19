# Token Consumption Model

**Date:** 2026-04-19
**Scope:** secure-claude v1.x — autonomous AI coding agent cluster
**Data source:** Sessions 461dcee4, 9b1e565b, 93fe0e8e, b10a2b3b (2026-04-19); plus 10 sessions from 2026-04-10–11 and 35 prior sessions from 2026-04-03–06 analyses.

---

## 1. Context Minimization Audit

### 1.1 Project Decomposition ✅ COMPLIANT

Monorepo-with-submodules: `secure-claude` (parent) contains three submodules (`cluster/agent`, `cluster/planner`, `cluster/tester`). Only **one submodule** is mounted as `/workspace` at a time — cross-project context bleed is architecturally impossible.

### 1.2 Documentation Scoping ✅ COMPLIANT

Architecture docs split into overview (~3k tok) + detail (~7k tok). Detail doc gated to security/infra tasks. TOKEN_USE.md excluded from routine reads via system prompt directive. Historical tables archived to TOKEN_USE_ARCHIVE.md.

### 1.3 Session Isolation ✅ COMPLIANT

Subagent-per-task (`claude --print` per task) confirmed across all sessions analyzed. No cross-task context accumulation.

### 1.4 Tool Description Bloat ✅ RESOLVED

Shortened in commit f205653. ~500 tokens of redundancy removed.

### 1.5 File Read Discipline ✅ RESOLVED

No duplicate file reads detected in any 2026-04-19 session (dedup endpoint verified for 461dcee4, 9b1e565b).

### 1.6 Tool Event Ingestion Gap 🟡 MEDIUM

All four 2026-04-19 sessions show empty `tool_counts: {}` in `get_session_summary`, despite having 20–24 LLM calls each. This means `file_read`, `file_write`, `test_run`, `git_op`, and `plan_op` events are **not being ingested** for these sessions, rendering the §5.3 aggregation work invisible. Root cause: either `log_mcp.py` fire-and-forget calls are failing silently, or the MCP wrappers are not emitting tool-level events.

| Metric | Value |
|--------|-------|
| Impact | Cannot attribute token cost to specific tool operations |
| **Root cause** | Tool event ingestion not firing or silently failing |
| **Fix** | Audit `log_mcp.py` and MCP wrappers for event emission; add health check for tool event ingestion |
| **Effort** | Low |

### 1.7 Turn Count Regression ✅ RESOLVED (2026-04-19)

Average LLM calls dropped from 32.6 (2026-04-11) to **21.25** (2026-04-19) after `--max-turns 16` was enforced on the `/plan` endpoint. No sessions exceeded 24 calls. The 61-call runaway pattern is eliminated.

---

## 2. Token Flow Map

### 2.1 Per-Session Token Profile (2026-04-19, 4 sessions)

| Session | LLM Calls | Cache Read | Output | Duration |
|---------|-----------|------------|--------|----------|
| 9b1e565b | 24 | 950,652 | 983 | 74s |
| 461dcee4 | 21 | 743,940 | 1,016 | 193s |
| 93fe0e8e | 20 | 697,427 | 694 | 58s |
| b10a2b3b | 20 | 606,576 | 859 | 128s |
| **Average** | **21.25** | **749,649** | **888** | **113s** |
| **Median** | **20.5** | **720,684** | **921** | **101s** |

### 2.2 Context Growth Curves (2026-04-19)

| Session | Start (tok) | Peak (tok) | Growth |
|---------|-------------|------------|--------|
| 461dcee4 | ~31,300 | ~46,000 | +47% |
| 9b1e565b | ~30,500 | ~57,000 | +87% |
| 93fe0e8e | ~31,000 | ~47,000 | +52% |
| b10a2b3b | ~31,000 | ~35,500 | +15% |

Context peaks are well-controlled. Session b10a2b3b shows near-ideal context discipline (+15% growth over 20 turns). Session 9b1e565b grew most due to large file reads mid-session but stayed under 60k.

### 2.3 Cache Creation Pattern

All sessions show 2–3 initial turns with zero cache reads and ~31k cache creation (system prompt + tool schemas being cached). From turn 3 onward, cache hits dominate — confirming efficient prompt caching.

### 2.4 Component → Token Cost Map

| Component | Operation | Token Impact | Notes |
|-----------|-----------|-------------|-------|
| System prompt + tools | Fixed overhead | ~31,000 tok (cached) | Sent every turn; cache hit after turn 1–3 |
| `plan-server` | `plan_current` | ~300–800 tok | Task JSON |
| `docs_mcp.py` | `read_doc(CONTEXT.md)` | ~3,000 tok | Read once per session |
| `docs_mcp.py` | `read_doc(ARCHITECTURE_OVERVIEW.md)` | ~3,000 tok | Read once per session |
| `mcp-server` | `read_workspace_file` | 100–50,000 tok/file | Largest variable cost |
| `tester-server` | `run_tests` + `get_test_results` | ~50 tok (pass) | Truncated output; blocking wait |
| `git-server` | `git_add` + `git_commit` | ~100–200 tok | Low cost |

---

## 3. Session Analysis

### 3.1 Aggregate Statistics (2026-04-19)

| Metric | Value | Change from 2026-04-11 |
|--------|-------|------------------------|
| Sessions analyzed | 4 | — |
| Avg LLM calls/session | 21.25 | 🟢 −35% (was 32.6) |
| Avg cache read/session | 749,649 tok | 🟢 −31% (was 1,093,790) |
| Avg output/session | 888 tok | +26% (was 703) |
| Avg duration/session | 113s | −21% (was 143s) |
| Max cache read | 950,652 tok (9b1e565b) | 🟢 −57% (was 2.2M) |
| Sessions >1M cache | 0/4 (0%) | 🟢 was 3/10 (30%) |

### 3.2 Comparison Table

| Date | Avg Cache/Session | Avg Calls | Runaways (>1M) | Avg Cost/Session |
|------|-------------------|-----------|-----------------|------------------|
| 2026-04-03 | ~800k | ~25 | 2/5 (40%) | ~$1.50 |
| 2026-04-05 | ~550k | ~21 | 3/10 (30%) | ~$0.50 |
| 2026-04-06 | 551k | 21.3 | 0/10 (0%) | **$0.17** |
| 2026-04-11 | 1,094k | 32.6 | 3/10 (30%) | $1.69 🔴 |
| **2026-04-19** | **750k** | **21.25** | **0/4 (0%)** | **~$0.55** 🟢 |

The `--max-turns 16` enforcement on `/plan` (done 2026-04-19) reversed the regression. Cost dropped from $1.69 → ~$0.55/session. Not yet at the $0.17 low of 2026-04-06 — the gap is due to higher base context (~31k vs ~22k on 2026-04-06, likely from system prompt growth) and slightly higher peak context.

_Historical session tables: [TOKEN_USE_ARCHIVE.md](TOKEN_USE_ARCHIVE.md)_

---

## 4. Waste Taxonomy

### 4.1 System Prompt Growth — 🟡 MEDIUM (NEW)

Base context rose from ~22k (2026-04-06) to ~31k tokens (2026-04-19) — a 41% increase. This adds ~9k tokens per turn of cache read cost. Over 21 turns, that's ~189k extra cache tokens per session.

| Metric | Value |
|--------|-------|
| Extra cache per session | ~189k tok (9k × 21 turns) |
| **Root cause** | System prompt and/or tool schema growth since April 6 |
| **Fix** | Audit `ask.md`/`ask-adhoc.md` for content added since 2026-04-06; trim redundant instructions |
| **Effort** | Low |

### 4.2 Turn Count Inflation — ✅ RESOLVED (2026-04-19)

Average 21.25 calls vs 32.6 on 2026-04-11 (−35%). All sessions within --max-turns 16 cap (32 LLM calls).

### 4.3 Heavy Session Runaway — ✅ RESOLVED (2026-04-19)

0/4 sessions exceeded 1M cache tokens (was 3/10 on 2026-04-11).

### 4.4 Test Output Bloat — ✅ RESOLVED

Pass returns `{"status":"pass","exit_code":0}`; fail returns last 50 lines.

### 4.5 Polling Waste — ✅ RESOLVED

Blocking `wait=true` on `get_test_results`. Zero poll round-trips observed.

### 4.6 Tool Count Aggregation — 🟡 MEDIUM (REGRESSION)

`handleGetSummary` code is correct (verified 2026-04-19) but `tool_counts` is empty for all 4 recent sessions. Events are either not being emitted by MCP wrappers or silently dropped during fire-and-forget ingestion.

### 4.7 Context Accumulation — ✅ RESOLVED

Subagent-per-task architecture. No cross-task bleed.

### 4.8 Documentation Self-Growth — ✅ RESOLVED

TOKEN_USE.md excluded from routine reads. Historical data archived.

---

## 5. Optimization Plan

### 5.1 Audit System Prompt Size Growth [P1 — Low Effort] — Open

Base context grew from ~22k to ~31k tokens (+41%) between 2026-04-06 and 2026-04-19. Every extra token is re-sent (cached) on every turn.

**Action:** Diff `ask.md` and `ask-adhoc.md` against their 2026-04-06 versions. Identify additions. Remove or condense anything non-essential.
**Files:** `cluster/agent/prompts/system/ask.md`, `cluster/agent/prompts/system/ask-adhoc.md`
**Impact:** ~189k cache tokens saved per session (~$0.10/session at current rates).

### 5.2 Verify --max-turns 16 Enforcement [P0 — Low Effort] ✅ DONE (2026-04-19)

Added `--max-turns 16` to the `/plan` endpoint's subprocess invocation. Regression tests guard all three invocation sites (`/ask` ad-hoc, `/ask` plan-loop, `/plan`).

**Files:** `cluster/agent/claude/server.py`, `cluster/agent/claude/claude_tests.py`
**Impact:** Caps worst-case sessions at 32 LLM calls (~1M cache). Confirmed effective: avg calls dropped 32.6 → 21.25.

### 5.3 Aggregate tool_counts in get_session_summary [P2 — Low Effort] ✅ DONE (2026-04-19)

Code implemented and tested. However, tool events are not appearing in production sessions (see §4.6).

**Files:** `cluster/log-server/main.go`, `cluster/log-server/main_test.go`

### 5.4 Fix Tool Event Ingestion [P1 — Low Effort] — Open

`tool_counts` is empty for all 2026-04-19 sessions despite active tool use. The fire-and-forget log ingestion in `server.py` may be silently failing, or MCP wrappers may not be emitting tool-level events.

**Action:** Add error logging to fire-and-forget ingestion calls. Verify each MCP wrapper (`files_mcp.py`, `git_mcp.py`, `tester_mcp.py`, `plan_mcp.py`) emits the expected event type on each operation.
**Files:** `cluster/agent/claude/server.py`, `cluster/agent/mcp/files_mcp.py`, `cluster/agent/mcp/git_mcp.py`, `cluster/agent/mcp/tester_mcp.py`, `cluster/agent/mcp/plan_mcp.py`
**Impact:** Enables per-tool waste measurement. No direct token savings but critical for future optimization.

### 5.5 Fast-path Prompt for Trivial Tasks [P3 — Medium Effort] — Open

A lightweight system prompt variant for simple edits could reduce call counts for trivial tasks from ~20 → 10–15.

**Files:** `cluster/agent/prompts/system/ask-adhoc.md`, `cluster/agent/claude/server.py`
**Impact:** ~50% cache savings on simple tasks.

---

## 6. Infrastructure Requirements

### 6.1 System Prompt Audit

| Change | File | Description |
|--------|------|-------------|
| Diff and trim prompts | `cluster/agent/prompts/system/ask.md`, `ask-adhoc.md` | Reduce base context from ~31k back toward ~22k |

### 6.2 Tool Event Ingestion Fix

| Change | File | Description |
|--------|------|-------------|
| Debug event emission | MCP wrappers + `server.py` | Ensure tool events reach log-server |
| Add ingestion health check | `log_mcp.py` or `server.py` | Detect silent ingestion failures |

---

## 7. Prioritized Action Items

| Priority | Item | Category | Current Waste | Expected Savings | Effort | Status |
|----------|------|----------|---------------|------------------|--------|--------|
| P0 | Verify --max-turns 16 enforcement | Runaway Prevention | 61 calls observed (cap=32) | Caps at 32 calls | Low | **Done** (2026-04-19) |
| P1 | Audit system prompt size growth (+41%) | Context Size | ~189k cache/session | ~189k cache/session | Low | Open |
| P1 | Fix tool event ingestion (empty tool_counts) | Observability | Visibility gap | Enables per-tool analysis | Low | Open |
| P1 | Truncate test output | Infrastructure | 2k–15k tok/task | 2k–15k tok/task | Low | **Done** |
| P1 | Instrument MCP backends | Observability | Unquantifiable waste | Full visibility | Medium | **Done** |
| P2 | Blocking `wait=true` on get_test_results | Infrastructure | 1–2 poll round-trips | 30k–78k cache/poll | Medium | **Done** |
| P2 | Split ARCHITECTURE.md → overview + detail | Documentation | 7k–9k tok/routine task | 7k–9k tok/task | Low | **Done** |
| P2 | Archive TOKEN_USE history | Context Hygiene | 11k tok on non-analysis | 11k tok/read | Low | **Done** |
| P2 | Aggregate tool_counts in get_session_summary | Observability | Visibility gap | Enables per-tool analysis | Low | **Done** (code works; events not reaching it — see P1 fix) |
| P3 | Pre-spawn plan check (skip if no pending task) | Infrastructure | 22k tok/DONE-call | 22k tok/no-op | Low | **Done** |
| P3 | Per-turn LLM event logging | Observability | Turn-level blind spot | Full turn visibility | Medium | **Done** |
| P3 | Fast-path prompt for trivial tasks | Turn Reduction | ~10 extra turns on simple tasks | ~50% cache on simple tasks | Medium | Open |
| P4 | Shorten tool descriptions | Tool Descriptions | ~500 tok/call (cached) | ~500 tok/call | Low | **Done** |
| P4 | SHA256 dedup detection endpoint | Observability | Unknown dup waste | Per-session dedup report | Low | **Done** |

### Cost Trend

| Date | Avg Cache/Session | Avg Calls/Session | Runaways (>1M) | Avg Cost/Session |
|------|-------------------|-------------------|-----------------|------------------|
| 2026-04-03 | ~800k | ~25 | 2/5 (40%) | ~$1.50 |
| 2026-04-05 | ~550k | ~21 | 3/10 (30%) | ~$0.50 |
| 2026-04-06 | 551k | 21.3 | 0/10 (0%) | **$0.17** |
| 2026-04-11 | 1,094k | 32.6 | 3/10 (30%) | $1.69 🔴 |
| **2026-04-19** | **750k** | **21.25** | **0/4 (0%)** | **~$0.55** 🟢 |

**Summary:** The `--max-turns 16` fix reversed the 2026-04-11 regression. Cost dropped from $1.69 → $0.55/session. Two open items remain: (1) system prompt grew 41% since the $0.17 baseline — trimming it could recover ~$0.10/session; (2) tool event ingestion is silently failing, blocking per-tool waste attribution.
