# Token Consumption Model

**Date:** 2026-04-05
**Scope:** secure-claude v1.x — autonomous AI coding agent cluster
**Data source:** Sessions c5152d56, 7cb87709, 73cb649b, a1724034, eebf7ed9, 819a72dc, 7ae06422, eef6e3f9, 0d89bcf8, f4f34625 (2026-04-05); plus 15 prior sessions from 2026-04-03–04 analyses.

---

## 1. Context Minimization Audit

### 1.1 Project Decomposition ✅ COMPLIANT

Monorepo-with-submodules pattern: `secure-claude` (parent) contains three independently-developable submodules (`cluster/agent`, `cluster/planner`, `cluster/tester`). Each has its own `docs/CONTEXT.md`. Only **one submodule** is mounted as `/workspace` at a time — cross-project context bleed is architecturally impossible.

### 1.2 Documentation Scoping ✅ IMPROVED

Architecture docs split into overview (~3k tok) + detail (~7k tok). Detail doc header gates reads to security/infra tasks only.

**Remaining debt:**

| Document | Est. Tokens | Issue |
|----------|-------------|-------|
| `docs/TOKEN_USE.md` | ~11,000 | Self-growth; read unnecessarily on non-analysis tasks |
| `docs/CONTEXT.md` | ~3,000 | Focused; acceptable |

**Context debt:** ~11,000 tokens if agent reads TOKEN_USE.md on routine tasks.

### 1.3 Session Isolation ✅ COMPLIANT

Subagent-per-task architecture (`claude --print` per task) confirmed across all 25 sessions analyzed. No cross-task context accumulation.

### 1.4 Tool Description Bloat ✅ RESOLVED

Shortened in latest commit (f205653). ~500 tokens of redundancy in `submodule_path` descriptions and `run_tests` async explanation removed.

### 1.5 File Read Discipline ❌ CANNOT ASSESS

`tool_counts` remains `{}` in all 10 new sessions. MCP backend instrumentation still not implemented.

---

## 2. Token Flow Map

### 2.1 Per-Session Request Lifecycle

Estimated token flow for a typical coding task. Context grows with each round-trip.

```
Round-trip 1: Initial assessment
  [CACHE] System prompt + MCP tool schemas + CC wrapper  ~22,150 tok
  [INPUT] User query                                          ~5 tok
  [OUTPUT] Tool call: plan_current                           ~50 tok

Round-trip 2: Receive task; read docs
  [CACHE] RT1 context                                    ~22,150 tok
  [INPUT] plan_current result                               ~500 tok
  [OUTPUT] Tool calls: list_docs + read_doc                  ~80 tok

Round-trip 3: Read CONTEXT.md + ARCHITECTURE_OVERVIEW.md
  [CACHE] Growing context                                ~22,730 tok
  [INPUT] Doc contents                                    ~6,000 tok
  [OUTPUT] Tool calls: read_file + replace                   ~80 tok

Round-trip 4: File read + edit
  [CACHE] Growing context                                ~28,810 tok
  [INPUT] File content + edit confirm                     ~3,000 tok
  [OUTPUT] Tool call: run_tests                              ~30 tok

Round-trip 5: Test results (with blocking wait)
  [CACHE] Growing context                                ~31,840 tok
  [INPUT] Test result                                     ~5,000 tok
  [OUTPUT] Tool calls: git_add + git_commit                 ~100 tok

Round-trip 6: Commit confirm + plan_complete
  [CACHE] Growing context                                ~36,940 tok
  [INPUT] Commit success                                     ~50 tok
  [OUTPUT] plan_complete + DONE                             ~100 tok

  ──────────────────────────────────────────────────────
  Estimated cache read (cumulative):                   ~180,420 tok
  Estimated non-cached input:                           ~14,555 tok
  Estimated output:                                        ~440 tok
```

### 2.2 Component → Token-Consuming Operation Map

| Component | Operation | Token Impact | Notes |
|-----------|-----------|-------------|-------|
| `claude-server` | Spawn subprocess | ~22,150 tok fixed (cached) | System prompt + tool schemas + CC wrapper |
| `plan-server` | `plan_current` | ~300–800 tok | Task JSON |
| `docs_mcp.py` | `read_doc(CONTEXT.md)` | ~3,000 tok | Always read |
| `docs_mcp.py` | `read_doc(ARCHITECTURE_OVERVIEW.md)` | ~3,000 tok | Always read |
| `docs_mcp.py` | `read_doc(ARCHITECTURE_DETAIL.md)` | ~7,000 tok | Security/infra tasks only |
| `mcp-server` | `read_workspace_file` | 100–50,000 tok/file | Largest variable cost |
| `tester-server` | `run_tests` + poll | ~50 tok start; 2,000–15,000 tok results | Full stdout enters context |
| `git-server` | `git_add` + `git_commit` | ~100–200 tok | Low cost |

---

## 3. Session Analysis

_Historical session data moved to [TOKEN_USE_ARCHIVE.md](TOKEN_USE_ARCHIVE.md)._

---

## 4. Waste Taxonomy

### 4.1 Model Misallocation — ⚠️ MEDIUM (Improved from ❌ HIGH)

Opus usage dropped from 60% to 10%. One remaining Opus session detected (819a72dc).

| Metric | Value |
|--------|-------|
| Sessions affected | 1/10 (10%) — down from 3/5 (60%) |
| Premium per Opus session | ~$0.77 for medium task |
| **Fix** | Default `/ask` to Sonnet; Opus for `/plan` or explicit opt-in only |
| **Effort** | Low |
| **Status** | Partially mitigated; needs enforcement |

### 4.2 Heavy Session Runaway — ❌ HIGH PRIORITY (New)

Three sessions consumed >700k cache tokens each. Session 7ae06422 hit 7.1M cache tokens (49 internal turns per token breakdown aggregate). The ≤8 round-trip budget in the system prompt is either not being enforced by Claude Code, or the session legitimately needed many turns for a complex task.

| Metric | Value |
|--------|-------|
| Affected sessions | 3/10 (30%) |
| Avg cache for heavy sessions | 4,083,291 tok (~$1.22 at Sonnet) |
| Avg cache for all others | 234,574 tok (~$0.07 at Sonnet) |
| Cost ratio | Heavy sessions cost **17.4×** more than typical |
| **Fix** | (1) Hard turn limit in `server.py` via `--max-turns` flag; (2) task decomposition in plans to keep each task ≤8 turns; (3) output token budget to prevent verbose generation |
| **Effort** | Low (flag) / Medium (decomposition) |

### 4.3 Test Output Bloat — ✅ RESOLVED

Truncation implemented in `001c0cc`. Pass returns minimal JSON; fail returns last 50 lines.

| Metric | Estimate |
|--------|----------|
| Tokens saved per passing task | 2,000–15,000 in context |
| **Status** | **Done** |

### 4.4 Polling Waste — ✅ RESOLVED

Blocking `wait=true` implemented in tester-server (`42b3338`) and wired into tester_mcp (`4f6da71`).

| Metric | Estimate |
|--------|----------|
| Polls eliminated | 1–2 round-trips per tested task |
| **Status** | **Done** |

### 4.5 Analysis Document Self-Growth — LOW PRIORITY

TOKEN_USE.md is ~11,000 tokens. Growth is capped by rewriting (not appending) on each analysis. Legacy `token_consumption_analysis.md` may have been removed (not found in latest docs listing).

| Metric | Estimate |
|--------|----------|
| Current TOKEN_USE.md size | ~11,000 tok → ~5k tok after archiving |
| **Fix** | §3 historical tables archived to TOKEN_USE_ARCHIVE.md; excluded from routine reads via system prompt |
| **Effort** | Low |
| **Status** | **Done** |

### 4.6 Observability Gap — ✅ RESOLVED

MCP backends instrumented: `file_read` (`c99223e`), `test_run` (`40391a5`), `git_op` (`cd0f026`) events now emitted via shared `log_emit` helper (`0b98f00`). Per-turn LLM logging added via `stream-json` (`28518aa`).

| Metric | Notes |
|--------|-------|
| Events now emitted | `file_read`, `test_run`, `git_op`, per-turn `llm_call` |
| **Status** | **Done** |

### 4.7 Context Accumulation — ✅ RESOLVED

Subagent-per-task architecture confirmed across all 25 sessions.

### 4.8 Tool Description Redundancy — ✅ RESOLVED

Shortened in commit f205653. ~500 tokens of redundancy removed.

### 4.9 DONE-Call Overhead — LOW PRIORITY

2/10 sessions are DONE-calls (22k cache each). Pre-spawn plan check (P3, Done) should eliminate these; if still occurring, the check may not be deployed or may not cover all code paths.

| Metric | Value |
|--------|-------|
| DONE-call rate | 20% (2/10) |
| Cost per DONE-call | ~$0.007 (Sonnet, 22k–44k cache) |
| Total DONE-call waste | ~$0.014/10 sessions |
| **Fix** | Verify pre-spawn plan check is deployed and covers ad-hoc endpoint |
| **Effort** | Low |

---

## 5. Optimization Plan

### 5.1 Enforce Turn Limits on Heavy Sessions [P0 — Low Effort, Highest Impact]

Session c5152d56 (49 turns) and session 7ae06422 (7.1M cache) show that complex tasks can run away. Claude Code supports `--max-turns N` to hard-cap LLM round-trips.

**Action:** Add `--max-turns 16` to the `claude --print` invocation in `server.py`. The ≤8 target in the system prompt is advisory; the flag makes it mandatory.

**Files:** `cluster/agent/claude/server.py`
**Impact:** Caps worst-case at ~16 turns (~560k cache Sonnet) instead of unbounded. Prevents sessions like 7ae06422 (7.1M cache).
**Savings:** Up to 6.5M cache tokens per runaway session (~$1.95 Sonnet, ~$9.75 Opus).

### 5.2 Default All /ask Tasks to Sonnet [P0 — Low Effort, High Impact]

Route all `/ask` invocations to `claude-sonnet-4-6` by default. Reserve Opus for `/plan` or explicit user opt-in.

**Files:** `cluster/agent/claude/server.py` (default model config)
**Impact:** 80% cost reduction on Opus sessions. With 10% Opus usage remaining, this saves ~$0.77 per affected session.

### 5.3 Truncate Test Output on Pass [P1 — Low Effort, High Impact]

On pass: return `{"status":"pass","exit_code":0}`. On fail: last 50 lines only.

**Files:** `cluster/tester/main.go`, `cluster/agent/claude/tester_mcp.py`
**Impact:** 2,000–15,000 tokens removed from context per passing task; 4,000–30,000 fewer cache tokens in subsequent turns.

### 5.4 Instrument MCP Backends [P1 — Medium Effort, High Value]

Emit `file_read`, `test_run`, `git_op` events from Go backend servers to log-server.

**Files:** `mcp-server/main.go`, `cluster/tester/main.go`, `cluster/git-server/main.go`, `docker-compose.yml`
**Impact:** Enables data-driven measurement of all waste categories. Unblocks P4 SHA256 dedup detection.

### 5.5 Add Blocking `get_test_results` [P2 — Medium Effort, Medium Impact]

Add `wait=true` query parameter to tester-server. Server holds connection until test completes.

**Files:** `cluster/tester/main.go`, `cluster/agent/claude/tester_mcp.py`, system prompt
**Impact:** Eliminates 1–2 poll round-trips (~30k–78k cache tokens each).

### 5.6 Archive TOKEN_USE History [P2 — Low Effort, Low Impact]

Move historical session tables to a separate archive doc. Add system prompt exclusion for TOKEN_USE on routine tasks.

**Files:** `docs/TOKEN_USE.md`, system prompt
**Impact:** Prevents self-growth; eliminates ~11k tok on routine reads.

### 5.7 Verify Pre-Spawn Plan Check Deployment [P3 — Low Effort, Low Impact]

DONE-calls still observed (20%). Verify the pre-spawn check covers both plan-driven and ad-hoc endpoints.

**Files:** `cluster/agent/claude/server.py`
**Impact:** ~22k tokens + 7s per DONE-call eliminated.

### 5.8 Per-Turn LLM Logging [P3 — Medium Effort, High Observability Value]

Parse `--output-format json` for per-turn usage. Emit per-turn `llm_call` events with turn number. Session c5152d56 already shows this data is available — extend to all sessions.

**Files:** `cluster/agent/claude/server.py`, `cluster/log-server/main.go`
**Impact:** Full turn-level visibility into context growth curves.

---

## 6. Infrastructure Requirements

### 6.1 Claude Code CLI Flag Addition

| Change | File | Description |
|--------|------|-------------|
| Add `--max-turns 16` | `cluster/agent/claude/server.py` | Hard cap on LLM round-trips per subprocess |

### 6.2 Model Routing Configuration

| Change | File | Description |
|--------|------|-------------|
| Default model to Sonnet | `cluster/agent/claude/server.py` or env config | Route `/ask` to `claude-sonnet-4-6` unless user passes `model=claude-opus-4-6` |

### 6.3 tester-server: Blocking Wait + Output Truncation

| Change | File | Description |
|--------|------|-------------|
| Output truncation on pass | `cluster/tester/main.go` | Return minimal JSON on success; last 50 lines on fail |
| `wait=true` query param | `cluster/tester/main.go` | Hold connection until test completes |
| MCP wrapper update | `cluster/agent/claude/tester_mcp.py` | Use blocking call; remove poll explanation |

### 6.4 MCP Backend Log Instrumentation

| Service | File | Events to Emit |
|---------|------|----------------|
| mcp-server | `mcp-server/main.go` | `file_read: {path, bytes, sha256, duration_ms}` |
| tester-server | `cluster/tester/main.go` | `test_run: {exit_code, output_lines, duration_ms}` |
| git-server | `cluster/git-server/main.go` | `git_op: {operation, submodule_path, duration_ms}` |
| All three | `docker-compose.yml` | Add `LOG_SERVER_URL=https://log-server:8443` |

### 6.5 Documentation Changes

| Change | File | Description |
|--------|------|-------------|
| Archive TOKEN_USE history | `docs/TOKEN_USE.md` | Move §3 historical tables to separate archive |
| Exclude from routine reads | system prompt | Add exclusion for TOKEN_USE docs on non-analysis tasks |

---

## 7. Prioritized Action Items

| Priority | Item | Category | Current Waste | Expected Savings | Effort | Status |
|----------|------|----------|---------------|------------------|--------|--------|
| P0 | Add `--max-turns 16` to `claude --print` invocation | Runaway Prevention | Up to 7.1M cache tok/session ($1.95–$9.75) | Caps worst-case at ~560k cache | Low | Open |
| P0 | Default `/ask` to Sonnet — reserve Opus for explicit opt-in | Model Allocation | 5× cost premium on 10% of sessions | ~80% cost reduction on affected sessions | Low | Open |
| P1 | Truncate test output on pass — return `{"status":"pass"}` only; last 50 lines on fail | Infrastructure | 2,000–15,000 tok/task in context | 2,000–15,000 tok/task | Low | **Done** |
| P1 | Instrument mcp-server, tester-server, git-server to emit log events | Observability | All waste categories unquantifiable | Full per-tool visibility | Medium | **Done** |
| P2 | Add `wait=true` to `get_test_results` (server-side blocking) | Infrastructure | 1–2 poll round-trips (~30k–78k cache tok each) | 1–2 round-trips per tested task | Medium | **Done** |
| P2 | Split `ARCHITECTURE.md` → overview + detail; update system prompt | Documentation | ~7,000–9,000 tok/routine task | ~7,000–9,000 tok/task | Low | **Done** |
| P2 | Archive TOKEN_USE history; exclude from routine reads | Context Hygiene | ~11,000 tok if read on non-analysis tasks | Caps doc growth; eliminates ~11k tok | Low | Open |
| P3 | Pre-spawn plan check in `server.py` — skip subprocess if no pending task | Infrastructure | ~22k tok + 7s per DONE call | 22k tok per no-op | Low | **Done** |
| P3 | Verify pre-spawn check covers ad-hoc endpoint (DONE-calls still at 20%) | Infrastructure | ~22k tok/DONE-call | Eliminates remaining DONE-calls | Low | **Done** |
| P3 | Per-turn LLM event logging (parse `--output-format json`) | Observability | Round-trip counts invisible | Full turn-level visibility | Medium | **Done** |
| P4 | Shorten tool descriptions (submodule_path + async explanation) | Tool Descriptions | ~500 tok/call (cached) | ~500 tok/call | Low | **Done** |
| P4 | Enable SHA256 dedup detection for file reads via log analysis | Observability | Unknown (est. ~500–5k tok/dup) | Unknown until P1 instrumentation | Low | **Done** |

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
| `≤8 LLM round-trips per task` budget ceiling | Prompt | Advisory cap on runaway sessions |
| Prompt caching (Anthropic API) | Infrastructure | 10× reduction on fixed overhead ($0.30 vs $3.00/MTok) |
| Shortened tool descriptions | Tool Descriptions | ~500 tok/call removed from cached baseline |
| Pre-spawn plan check | Infrastructure | ~22k tok + startup cost per no-op (when it triggers) |
| Truncated test output (pass: minimal JSON; fail: last 50 lines) | Infrastructure | 2,000–15,000 tok/task removed from context |
| MCP backend log instrumentation (file_read, test_run, git_op events) | Observability | Full per-tool visibility enabled |
| Blocking `wait=true` on `get_test_results` | Infrastructure | 1–2 poll round-trips eliminated per tested task |
| Intra-loop plan check covers ad-hoc endpoint | Infrastructure | Eliminates remaining DONE-call overhead |
| Per-turn LLM event logging (stream-json + _log_llm_turns) | Observability | Full turn-level visibility into context growth |
| SHA256 dedup detection endpoint in log-server (get_file_dedup_report) | Observability | Per-session duplicate file read visibility |
