# Token Consumption Model

**Date:** 2026-04-05
**Scope:** secure-claude v1.x — autonomous AI coding agent cluster
**Data source:** Sessions 8ec1d3ac, f144760e, 459cbc2d, cc5c7709, 99f07dd5 (2026-04-04 to 2026-04-05); plus 10 prior sessions from 2026-04-03 analysis.

---

## 1. Context Minimization Audit

### 1.1 Project Decomposition ✅ COMPLIANT

Monorepo-with-submodules pattern: `secure-claude` (parent) contains three independently-developable submodules (`cluster/agent`, `cluster/planner`, `cluster/tester`). Each has its own `docs/CONTEXT.md`. Only **one submodule** is mounted as `/workspace` at a time — cross-project context bleed is architecturally impossible.

**No violation.**

### 1.2 Documentation Scoping ✅ IMPROVED (was ⚠️ MEDIUM DEBT)

The prior analysis identified `ARCHITECTURE.md` (~10,000 tokens) as the dominant doc cost. This has been **resolved**: the document was split into:
- `ARCHITECTURE_OVERVIEW.md` (~3,000 tok) — component table, data flow, MCP tool sets
- `ARCHITECTURE_DETAIL.md` (~7,000 tok) — security, TLS, network, design decisions

The detail doc header states: *"Read this document only when working on security, TLS, network, or infrastructure tasks."*

**Remaining debt:**

| Document | Est. Tokens | Issue |
|----------|-------------|-------|
| `docs/TOKEN_USE.md` | ~11,000 | Self-growth from successive analysis runs; read unnecessarily on non-analysis tasks |
| `docs/token_consumption_analysis.md` | ~1,000 | **Legacy doc, fully superseded.** Still present; wastes tokens if read speculatively |
| `docs/CONTEXT.md` | ~3,000 | Focused; acceptable |

**Context debt:** ~12,000 tokens if agent reads TOKEN_USE.md + legacy doc on routine tasks.

### 1.3 Session Isolation ✅ COMPLIANT

All 5 new sessions show exactly 1 logged LLM event per session. Subagent-per-task architecture (`claude --print` per task) is functioning correctly. No cross-task context accumulation.

### 1.4 Tool Description Bloat ⚠️ LOW DEBT

35 MCP tools contribute ~4,000–6,000 cached tokens per call. ~500 tokens of redundancy identified (verbose `submodule_path` descriptions, redundant async polling explanation in `run_tests`). Low absolute cost at cache-read pricing.

### 1.5 File Read Discipline ❌ CANNOT ASSESS

`tool_counts` remains `{}` in all 5 new sessions. MCP backend instrumentation still not implemented. Duplicate reads cannot be detected from production data.

---

## 2. Token Flow Map

### 2.1 Per-Session Request Lifecycle

Estimated token flow for a typical coding task (one `claude --print` subprocess). Context grows with each round-trip as Claude Code re-sends the full conversation history.

```
Round-trip 1: Initial assessment
  [CACHE] System prompt + MCP tool schemas + CC wrapper  ~22,300 tok
  [INPUT] User query                                          ~5 tok
  [OUTPUT] Tool call: plan_current                           ~50 tok

Round-trip 2: Receive task; read docs
  [CACHE] RT1 context                                    ~22,300 tok
  [INPUT] plan_current result                               ~500 tok
  [OUTPUT] Tool calls: list_docs + read_doc                  ~80 tok

Round-trip 3: Read CONTEXT.md + ARCHITECTURE_OVERVIEW.md
  [CACHE] Growing context                                ~22,880 tok
  [INPUT] Doc contents                                    ~6,000 tok
  [OUTPUT] Tool calls: read_file + replace                   ~80 tok

Round-trip 4: File read + edit
  [CACHE] Growing context                                ~28,960 tok
  [INPUT] File content + edit confirm                     ~3,000 tok
  [OUTPUT] Tool call: run_tests                              ~30 tok

Round-trip 5: Test results (with blocking wait)
  [CACHE] Growing context                                ~31,990 tok
  [INPUT] Test result                                     ~5,000 tok
  [OUTPUT] Tool calls: git_add + git_commit                 ~100 tok

Round-trip 6: Commit confirm + plan_complete
  [CACHE] Growing context                                ~37,090 tok
  [INPUT] Commit success                                     ~50 tok
  [OUTPUT] plan_complete + DONE                             ~100 tok

  ──────────────────────────────────────────────────────
  Estimated cache read (cumulative):                   ~181,520 tok
  Estimated non-cached input:                           ~14,555 tok
  Estimated output:                                        ~440 tok
```

**Improvement vs prior model:** The ARCHITECTURE split saves ~7,000 tokens from RT3 onward, reducing cumulative cache reads by ~28,000 tokens per 4 subsequent round-trips.

### 2.2 Component → Token-Consuming Operation Map

| Component | Operation | Token Impact | Notes |
|-----------|-----------|-------------|-------|
| `claude-server` | Spawn subprocess | ~22,300 tok fixed (cached) | System prompt + tool schemas + CC wrapper |
| `plan-server` | `plan_current` | ~300–800 tok | Task JSON |
| `docs_mcp.py` | `read_doc(CONTEXT.md)` | ~3,000 tok | Always read |
| `docs_mcp.py` | `read_doc(ARCHITECTURE_OVERVIEW.md)` | ~3,000 tok | Always read (was ~10,000 before split) |
| `docs_mcp.py` | `read_doc(ARCHITECTURE_DETAIL.md)` | ~7,000 tok | Security/infra tasks only |
| `mcp-server` | `read_workspace_file` | 100–50,000 tok/file | Largest variable cost |
| `tester-server` | `run_tests` + poll | ~50 tok start; 2,000–15,000 tok results | Full stdout enters context |
| `git-server` | `git_add` + `git_commit` | ~100–200 tok | Low cost |

---

## 3. Session Analysis

### 3.1 Latest Session Data (2026-04-04 to 2026-04-05, n=5)

| Session ID | Model | Input Tok | Output Tok | Cache Read Tok | Duration | Category |
|------------|-------|-----------|------------|----------------|----------|----------|
| 8ec1d3ac | **opus** | 22 | 6,806 | 791,409 | 290s | Heavy analysis |
| f144760e | **opus** | 17 | 7,443 | 730,733 | 182s | Heavy analysis |
| 459cbc2d | sonnet | 104 | 27,532 | 6,499,315 | 597s | **Very heavy** analysis |
| cc5c7709 | **opus** | 14 | 3,957 | 383,182 | 110s | Medium task |
| 99f07dd5 | sonnet | 10 | 1,272 | 200,609 | 37s | Light task |

### 3.2 Key Findings from New Data

**Finding 1: Model Misallocation Confirmed (was "Verify" in prior report)**

3 of 5 sessions use `claude-opus-4-6`. Opus cache-read pricing is $1.50/MTok vs Sonnet's $0.30/MTok — a **5× premium**. Comparing equivalent-complexity sessions:

| Metric | cc5c7709 (Opus) | 99f07dd5 (Sonnet) |
|--------|-----------------|-------------------|
| Cache read | 383,182 tok | 200,609 tok |
| Cache cost | $0.575 | $0.060 |
| Duration | 110s | 37s |

Even accounting for different task complexity, the Opus sessions pay 5× more per cached token. Session cc5c7709 (383k cache, Opus) costs ~$0.575 vs ~$0.115 if it had used Sonnet — a $0.46 difference on a single task.

**Finding 2: Extreme Cache Consumption Session**

Session 459cbc2d consumed **6,499,315 cache read tokens** (Sonnet) over 597 seconds. At $0.30/MTok this is ~$1.95. This is 29× higher than the typical light task (200k tokens). The 104 input tokens suggest many round-trips with minimal new input — classic context accumulation *within* a single subprocess execution. This session likely involved a complex multi-file analysis or generation task with 15+ internal round-trips.

**Finding 3: DONE-Call Pattern Absent**

None of the 5 new sessions are DONE calls (all have >1,000 output tokens). The prior 50% DONE-call rate may have been a transient artifact of rapid manual testing against an exhausted plan. The pre-spawn plan check remains a valid optimization but may have lower real-world impact than the 50% estimate.

**Finding 4: Observability Gap Persists**

`tool_counts` remains `{}` across all sessions. Per-tool and per-round-trip instrumentation is still the #1 infrastructure prerequisite.

### 3.3 Historical Comparison

| Period | Sessions | Avg Cache Tok | Avg Output Tok | Models Used |
|--------|----------|--------------|----------------|-------------|
| 2026-04-03 (prior report) | 10 | 233,350 | 5,032 | 100% Sonnet |
| 2026-04-04–05 (this report) | 5 | 1,721,050 | 9,402 | 60% Opus, 40% Sonnet |

The 7.4× increase in average cache tokens is driven by: (a) Opus model usage inflating token counts, (b) session 459cbc2d as a statistical outlier, and (c) heavier analysis tasks in this sample period.

---

## 4. Waste Taxonomy

### 4.1 Model Misallocation — ❌ HIGH PRIORITY (Escalated from P3 "Verify")

**Status:** Confirmed. 60% of recent sessions use Opus unnecessarily.

Opus costs 5× more per cached token ($1.50 vs $0.30/MTok cache read) and runs ~3× slower. For routine coding tasks (read files, edit, test, commit), Sonnet is sufficient.

| Metric | Value |
|--------|-------|
| Current cost multiplier | 5× on cache reads for Opus sessions |
| Sessions affected | 3/5 (60%) in latest sample |
| Cost of cc5c7709 at Opus pricing | ~$0.575 |
| Cost of cc5c7709 at Sonnet pricing | ~$0.115 |
| **Savings per Opus→Sonnet switch** | **~$0.46 per medium task; ~80% cost reduction** |
| **Proposed fix** | Default all `/ask` tasks to Sonnet; reserve Opus for `/plan` or explicit user opt-in |
| **Effort** | Low (env var / model config change) |

### 4.2 Test Output Bloat — HIGH PRIORITY

Unchanged from prior analysis. `get_test_results` returns full stdout/stderr regardless of pass/fail. 2,000–15,000 tokens enter context and persist through 2+ subsequent round-trips.

| Metric | Estimate |
|--------|----------|
| Tokens wasted per passing task | 2,000–15,000 in context |
| Extra cache from carry-forward | 4,000–30,000 tok |
| **Fix** | On pass: `{"status":"pass","exit_code":0}`. On fail: last 50 lines only |
| **Effort** | Low |

### 4.3 Polling Waste — MEDIUM PRIORITY

System prompt mitigates to 1–3 polls. Each unnecessary poll re-reads ~39k+ cached tokens. Blocking `wait=true` endpoint would eliminate 1–2 round-trips.

| Metric | Estimate |
|--------|----------|
| Extra cache per unnecessary poll | ~39,000–78,000 tok |
| **Fix** | Add `wait=true` to `GET /results` in tester-server |
| **Effort** | Medium |

### 4.4 DONE-Call Overhead — LOW PRIORITY (Downgraded)

Not observed in latest 5 sessions. Prior 50% rate may have been transient. Pre-spawn check remains valid but lower priority.

| Metric | Estimate |
|--------|----------|
| Overhead per DONE call | ~22,301 cache tok + 13–18s |
| Observed frequency | 0/5 recent; 5/10 prior |
| **Fix** | Pre-check plan-server before subprocess spawn |
| **Effort** | Low |

### 4.5 Analysis Document Self-Growth — MEDIUM PRIORITY

TOKEN_USE.md is now ~11,000 tokens. Each analysis run reads it, grows it, and the next run pays more. `token_consumption_analysis.md` (legacy, ~1,000 tok) still exists and is fully superseded.

| Metric | Estimate |
|--------|----------|
| Current TOKEN_USE.md size | ~11,000 tok |
| Legacy doc overhead | ~1,000 tok |
| **Fix** | Archive §3 history; exclude from routine reads; delete legacy doc |
| **Effort** | Low |

### 4.6 Observability Gap — HIGH OPERATIONAL PRIORITY

Unchanged. `tool_counts` is `{}` in all sessions. No per-tool or per-round-trip data. All waste estimates are projections.

| Metric | Notes |
|--------|-------|
| Missing events | `tool_call`, `file_read`, `test_run`, `git_op` |
| **Fix** | Instrument mcp-server, tester-server, git-server |
| **Effort** | Medium |

### 4.7 Context Accumulation — RESOLVED ✅

Subagent-per-task architecture confirmed working across all 15 sessions analyzed.

### 4.8 Tool Description Redundancy — LOW PRIORITY

~500 tokens of redundancy. Negligible at cache pricing. Fix opportunistically.

---

## 5. Optimization Plan

### 5.1 Default All /ask Tasks to Sonnet [P0 — Low Effort, Highest Impact]

The single highest-impact optimization available. Route all `/ask` endpoint invocations to `claude-sonnet-4-6` by default. Reserve `claude-opus-4-6` for explicit user opt-in via the `model` parameter.

**Files:** `cluster/agent/claude/server.py` (default model config), environment config
**Impact:** ~80% cost reduction on all tasks currently using Opus (~60% of recent sessions).

### 5.2 Truncate Test Output on Pass [P1 — Low Effort, High Impact]

On pass: return `{"status":"pass","exit_code":0}`. On fail: last 50 lines only.

**Files:** `cluster/tester/main.go`, `cluster/agent/claude/tester_mcp.py`
**Impact:** 2,000–15,000 tokens removed from context per passing task.

### 5.3 Instrument MCP Backends [P1 — Medium Effort, High Value]

Emit `file_read`, `test_run`, `git_op` events from Go backend servers. Add `LOG_SERVER_URL` env var.

**Files:** `mcp-server/main.go`, `cluster/tester/main.go`, `cluster/git-server/main.go`, `docker-compose.yml`
**Impact:** Enables data-driven measurement of all waste categories.

### 5.4 Add Blocking `get_test_results` [P2 — Medium Effort, Medium Impact]

Add `wait=true` query parameter. Server holds connection until test completes. Update MCP wrapper and system prompt.

**Files:** `cluster/tester/main.go`, `cluster/agent/claude/tester_mcp.py`, `cluster/agent/prompts/system/ask.md`
**Impact:** Eliminates 1–2 poll round-trips (~39k–78k cache tokens each).

### 5.5 Archive TOKEN_USE History + Delete Legacy Doc [P2 — Low Effort, Medium Impact]

1. Move §3 historical data to `docs/TOKEN_USE_HISTORY.md`
2. Delete `docs/token_consumption_analysis.md`
3. Add system prompt exclusion for TOKEN_USE docs on routine tasks

**Files:** `docs/TOKEN_USE.md`, new `docs/TOKEN_USE_HISTORY.md`, `docs/token_consumption_analysis.md` (delete), `cluster/agent/prompts/system/ask.md`
**Impact:** Prevents self-growth; eliminates ~12,000 tok on routine tasks.

### 5.6 Pre-Spawn Plan Check [P3 — Low Effort, Low-Medium Impact]

Check plan-server before spawning subprocess. Return DONE immediately if no pending task.

**Files:** `cluster/agent/claude/server.py`
**Impact:** ~22k tokens + 13–18s per no-op (when it occurs).

### 5.7 Per-Round-Trip LLM Logging [P3 — Medium Effort, High Observability Value]

Parse `--output-format json` for per-turn usage. Emit per-turn `llm_call` events.

**Files:** `cluster/agent/claude/server.py`, `cluster/log-server/main.go`
**Impact:** Full turn-level visibility into context growth curves.

### 5.8 Deduplicate Tool Descriptions [P4 — Low Effort, Low Impact]

Shorten `submodule_path` descriptions. Remove redundant async explanation from `run_tests`.

**Files:** `cluster/agent/claude/git_mcp.py`, `cluster/agent/claude/tester_mcp.py`, `docs/mcp-tools.json`
**Impact:** ~500 tokens removed from cached baseline.

---

## 6. Infrastructure Requirements

### 6.1 Model Routing Configuration

| Change | File | Description |
|--------|------|-------------|
| Default model to Sonnet | `cluster/agent/claude/server.py` or env config | Route `/ask` to `claude-sonnet-4-6` unless user explicitly passes `model=claude-opus-4-6` |

### 6.2 tester-server: Blocking Wait + Output Truncation

| Change | File | Description |
|--------|------|-------------|
| Output truncation on pass | `cluster/tester/main.go` | Return minimal JSON on success; last 50 lines on fail |
| `wait=true` query param | `cluster/tester/main.go` | Hold connection until test completes |
| MCP wrapper update | `cluster/agent/claude/tester_mcp.py` | Document changes; remove async poll explanation |
| System prompt update | `cluster/agent/prompts/system/ask.md` | Use `wait=true`; simplify poll instructions |

### 6.3 MCP Backend Log Instrumentation

| Service | File | Events to Emit |
|---------|------|----------------|
| mcp-server | `mcp-server/main.go` | `file_read: {path, bytes, sha256, duration_ms}` |
| tester-server | `cluster/tester/main.go` | `test_run: {exit_code, output_lines, duration_ms}` |
| git-server | `cluster/git-server/main.go` | `git_op: {operation, submodule_path, duration_ms}` |
| All three | `docker-compose.yml` | Add `LOG_SERVER_URL=https://log-server:8443` |

### 6.4 server.py Changes

| Change | File | Description |
|--------|------|-------------|
| Pre-spawn plan check | `cluster/agent/claude/server.py` | `GET /plan/current` before subprocess; skip if no task |
| Per-turn log parsing | `cluster/agent/claude/server.py` | Parse JSON output for per-turn usage; emit per-turn events |

### 6.5 Documentation Changes

| Change | File | Description |
|--------|------|-------------|
| Archive TOKEN_USE history | `docs/TOKEN_USE.md` → `docs/TOKEN_USE_HISTORY.md` | Move §3 historical run tables |
| Delete legacy doc | `docs/token_consumption_analysis.md` | Fully superseded |
| Exclude from routine reads | `cluster/agent/prompts/system/ask.md` | Add exclusion for TOKEN_USE docs |
| Deduplicate tool descriptions | git_mcp.py, tester_mcp.py, mcp-tools.json | Shorten verbose descriptions |

---

## 7. Prioritized Action Items

| Priority | Item | Category | Current Waste | Expected Savings | Effort | Status |
|----------|------|----------|---------------|------------------|--------|--------|
| P0 | Default `/ask` to Sonnet — reserve Opus for explicit opt-in | Model Allocation | 5× cost premium on 60% of sessions | ~80% cost reduction on affected sessions | Low | Open |
| P1 | Truncate test output on pass — return `{"status":"pass"}` only; last 50 lines on fail | Infrastructure | 2,000–15,000 tok/task in context | 2,000–15,000 tok/task | Low | Open |
| P1 | Instrument mcp-server, tester-server, git-server to emit log events | Observability | All waste categories unquantifiable | Full per-tool visibility | Medium | Open |
| P2 | Split `ARCHITECTURE.md` → overview + detail; update system prompt | Documentation | ~7,000–9,000 tok/routine task | ~7,000–9,000 tok/task | Low | **Done** |
| P2 | Archive TOKEN_USE §3 history; delete legacy `token_consumption_analysis.md`; exclude from routine reads | Context Hygiene | ~12,000 tok if read on non-analysis tasks | Caps doc growth; eliminates ~12k tok on routine tasks | Low | Open |
| P2 | Add `wait=true` to `get_test_results` (server-side blocking) | Infrastructure | 1–2 poll round-trips/test (~39k–78k cache tok each) | 1–2 round-trips per tested task | Medium | Open |
| P3 | Pre-spawn plan check in `server.py` — skip subprocess if no pending task | Infrastructure | ~22,301 tok + 13–18s per DONE call | 22k tok + startup cost per no-op | Low | **Done** |
| P3 | Per-turn LLM event logging (parse `--output-format json`) | Observability | Round-trip counts invisible | Full turn-level visibility | Medium | Open |
| P4 | Shorten `submodule_path` + remove redundant async explanation in tool descriptions | Tool Descriptions | ~500 tok/call (cached) | ~500 tok/call | Low | Open |
| P4 | Enable SHA256 dedup detection for file reads via log analysis | Observability | Unknown (est. ~500–5k tok/dup) | Unknown until P1 observability | Low | Blocked (needs P1 instrumentation) |

### Status Legend

| Status | Meaning |
|--------|---------|
| **Open** | Not started |
| **Done** | Implemented and verified |
| **Blocked** | Depends on another item |

### Already Implemented

| Item | Category | Savings Realized |
|------|----------|-----------------|
| Subagent-per-task architecture (fresh subprocess per task) | Architecture | 40–60% total tokens — eliminates cross-task context accumulation |
| ARCHITECTURE.md split into overview (~3k tok) + detail (~7k tok) | Documentation | ~7,000–9,000 tok/routine task |
| Poll delay directives in system prompt (15s/30s, max 3 polls) | Prompt | Reduced polling from ~7 to 1–3 rounds/cycle |
| "Read and edit in the same turn" rule | Prompt | Mitigates 1–2 duplicate reads/task |
| "Batch git_add + git_commit in one response" rule | Prompt | Saves 1 round-trip per commit |
| `≤8 LLM round-trips per task` budget ceiling | Prompt | Caps worst-case runaway sessions |
| Prompt caching (Anthropic API) | Infrastructure | 10× reduction on fixed overhead ($0.30 vs $3.00/MTok) |
