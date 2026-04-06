# Token Consumption Model

**Date:** 2026-04-06
**Scope:** secure-claude v1.x — autonomous AI coding agent cluster
**Data source:** Sessions 34f0c87e, b831ec05, 9e491450, e695b5d7, 3b4db094, 6928ca0b, d5a0bb42, bbc8ddf9, 55f52fa6, 767ba6a0 (2026-04-06); plus 25 prior sessions from 2026-04-03–05 analyses.

---

## 1. Context Minimization Audit

### 1.1 Project Decomposition ✅ COMPLIANT

Monorepo-with-submodules: `secure-claude` (parent) contains three submodules (`cluster/agent`, `cluster/planner`, `cluster/tester`). Only **one submodule** is mounted as `/workspace` at a time — cross-project context bleed is architecturally impossible.

### 1.2 Documentation Scoping ✅ COMPLIANT

Architecture docs split into overview (~3k tok) + detail (~7k tok). Detail doc gated to security/infra tasks. TOKEN_USE.md excluded from routine reads via system prompt directive. Historical tables archived to TOKEN_USE_ARCHIVE.md.

### 1.3 Session Isolation ✅ COMPLIANT

Subagent-per-task (`claude --print` per task) confirmed across all 35 sessions analyzed. No cross-task context accumulation.

### 1.4 Tool Description Bloat ✅ RESOLVED

Shortened in commit f205653. ~500 tokens of redundancy removed.

### 1.5 File Read Discipline ⚠️ PARTIAL

`tool_counts` remains `{}` in all 10 new sessions — MCP backend tool counting not yet wired into summary aggregation. Individual `file_read` events are emitted but not rolled up. No duplicate file reads detected in session 34f0c87e (dedup endpoint works).

**Context debt:** Unquantifiable until tool_counts aggregation is implemented. Estimated engineering effort: Low (aggregate existing events in `get_session_summary`).

---

## 2. Token Flow Map

### 2.1 Per-Session Token Profile (2026-04-06, 10 sessions)

| Session | LLM Calls | Cache Read | Output | Duration |
|---------|-----------|------------|--------|----------|
| 34f0c87e | 32 | 976,060 | 635 | 70s |
| 55f52fa6 | 27 | 676,628 | 806 | 41s |
| e695b5d7 | 21 | 625,841 | 704 | 160s |
| bbc8ddf9 | 23 | 583,978 | 614 | 53s |
| d5a0bb42 | 23 | 562,594 | 790 | 48s |
| 6928ca0b | 22 | 557,365 | 652 | 58s |
| 767ba6a0 | 21 | 552,956 | 716 | 71s |
| 9e491450 | 19 | 455,007 | 863 | 44s |
| b831ec05 | 15 | 350,828 | 233 | 26s |
| 3b4db094 | 10 | 168,590 | 190 | 73s |
| **Average** | **21.3** | **550,985** | **620** | **64s** |
| **Median** | **21.5** | **560,180** | **683** | **56s** |

### 2.2 Context Growth Curve (Session 34f0c87e, 32 turns)

```
Turn  1-3:  ~22,000 tok (system prompt + tool schemas — cache creation)
Turn  4-5:  ~22,400 tok (plan + initial tool results)
Turn  6-8:  ~31,300 tok (doc reads: CONTEXT.md, ARCHITECTURE_OVERVIEW.md)
Turn  9-10: ~31,900 tok (file reads)
Turn 11-13: ~34,550 tok (edits + test results)
Turn 14-16: ~35,800 tok (git operations)
Turn 17-21: ~37,000 tok (second file cycle)
Turn 22-25: ~39,000 tok (commit + plan_complete)
Turn 26-32: ~39,500 tok (final operations + DONE)
```

Context grew from 22k → 39.5k over 32 turns (80% growth). The `--max-turns 16` flag caps at 32 LLM calls (each "turn" = 2 LLM calls: tool call + result processing). Growth is well-bounded.

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

### 3.1 Aggregate Statistics (2026-04-06)

| Metric | Value |
|--------|-------|
| Sessions analyzed | 10 |
| Model used | claude-sonnet-4-6 (100%) |
| Avg LLM calls/session | 21.3 |
| Avg cache read/session | 550,985 tok |
| Avg output/session | 620 tok |
| Avg duration/session | 64s |
| Max cache read | 976,060 tok (34f0c87e, 32 turns) |
| Min cache read | 168,590 tok (3b4db094, 10 turns) |
| Runaway sessions (>1M cache) | 0/10 (0%) — down from 3/10 on 2026-04-05 |

### 3.2 Cost Estimate (Sonnet pricing: $0.30/MTok cache read, $3/MTok input, $15/MTok output)

| Metric | Per Session | Per 10 Sessions |
|--------|-------------|-----------------|
| Cache read cost | $0.165 | $1.65 |
| Input cost | $0.00006 | $0.0006 |
| Output cost | $0.009 | $0.09 |
| **Total** | **$0.174** | **$1.74** |

_Historical session tables: [TOKEN_USE_ARCHIVE.md](TOKEN_USE_ARCHIVE.md)_

---

## 4. Waste Taxonomy

### 4.1 Model Misallocation — ✅ RESOLVED

All 10 sessions on 2026-04-06 used Sonnet. Opus usage dropped from 60% → 10% → 0%.

### 4.2 Heavy Session Runaway — ✅ RESOLVED

`--max-turns 16` enforced since 2026-04-05. Heaviest session (34f0c87e) hit 32 LLM calls / 976k cache — well within budget. No sessions exceeded 1M cache tokens. Previous worst case was 7.1M.

### 4.3 Test Output Bloat — ✅ RESOLVED

Pass returns `{"status":"pass","exit_code":0}`; fail returns last 50 lines.

### 4.4 Polling Waste — ✅ RESOLVED

Blocking `wait=true` on `get_test_results`. Zero poll round-trips observed.

### 4.5 Tool Count Aggregation Gap — ⚠️ LOW PRIORITY

`tool_counts` is `{}` in all sessions. Individual events (`file_read`, `test_run`, `git_op`) are emitted but `get_session_summary` doesn't aggregate them. This prevents quantifying per-tool waste.

| Metric | Value |
|--------|-------|
| Impact | Observability gap only; no direct token waste |
| **Fix** | Aggregate `file_read`/`test_run`/`git_op` events in `get_session_summary` |
| **Effort** | Low |

### 4.6 DONE-Call Overhead — ✅ RESOLVED (monitoring)

Pre-spawn plan check deployed. Smallest session (3b4db094, 10 calls, 168k cache) may be a DONE-call or simple task — cost is negligible at $0.05.

### 4.7 Context Accumulation — ✅ RESOLVED

Subagent-per-task architecture. No cross-task bleed.

### 4.8 Documentation Self-Growth — ✅ RESOLVED

TOKEN_USE.md excluded from routine reads. Historical data archived.

---

## 5. Optimization Plan

### 5.1 Aggregate tool_counts in get_session_summary [P2 — Low Effort]

Roll up `file_read`, `test_run`, `git_op` event counts into the existing `tool_counts` field in `get_session_summary`. Enables per-tool waste measurement.

**Files:** `cluster/log-server/main.go` (or equivalent query logic)
**Impact:** Unlocks data-driven tool optimization. No direct token savings.

### 5.2 Default All /ask to Sonnet [P2 — Low Effort]

Model misallocation is resolved in practice (0% Opus on 2026-04-06) but not enforced. Hardcode Sonnet default in `server.py` for `/ask`; require explicit opt-in for Opus.

**Files:** `cluster/agent/claude/server.py`
**Impact:** Prevents regression. 80% cost reduction if Opus creeps back.

### 5.3 Reduce Turn Count for Simple Tasks [P3 — Medium Effort]

Average 21 LLM calls/session is reasonable for complex tasks but high for simple edits. Consider a "fast path" system prompt variant that skips doc reads for tasks marked as trivial.

**Files:** `cluster/agent/prompts/system/ask-adhoc.md`, `cluster/agent/claude/server.py`
**Impact:** Could reduce simple-task sessions from 21 → 10 calls (~50% cache savings on those tasks).

---

## 6. Infrastructure Requirements

### 6.1 Log Aggregation Enhancement

| Change | File | Description |
|--------|------|-------------|
| Aggregate tool events into `tool_counts` | log-server query logic | Count `file_read`/`test_run`/`git_op` per session |

### 6.2 Model Enforcement (Optional)

| Change | File | Description |
|--------|------|-------------|
| Default model config | `cluster/agent/claude/server.py` | Hardcode Sonnet for `/ask`; Opus for `/plan` only |

---

## 7. Prioritized Action Items

| Priority | Item | Category | Current Waste | Expected Savings | Effort | Status |
|----------|------|----------|---------------|------------------|--------|--------|
| P0 | Add `--max-turns 16` to `claude --print` | Runaway Prevention | Up to 7.1M cache/session | Caps at ~1M cache | Low | **Done** |
| P0 | Default `/ask` to Sonnet | Model Allocation | 5× cost on Opus sessions | 80% on affected | Low | **Done** (behavioral) |
| P1 | Truncate test output (pass: minimal JSON; fail: 50 lines) | Infrastructure | 2k–15k tok/task | 2k–15k tok/task | Low | **Done** |
| P1 | Instrument MCP backends (file_read, test_run, git_op events) | Observability | Unquantifiable waste | Full visibility | Medium | **Done** |
| P2 | Blocking `wait=true` on get_test_results | Infrastructure | 1–2 poll round-trips | 30k–78k cache/poll | Medium | **Done** |
| P2 | Split ARCHITECTURE.md → overview + detail | Documentation | 7k–9k tok/routine task | 7k–9k tok/task | Low | **Done** |
| P2 | Archive TOKEN_USE history; exclude from routine reads | Context Hygiene | 11k tok on non-analysis | 11k tok/read | Low | **Done** |
| P2 | Aggregate tool_counts in get_session_summary | Observability | Visibility gap | Enables per-tool analysis | Low | Open |
| P2 | Enforce Sonnet default in server.py code | Model Allocation | Regression risk | Prevents Opus creep | Low | Open |
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

### Cost Trend

| Date | Avg Cache/Session | Avg Calls/Session | Runaways | Model Mix |
|------|-------------------|-------------------|----------|-----------|
| 2026-04-03 | ~800k | ~25 | 2/5 (40%) | 60% Opus |
| 2026-04-05 | ~550k (excl. runaways: 235k) | ~21 | 3/10 (30%) | 10% Opus |
| 2026-04-06 | **551k** | **21.3** | **0/10 (0%)** | **0% Opus** |

Runaway elimination and Opus removal reduced effective per-session cost from ~$1.50 (2026-04-03 avg with Opus) to **$0.17** (2026-04-06) — an **89% reduction**.
