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

### 1.6 Model Misallocation 🔴 CRITICAL REGRESSION

**All 10 sessions from 2026-04-10–11 used `claude-opus-4-6`.** Token breakdown confirms Opus on every turn across sessions 4b5af5a1, f1a5d59a, b9d7c64e, and 9fcb0a3e. This is a complete regression from the 0% Opus achieved on 2026-04-06.

**Root cause:** The model parameter passed to `/ask` is not enforced server-side. The behavioral fix (callers using Sonnet) reverted — likely the caller script or user changed the model parameter back to Opus.

**Cost impact:** Opus cache read pricing is $1.50/MTok vs Sonnet's $0.30/MTok (5× multiplier). Opus output is $75/MTok vs $15/MTok (5× multiplier). Per-session cost increased from **$0.17 → $1.69** — a **10× regression**.

### 1.7 Turn Count Regression 🔴 HIGH

Average LLM calls rose from 21.3 (2026-04-06) to **32.6** (2026-04-10–11). Session 4b5af5a1 hit **61 LLM calls**, exceeding the `--max-turns 16` cap (which allows 32 LLM calls). This suggests the turn cap was raised or removed for some sessions.

---

## 2. Token Flow Map

### 2.1 Per-Session Token Profile (2026-04-10–11, 10 sessions, ALL Opus)

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

### 2.2 Context Growth Curve (Session 4b5af5a1, 61 turns, Opus)

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
| Model used | claude-opus-4-6 (100%) | 🔴 was 0% Opus |
| Avg LLM calls/session | 32.6 | 🔴 +53% (was 21.3) |
| Avg cache read/session | 1,093,790 tok | 🔴 +99% (was 550,985) |
| Avg output/session | 703 tok | ~same (was 620) |
| Avg duration/session | 143s | +123% (was 64s) |
| Max cache read | 2,208,569 tok (f1a5d59a) | 🔴 +126% (was 976k) |
| Sessions >1M cache | 3/10 (30%) | 🔴 was 0/10 |

### 3.2 Cost Estimate (Opus pricing: $1.50/MTok cache read, $15/MTok input, $75/MTok output)

| Metric | Per Session (Opus, actual) | Per Session (Sonnet, if fixed) |
|--------|---------------------------|-------------------------------|
| Cache read cost | $1.64 | $0.33 |
| Input cost | $0.0001 | $0.00002 |
| Output cost | $0.053 | $0.011 |
| **Total** | **$1.69** | **$0.34** |

**Switching back to Sonnet alone would save $1.35/session (80%).** Reducing turn count back to ~21 would save an additional $0.17/session.

### 3.3 Comparison Table

| Date | Avg Cache/Session | Avg Calls | Runaways (>1M) | Model | Avg Cost/Session |
|------|-------------------|-----------|-----------------|-------|------------------|
| 2026-04-03 | ~800k | ~25 | 2/5 (40%) | 60% Opus | ~$1.50 |
| 2026-04-05 | ~550k | ~21 | 3/10 (30%) | 10% Opus | ~$0.50 |
| 2026-04-06 | 551k | 21.3 | 0/10 (0%) | 0% Opus | **$0.17** |
| **2026-04-11** | **1,094k** | **32.6** | **3/10 (30%)** | **100% Opus** | **$1.69** |

The 89% cost reduction achieved by 2026-04-06 has been **fully reversed**. Current per-session cost is higher than the 2026-04-03 baseline.

_Historical session tables: [TOKEN_USE_ARCHIVE.md](TOKEN_USE_ARCHIVE.md)_

---

## 4. Waste Taxonomy

### 4.1 Model Misallocation — 🔴 CRITICAL REGRESSION

All 10 sessions used Opus. This is the **single largest cost driver**, adding $1.35/session compared to Sonnet.

| Metric | Value |
|--------|-------|
| Waste per session | $1.35 (Opus vs Sonnet at same token volume) |
| Waste per 10 sessions | $13.50 |
| **Root cause** | No server-side model enforcement; caller reverted to Opus |
| **Fix** | Enforce Sonnet default in `server.py`; require explicit Opus opt-in flag |
| **Effort** | Low |

### 4.2 Turn Count Inflation — 🟡 HIGH

Average 32.6 calls vs 21.3 on 2026-04-06 (+53%). Session 4b5af5a1 hit 61 calls (exceeds --max-turns 16 = 32 calls cap).

| Metric | Value |
|--------|-------|
| Extra cache per session | ~543k tok (1,094k − 551k) |
| Extra cost at Opus | $0.81/session |
| Extra cost at Sonnet | $0.16/session |
| **Root cause** | --max-turns may have been raised/removed; complex tasks generating more turns |
| **Fix** | Verify --max-turns 16 enforcement; audit sessions with >32 calls |
| **Effort** | Low |

### 4.3 Heavy Session Runaway — 🟡 REGRESSED

3/10 sessions exceeded 1M cache tokens (was 0/10 on 2026-04-06). Session f1a5d59a hit 2.2M.

| Metric | Value |
|--------|-------|
| Waste per runaway | ~$1.50 extra (Opus) vs $0.30 (Sonnet) |
| **Root cause** | Combination of Opus model + high turn counts + large file reads |
| **Fix** | Re-enforce --max-turns 16; model switch to Sonnet caps effective cost |
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

### 5.1 Enforce Sonnet Default in server.py [P0 — Low Effort, CRITICAL]

The behavioral fix (callers choosing Sonnet) has failed. **Server-side enforcement is required.**

**Change:** In `cluster/agent/claude/server.py`, default the model to `claude-sonnet-4-6` for `/ask` endpoint. Add an explicit `force_opus=true` parameter that must be set to use Opus. Log a warning when Opus is requested.

**Files:** `cluster/agent/claude/server.py`
**Impact:** $1.35/session savings (80% reduction). Prevents future regressions.

### 5.2 Verify --max-turns 16 Enforcement [P0 — Low Effort]

Session 4b5af5a1 hit 61 LLM calls, which exceeds the 32-call limit from `--max-turns 16`. Verify the flag is present in all `claude --print` invocations.

**Files:** `cluster/agent/claude/server.py` (subprocess invocation)
**Impact:** Caps worst-case sessions at 32 calls (~1M cache at Sonnet = $0.30).

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

### 6.1 Model Enforcement (CRITICAL)

| Change | File | Description |
|--------|------|-------------|
| Default model to Sonnet | `cluster/agent/claude/server.py` | Hardcode `claude-sonnet-4-6` for `/ask`; require explicit opt-in for Opus |
| Log model usage | `cluster/agent/claude/server.py` | Emit WARNING when Opus is used for `/ask` |

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
| P0 | Enforce Sonnet default in server.py | Model Allocation | $1.35/session (5× markup) | 80% cost reduction | Low | **Open** |
| P0 | Verify --max-turns 16 enforcement | Runaway Prevention | 61 calls observed (cap=32) | Caps at 32 calls | Low | **Open** |
| P0 | Add `--max-turns 16` to `claude --print` | Runaway Prevention | Up to 7.1M cache/session | Caps at ~1M cache | Low | **Done** (verify) |
| P0 | Default `/ask` to Sonnet | Model Allocation | 5× cost on Opus sessions | 80% on affected | Low | **Done** (behavioral, regressed) |
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

| Date | Avg Cache/Session | Avg Calls/Session | Runaways (>1M) | Model Mix | Avg Cost/Session |
|------|-------------------|-------------------|-----------------|-----------|------------------|
| 2026-04-03 | ~800k | ~25 | 2/5 (40%) | 60% Opus | ~$1.50 |
| 2026-04-05 | ~550k | ~21 | 3/10 (30%) | 10% Opus | ~$0.50 |
| 2026-04-06 | 551k | 21.3 | 0/10 (0%) | 0% Opus | **$0.17** |
| **2026-04-11** | **1,094k** | **32.6** | **3/10 (30%)** | **100% Opus** | **$1.69** 🔴 |

**Summary:** The 89% cost reduction achieved by 2026-04-06 ($1.50 → $0.17) has been fully reversed. Current cost ($1.69/session) exceeds the original 2026-04-03 baseline. Root cause: 100% Opus model usage + turn count inflation. Both are fixable with low-effort server-side enforcement.
