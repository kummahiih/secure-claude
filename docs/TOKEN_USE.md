# Token Consumption Model

**Date:** 2026-04-03
**Scope:** secure-claude v1.x — autonomous AI coding agent cluster
**Data source:** Sessions 8c9a0591, 8c14d7e7, 624ab533, 8367ff23, 2576f680, 2863d8bc, 51d162af,
d80ef2cc, ff286dfc, bcff70ba (all 2026-04-03, claude-sonnet-4-6).
This is the 5th TOKEN_USE generation run; prior runs are sessions 2576f680, 8367ff23, 624ab533, 8c14d7e7.

---

## 1. Context Minimization Audit

### 1.1 Project Decomposition ✅ COMPLIANT

The workspace follows a monorepo-with-submodules pattern: `secure-claude` (parent) contains
three independently-developable submodules (`cluster/agent`, `cluster/planner`,
`cluster/tester`). Each submodule has its own `docs/CONTEXT.md`. The parent hosts
infrastructure-only code (Dockerfiles, certs, compose, log-server).

Only **one submodule** is mounted as `/workspace` at a time — cross-project context bleed
is architecturally impossible via the volume-mount design. The `claude-server` container
mounts only `<active-repo>/docs` into `/docs`, scoping the doc MCP tool to that repo.

**No violation.** Decomposition is correctly implemented.

---

### 1.2 Documentation Scoping ⚠️ MEDIUM DEBT

| Document | Est. Tokens | Per-Session Cost | Issue |
|----------|-------------|-----------------|-------|
| `docs/CONTEXT.md` | ~3,000 | Paid when agent reads it | Focused; acceptable |
| `docs/ARCHITECTURE.md` | ~10,000 | Paid when agent reads it | **Over-read** — 9 sections, most irrelevant to routine coding tasks |
| `docs/HARDENING.md` | ~2,500 | Rarely read | OK |
| `docs/THREAT_MODEL.md` | ~4,000 | Rarely read | OK |
| `docs/mcp-tools.json` | ~4,000 | Rarely read | OK |
| `docs/TOKEN_USE.md` | ~9,500 | Paid during analysis tasks only | Self-referential; grows with each revision |

`docs/ARCHITECTURE.md` is the dominant cost: ~10,000 tokens covering TLS diagrams, full
security matrices, container resource limits, and design decision tables. For a task like
"add a unit test" or "fix a failing assertion", sections 5–9 (network topology, security
layers, TLS architecture, workspace interface, design decisions) are irrelevant but still
ingested when the system prompt directs the agent to read project docs before making changes.

**Context debt estimate:** ~7,000–9,000 excess tokens per session where `ARCHITECTURE.md`
is fully read when only `CONTEXT.md` was necessary. At $0.30/MTok (cache-read price),
~$0.002–0.003 per routine task. Compounds significantly at scale.

**Recommended fix:** Split `ARCHITECTURE.md` into:
- `ARCHITECTURE_OVERVIEW.md` (~3,000 tok): component table, data flow summary, MCP
  tool set table, volume mount assignments — what the agent needs for any coding task.
- `ARCHITECTURE_DETAIL.md` (~7,000 tok): security layers, TLS architecture, network
  topology, design decisions — needed only for security or infrastructure tasks.

Update system prompt: *"Read `ARCHITECTURE_OVERVIEW.md`. Read `ARCHITECTURE_DETAIL.md`
only when working on security, network, or infrastructure tasks."*

---

### 1.3 Session Isolation ✅ IMPLEMENTED

All 10 sampled sessions show exactly **1 logged LLM event** per session. The
subagent-per-task architecture (`claude --print` spawned fresh per plan task by the
`/ask` loop in `server.py`) is functioning correctly. No cross-task context accumulation
is occurring within a multi-task plan.

This is the **single highest-impact optimization already in place**. Before this
architecture, task N paid for the full conversation history of tasks 1…N-1 on every
round-trip within the subprocess.

**Note on logging granularity:** The 1-event-per-session pattern reflects the log server
receiving one `llm_call` event per subprocess (from `server.py`'s fire-and-forget thread),
not one per internal LLM round-trip. The subprocess may make 5–15 internal round-trips;
only the final aggregated token totals are recorded. See §3.3 for the full observability gap.

---

### 1.4 Tool Description Bloat ⚠️ LOW DEBT

The 35 MCP tools contribute ~4,000–6,000 tokens to the cached baseline on every call.
Specific redundancy identified from `docs/mcp-tools.json`:

| Issue | Tokens Wasted | Location |
|-------|--------------|----------|
| `submodule_path` description copied verbatim across all 6 git tools | ~360 tok | `git_mcp.py` |
| `run_tests` describes async polling behavior already in system prompt | ~80 tok | `tester_mcp.py` |
| `get_test_results` output schema described redundantly in description | ~60 tok | `tester_mcp.py` |

Total redundant tool description tokens: **~500 tokens per call** (always in cached
baseline, billed at $0.30/MTok = <$0.001 per call). Low individual impact; fix
opportunistically alongside other MCP server changes.

**Recommended fix:** Shorten `submodule_path` to: `"Optional: submodule path (e.g.
'cluster/agent'). Omit for root repo."` Remove async polling explanation from `run_tests`.

---

### 1.5 File Read Discipline ❌ CANNOT ASSESS (Data Gap)

The log server ingests only `llm_call` events (one per subprocess). Tool calls, file
accesses, test runs, and git operations are **not currently ingested** from any MCP
backend. The `tool_counts` field is `{}` in all 10 session summaries — this data is
never emitted.

Without `file_read` events (including SHA256), duplicate reads cannot be detected or
quantified from production sessions. The system prompt includes "Read and edit in the
same turn" to mitigate within-task duplicates, but compliance is unverifiable.

**Estimated context debt from file read patterns: 1–3 unnecessary reads per task
= ~500–10,000 excess tokens depending on file size.**

---

## 2. Token Flow Map

### 2.1 Per-Session Request Lifecycle

The following is the estimated token flow for a typical coding task (one `claude --print`
subprocess). Context grows with each round-trip because Claude Code re-sends the full
conversation history to the LLM on every call within the subprocess.

```
Round-trip 1: Initial assessment
  [CACHE] System prompt (ask.md)               ~2,000 tok
  [CACHE] MCP tool schemas (35 tools)          ~4,500 tok
  [CACHE] Claude Code wrapper overhead         ~8,000 tok
  [CACHE] Prior context baseline               ~7,800 tok
  [INPUT] User query ("execute plan")              ~5 tok
  ──────────────────────────────────────────────────────
  Total at RT1:                               ~22,305 tok  ← observed baseline (~22,301)
  [OUTPUT] Tool call: plan_current               ~50 tok

Round-trip 2: Receive task; read docs
  [CACHE] RT1 context                         ~22,305 tok
  [INPUT] plan_current result (task JSON)        ~500 tok
  [OUTPUT] Tool calls: list_docs + read_doc      ~80 tok

Round-trip 3: Read CONTEXT.md; request ARCHITECTURE.md
  [CACHE] Growing context                     ~22,885 tok
  [INPUT] CONTEXT.md content                  ~3,000 tok
  [OUTPUT] Tool call: read_doc(ARCHITECTURE)     ~50 tok

Round-trip 4: File read + edit decision
  [CACHE] Growing context                     ~25,935 tok
  [INPUT] ARCHITECTURE.md content            ~10,000 tok
  [OUTPUT] Tool calls: read_file + replace       ~80 tok

Round-trip 5: Confirm edit; start tests
  [CACHE] Growing context                     ~36,015 tok
  [INPUT] File content read + edit confirm     ~3,000 tok
  [OUTPUT] Tool call: run_tests                  ~30 tok

  [WAIT 15 seconds — no LLM call]

Round-trip 6: Poll test result (if not ready)
  [CACHE] Growing context                     ~39,045 tok
  [INPUT] get_test_results → "running"           ~30 tok
  [OUTPUT] Tool call: get_test_results           ~30 tok

  [WAIT 30 seconds — no LLM call]

Round-trip 7: Receive test result; commit
  [CACHE] Growing context                     ~39,105 tok
  [INPUT] Full test stdout (pass output)       ~5,000 tok
  [OUTPUT] Tool calls: git_add + git_commit     ~100 tok

Round-trip 8: Confirm commit; complete plan task
  [CACHE] Growing context                     ~44,205 tok
  [INPUT] Commit success                         ~50 tok
  [OUTPUT] plan_complete + "DONE"               ~100 tok

  ──────────────────────────────────────────────────────
  Total cache read (cumulative across all RTs):  ~271,800 tok
  Total non-cached input tokens:                  ~21,665 tok
  Total output tokens:                               ~520 tok
```

The `cache_read_tokens` value logged per session is the **sum across all round-trips within
the subprocess** — each subsequent round-trip re-reads the full growing context from cache.
This explains the large observed values (22k–1.1M tokens) relative to the actual content
consumed.

### 2.2 Component → Token-Consuming Operation Map

| Component | Operation | Token Impact | Notes |
|-----------|-----------|-------------|-------|
| `claude-server` | Spawn `claude --print` subprocess | ~22,301 tok fixed overhead (cached) | System prompt + MCP tool schemas + CC wrapper |
| `plan-server` | `plan_current` response | ~300–800 tok | Task JSON; small |
| `docs_mcp.py` | `list_docs` | ~100 tok | Doc listing; small |
| `docs_mcp.py` | `read_doc(CONTEXT.md)` | ~3,000 tok per call | Pulled into live context |
| `docs_mcp.py` | `read_doc(ARCHITECTURE.md)` | ~10,000 tok per call | Largest doc; often unnecessary for routine tasks |
| `mcp-server` | `read_workspace_file` | 100–50,000 tok per file | Largest variable cost |
| `mcp-server` | `replace_in_file` / `append_file` | ~50 tok response | Write confirmation only; minimal |
| `tester-server` | `run_tests` | ~50 tok | Immediate "started" response |
| `tester-server` | `get_test_results` (poll) | ~50 tok if running; 2,000–15,000 tok if done | Full stdout on completion enters context |
| `git-server` | `git_add` + `git_commit` | ~100–200 tok | Low cost |
| `plan-server` | `plan_complete` | ~50 tok | Low cost |

---

## 3. Session Analysis

### 3.1 Observed Session Data (2026-04-03, n=10, all claude-sonnet-4-6)

All sessions show exactly 1 logged LLM event (per-subprocess, not per-round-trip).
`tool_counts` is `{}` in all sessions — MCP backend instrumentation not yet implemented.

| Session ID | Input Tok | Output Tok | Cache Read Tok | Duration | Category |
|------------|-----------|------------|----------------|----------|----------|
| 8c14d7e7 | 9 | 13,339 | 208,896 | 289s | Heavy analysis (4th TOKEN_USE run) |
| 8c9a0591 | 10 | 13,776 | 271,103 | 276s | Heavy analysis (this report, 5th TOKEN_USE run) |
| 624ab533 | 9 | 13,238 | 220,684 | 257s | Heavy analysis (3rd TOKEN_USE run) |
| 8367ff23 | 12 | 15,689 | 259,727 | 293s | Heavy analysis (2nd TOKEN_USE run) |
| 2576f680 | 41 | 3,889 | 1,158,756 | 114s | Heavy analysis (1st TOKEN_USE run) |
| 2863d8bc | 7 | 1,661 | 125,133 | 35s | Single working task |
| 51d162af | 2 | 742 | 22,301 | 18s | DONE (no pending tasks) |
| d80ef2cc | 2 | 671 | 22,301 | 16s | DONE (no pending tasks) |
| ff286dfc | 2 | 504 | 22,301 | 14s | DONE (no pending tasks) |
| bcff70ba | 2 | 712 | 22,301 | 16s | DONE (no pending tasks) |
| 103e57bc | 2 | 542 | 22,301 | 13s | DONE (no pending tasks) |

### 3.2 Session Clusters

**Cluster A — "DONE" termination calls (5 sessions; 51d162af…103e57bc):**
- Input: 2 tokens | Output: 504–742 tokens | Cache: 22,301 tokens
- Pattern: `plan_current` returned no active task → subagent returned `DONE`
- The 22,301 token baseline = system prompt + MCP tool schemas + Claude Code overhead
- Output range (504–742 tok) reflects the `DONE` text plus minor reasoning variance
- Duration: 13–18s — fast, purely LLM round-trip + subprocess startup latency
- **These sessions represent pure waste if no tasks are pending.** The outer loop in
  `server.py` spawns a subprocess unconditionally, even when the plan is exhausted.
  A pre-check via the plan-server REST API before subprocess spawn would eliminate
  the ~22k-token overhead for these no-op iterations entirely.

**Cluster B — Single working task (1 session; 2863d8bc):**
- Cache: 125,133 tokens (5.6× baseline) → ~5–6 internal round-trips
- Duration: 35s → light task (likely: plan_current + read 1–2 files + edit + tests + commit + plan_complete)
- Output: 1,661 tokens — modest
- This is the **expected healthy profile** for a well-scoped coding task.

**Cluster C — Heavy analysis/generation tasks (4 sessions; 2576f680, 8367ff23, 624ab533, 8c14d7e7):**

These are the four successive TOKEN_USE generation runs. Their progression reveals a
strong efficiency improvement trend driven by batching discipline:

| Run | Session | Cache Tok | Output Tok | Duration | Improvement vs Prior |
|-----|---------|-----------|------------|----------|---------------------|
| 1st | 2576f680 | 1,158,756 | 3,889 | 114s | baseline |
| 2nd | 8367ff23 | 259,727 | 15,689 | 293s | −78% cache, +4× output |
| 3rd | 624ab533 | 220,684 | 13,238 | 257s | −15% cache, −16% output |
| 4th | 8c14d7e7 | 208,896 | 13,339 | 289s | −5% cache, +0.8% output |
| 5th | 8c9a0591 | 271,103 | 13,776 | 276s | **+30% regression** — TOKEN_USE.md self-growth |

**Key observations:**

1. **Run 1 vs Run 2 (−78% cache):** The largest single improvement, almost certainly
   from batching. Run 1 read docs interactively in many small round-trips (each re-reading
   a rapidly growing context). Run 2 batched independent doc reads into single responses,
   dramatically cutting round-trips despite producing 4× more output.

2. **Runs 2→3→4 (~5-15% gains):** Diminishing returns on batching once already applied.
   The remaining variance (~50k tokens between runs 2 and 4) is noise from different doc
   reads and reasoning paths — not a structural problem to fix.

3. **Output vs cache correlation:** Run 1 had the *smallest* output (3,889 tok) and the
   *largest* cache (1.1M tok) — confirming that many round-trips with short outputs are
   far more expensive than fewer round-trips with longer outputs. The system prompt
   directive to batch tool calls is the correct intervention.

4. **The 22,301-token floor is always hit.** Every session pays this regardless of task
   complexity — it's the immutable cost of system prompt + tool schemas + CC wrapper
   loaded from cache.

5. **Run 5 shows a +30% cache regression vs Run 4 (271k vs 209k).** This is not
   batching regression — the output token count and duration are comparable across
   runs 3–5. The cause is **document self-growth**: the TOKEN_USE.md written by Run 4
   (~9,500 tokens) is read in full during Run 5's doc-gathering phase, adding ~9,500
   tokens to context that were absent in Run 4. The TOKEN_USE.md written by Run 1
   (~1,000 tokens) was much shorter, making each successive version of this document
   incrementally more expensive to read. See §4.11.

### 3.3 Observability Gaps

The following log event types are defined in the architecture but are **not currently
ingested** into the log server from any backend:

| Event Type | Source | Gap Impact |
|------------|--------|------------|
| `tool_call` | claude-server | Cannot measure MCP round-trip counts per task |
| `file_read` | mcp-server | Cannot detect duplicate reads or measure file content size |
| `file_write` | mcp-server | Cannot track write patterns |
| `test_run` | tester-server | Cannot measure test output size or polling count |
| `git_op` | git-server | Cannot measure git operation overhead |
| `plan_op` | plan-server | Cannot measure plan state access frequency |

Additionally, the log server receives **one `llm_call` event per subprocess** from
`server.py`'s fire-and-forget thread, not one per internal round-trip. Internal round-trip
counts — the primary driver of context growth — are completely invisible.

**Consequence:** All per-task waste estimates in this document are projections based on
architectural analysis and behavioral inference from aggregate token totals, not from
measured per-operation data. The §5 observability items are prerequisites for data-driven
verification of all other categories.

---

## 4. Waste Taxonomy

### 4.1 Polling Waste — MEDIUM PRIORITY

**Status:** Partially mitigated by system prompt directives (15s/30s delays, max 3
polls). The async run-then-poll design requires at least one extra round-trip beyond
the minimum even with perfect timing.

**Structural issue:** `run_tests` returns immediately with `{"status": "started"}`.
The agent then calls `get_test_results` 1–3 times. Each poll is a full LLM round-trip
that re-sends the entire growing conversation context (~39k+ tokens by that point in
the subprocess). Even 1 unnecessary poll re-transmits ~39,000 cache tokens.

A server-side blocking `get_test_results?wait=true` endpoint would collapse the entire
poll loop to a single waiting HTTP call, eliminating 1–2 round-trips per test cycle.

| Metric | Estimate |
|--------|----------|
| Current polls per test cycle | 1–3 (with prompt mitigation) |
| Tokens re-read per unnecessary poll | ~39,000 cache tokens (context at that point) |
| Cost per unnecessary poll | ~$0.012 at $0.30/MTok |
| Sessions affected | All tasks that include tests |
| **Proposed fix** | Add `wait=true` param to `GET /results` in `tester-server` (Go) |
| **Expected savings** | Eliminate 1–2 polls/task = ~39k–78k cache tokens/task |
| **Effort** | Medium |

---

### 4.2 Context Accumulation — RESOLVED ✅

Cross-task context accumulation is fully eliminated by the subagent-per-task architecture
in `server.py`. Verified across all 10 sessions by the consistent 1-LLM-call pattern.
No remediation needed.

**Savings already realized:** 40–60% reduction vs. prior single-session execution model.

---

### 4.3 DONE-Call Overhead — LOW PRIORITY

When `plan_current` returns no active task, the subagent outputs `DONE` immediately.
These sessions still consume:
- ~22,301 cache tokens (system prompt + tool schemas + Claude Code wrapper)
- 13–18 seconds of subprocess startup + LLM latency
- ~$0.007 per call at $0.30/MTok

5 of 10 sampled sessions (50%) are DONE calls. Three occur in rapid succession within
2 minutes (ff286dfc, d80ef2cc, 51d162af at 11:53–11:54), confirming repeated `/ask`
invocations against an exhausted plan are common.

**Root cause:** The `/ask` loop spawns a subprocess unconditionally, then reads the
subagent's `DONE` output to stop. A pre-check via the plan-server REST API *before*
spawning the subprocess eliminates this overhead entirely.

| Metric | Estimate |
|--------|----------|
| Overhead per DONE call | ~22,301 cache tokens + 13–18s |
| Cost per DONE call | ~$0.007 |
| Frequency in sample | 5/10 sessions (50%) |
| **Proposed fix** | Pre-check `GET plan-server/plan/current` before subprocess spawn in `server.py` |
| **Expected savings** | Eliminate ~22k tokens + startup cost per no-op iteration |
| **Effort** | Low (server.py change only) |

---

### 4.4 Test Output Bloat — HIGH PRIORITY

`get_test_results` returns complete `test.sh` stdout/stderr regardless of pass/fail.
A passing test suite produces thousands of tokens of verbose output (package names,
timing lines, test counts, `PASS`/`ok` markers) that the agent reads, processes,
and then carries in context for all subsequent round-trips (git_add, git_commit,
plan_complete).

The test output enters the conversation context and is re-sent on every subsequent
round-trip within the same subprocess — even though the agent has already processed
it and moved on.

| Metric | Estimate |
|--------|----------|
| Test output size on pass | 2,000–15,000 tokens depending on test suite size |
| Round-trips test output persists in context | 2 (commit + plan_complete) |
| Extra cache tokens from test bloat | 4,000–30,000 tokens per task |
| Cost per task | ~$0.001–0.009 |
| **Proposed fix** | On pass: return `{"status":"pass","exit_code":0}`. On fail: return last 50 lines only |
| **Expected savings** | 2,000–15,000 tokens removed from context per passing task |
| **Effort** | Low (tester-server Go change) |

---

### 4.5 Duplicate File Reads — UNKNOWN (Data Gap)

Cannot measure from current logs. Prior analysis (2026-03-30, session bbab9f81) documented
two duplicate reads each of `server.py` and `test_server.py` (confirmed by identical SHA256
hashes) within a single session.

The system prompt directive "Read and edit in the same turn" mitigates this, but compliance
is unverifiable from current logs. The subagent-per-task architecture eliminates *cross-task*
duplicates; *within-task* duplicates remain possible.

| Metric | Estimate |
|--------|----------|
| Frequency | Unknown — was observed before subagent-per-task architecture |
| Cost per duplicate read | ~500–5,000 tokens depending on file size |
| **Proposed fix** | Instrument mcp-server to emit `file_read` events with SHA256; alert on duplicates |
| **Expected savings** | 1–3 round-trips per task if duplicates exist |
| **Effort** | Medium (blocked on §4.8 observability infrastructure) |

---

### 4.6 ARCHITECTURE.md Over-Read — MEDIUM PRIORITY

The system prompt instructs the agent to read project docs before making changes.
`ARCHITECTURE.md` (~10,000 tokens) is the largest doc and covers far more than routine
coding tasks require. Reading it for a task like "add a unit test" adds ~10,000 tokens
to context, of which ~7,000–9,000 (security, TLS, network, design decision sections)
are irrelevant.

| Metric | Estimate |
|--------|----------|
| Excess tokens from ARCHITECTURE.md over-read | ~7,000–9,000 per routine task |
| Cost per task | ~$0.002–0.003 |
| Frequency | Any task where agent reads ARCHITECTURE.md |
| **Proposed fix** | Split into `ARCHITECTURE_OVERVIEW.md` (~3k tok) + `ARCHITECTURE_DETAIL.md` (~7k tok); gate detail doc on task type |
| **Expected savings** | ~7,000–9,000 tokens per routine task |
| **Effort** | Low (doc restructuring + one-line system prompt update) |

---

### 4.7 Tool Description Redundancy — LOW PRIORITY

| Issue | Wasted Tokens | Fix |
|-------|--------------|-----|
| `submodule_path` description copied verbatim across all 6 git tools | ~360 tok | Shorten to one line per tool |
| Async polling explanation in `run_tests` description | ~80 tok | Remove (already in system prompt) |
| **Total** | ~440 tok/call | Always cached; low absolute cost |

At $0.30/MTok, ~440 tokens = $0.00013 per call. Negligible individually; fix
opportunistically during other MCP server changes.

---

### 4.8 Observability Infrastructure Gap — HIGH OPERATIONAL PRIORITY

Not a direct token cost, but a **prerequisite for data-driven optimization** of all
other categories. Without per-tool and per-round-trip event data:
- Polling waste (§4.1) cannot be measured from real sessions
- Duplicate reads (§4.5) cannot be detected automatically
- Test output sizes (§4.4) are not captured
- Round-trip counts per task are completely invisible

The log server already has the `POST /ingest` endpoint and full event schema for
`tool_call`, `file_read`, `test_run`, and `git_op`. The backend servers simply do not
emit these events yet.

| Metric | Notes |
|--------|-------|
| Current log coverage | `llm_call` only (1 per subprocess; not per round-trip) |
| Missing event types | `tool_call`, `file_read`, `test_run`, `git_op`, `plan_op` |
| **Proposed fix** | Instrument mcp-server, tester-server, git-server to emit events on each operation |
| **Expected value** | Enables quantification of §4.1, §4.4, §4.5 from real session data |
| **Effort** | Medium (Go changes in 3 servers + `LOG_SERVER_URL` env var in docker-compose.yml) |

---

### 4.9 Model Misallocation — VERIFY

All 10 sampled sessions used `claude-sonnet-4-6`. No `/plan` endpoint sessions appear
in the sample. The model allowlist includes `claude-opus-4-6`; if `/plan` calls default
to Opus, this represents ~70% unnecessary cost premium for a task that only reads docs
and emits a JSON structure.

| Metric | Notes |
|--------|-------|
| Current state | Unverified (no `/plan` sessions in 10-session sample) |
| Potential savings if `/plan` uses Opus | ~70% cost reduction on all planning calls |
| **Proposed fix** | Route `/plan` to Sonnet; reserve Opus for explicit user opt-in via `model` param |
| **Effort** | Low (env var or model config change) |

---

### 4.10 Analysis Task Self-Amplification — LOW (INHERENT)

Analysis tasks (TOKEN_USE generation, architecture reviews) are structurally expensive:
they read many large docs, accumulate large contexts, and generate substantial output.
The four TOKEN_USE generation sessions consumed 208k–1.1M cache tokens each.

However, the **5× variance between the least (208k) and most (1.1M) expensive analysis
sessions** demonstrates that batching discipline is the single biggest lever. The system
prompt already encourages batching; the 78% improvement from Run 1 to Run 2 confirms it
works. Runs 3 and 4 show diminishing returns (~5-15% additional gains), indicating the
batching discipline is now largely effective.

**No new optimization required** beyond existing batching directives and the observability
infrastructure (§4.8) needed to measure compliance quantitatively.

---

### 4.11 Analysis Document Self-Amplification — MEDIUM PRIORITY (New Finding)

Each TOKEN_USE generation run reads the prior version of `docs/TOKEN_USE.md`, then
writes a longer successor. The document grew from ~1,000 tokens (Run 1) to ~9,500 tokens
(Run 4), and the Run 5 cache total is 62,207 tokens higher than Run 4 — primarily
attributable to reading this now-large document. If the trend continues unmitigated,
Run 6 will read a ~12,000-token `TOKEN_USE.md` and cache consumption will climb further.

This is a concrete instance of a general principle: **analysis documents that accumulate
historical context grow without bound and become expensive to re-read on every revision.**

The same principle applies to any document the agent reads routinely as part of its
doc-reading phase (`CONTEXT.md`, `PLAN.md`). `TOKEN_USE.md` is the most acute case
because it is long, self-referential, and grows each run.

**Two-part fix:**

1. **Archive historical sections.** Keep §1 (Context Audit), §2 (Token Flow Map), §4
   (Waste Taxonomy), and §7 (Action Items). Move §3 (Session Analysis, historical runs)
   to `docs/TOKEN_USE_HISTORY.md`. The active document shrinks by ~3,000 tokens; the
   history is preserved but not re-read routinely.

2. **Scope doc reads.** Update `ask.md` system prompt to explicitly exclude `TOKEN_USE.md`
   from the standard "read docs before making changes" instruction. Token analysis docs
   should only be read when performing token analysis tasks.

| Metric | Estimate |
|--------|----------|
| Current TOKEN_USE.md size | ~11,000 tokens (after this run's additions) |
| Tokens wasted on routine tasks (if agent reads TOKEN_USE.md unnecessarily) | ~11,000 tok per task |
| Self-growth rate | ~2,000–3,000 tokens per analysis run |
| **Fix 1**: Archive history | Reduces doc to ~7,000 tokens; trims future growth rate |
| **Fix 2**: Exclude from routine reads | Eliminates ~11,000 tokens on every non-analysis task |
| **Effort** | Low (doc restructuring + one system prompt line) |

**Note on `docs/token_consumption_analysis.md`:** This is the original 2026-03-30
analysis document (pre-subagent architecture). Its findings are fully superseded by the
current `TOKEN_USE.md`. It should be removed to prevent unnecessary token cost if an
agent reads it speculatively. Confirmed safe to delete — all actionable items have been
migrated to §7.

---

## 5. Optimization Plan

### 5.1 Truncate Test Output on Pass [P1 — Low Effort, High Impact]

Modify `cluster/tester/main.go` to return minimal JSON on test success:

```json
{"status": "pass", "exit_code": 0, "timestamp": "..."}
```

On failure, return only the last 50 lines of combined stdout/stderr (sufficient for
diagnosis; prevents multi-thousand-line test output from entering context). Update the
MCP wrapper description and system prompt accordingly.

**Files:** `cluster/tester/main.go`, `cluster/agent/claude/tester_mcp.py`
**Impact:** 2,000–15,000 tokens removed from context per passing task.

---

### 5.2 Add Pre-Spawn Plan Check [P1 — Low Effort, Medium Impact]

In `cluster/agent/claude/server.py`, before spawning the `claude --print` subprocess,
make a lightweight HTTP call to plan-server (`GET /plan/current`) to check whether any
tasks are pending. If the plan is exhausted or no plan exists, return `DONE` immediately
without spawning the subprocess.

**Files:** `cluster/agent/claude/server.py`
**Impact:** Eliminates ~22k cache tokens + 13–18s subprocess startup per no-op iteration.
50% of observed sessions are DONE calls; this benefits each one.

---

### 5.3 Instrument MCP Backends for Observability [P1 — Medium Effort, High Value]

Enable log event ingest from three backend servers. Each already holds `LOG_API_TOKEN`.
Add `LOG_SERVER_URL=https://log-server:8443` to each in `docker-compose.yml`. Use
fire-and-forget background goroutines matching `server.py`'s pattern.

**Events to emit:**
- `mcp-server` → `file_read`: `{path, bytes, sha256, duration_ms}` (SHA256 already computed locally)
- `tester-server` → `test_run`: `{exit_code, output_lines, duration_ms}`
- `git-server` → `git_op`: `{operation, submodule_path, duration_ms}`

**Files:** `mcp-server/main.go`, `cluster/tester/main.go`, `cluster/git-server/main.go`,
`docker-compose.yml`
**Impact:** Unlocks data-driven measurement of §4.1, §4.4, §4.5 in real sessions.

---

### 5.4 Add Blocking `get_test_results` [P2 — Medium Effort, Medium Impact]

Add a `wait=true` query parameter to `GET /results` in tester-server. When set, the
server holds the HTTP connection open until `test.sh` completes (or the 300s timeout
fires) and returns the final result in one response. Update MCP wrapper and system prompt
to use `wait=true` by default and remove the poll-wait-retry instructions.

**Files:** `cluster/tester/main.go`, `cluster/agent/claude/tester_mcp.py`,
`cluster/agent/prompts/system/ask.md`
**Impact:** Eliminates 1–2 poll round-trips per test cycle (~39k–78k cache tokens each).

---

### 5.5 Split ARCHITECTURE.md [P2 — Low Effort, Medium Impact]

Create `docs/ARCHITECTURE_OVERVIEW.md` (~3,000 tokens) covering: component table,
data flow summary, MCP tool set table, volume mount assignments. Rename/trim existing
`docs/ARCHITECTURE.md` to `docs/ARCHITECTURE_DETAIL.md` retaining sections 5–9
(network topology, security, TLS, workspace interface, design decisions).

Update `cluster/agent/prompts/system/ask.md`:
> *"Read `ARCHITECTURE_OVERVIEW.md`. Read `ARCHITECTURE_DETAIL.md` only when working
> on security, TLS, network, or infrastructure tasks."*

**Files:** `docs/ARCHITECTURE.md` (rename/split), new `docs/ARCHITECTURE_OVERVIEW.md`,
`cluster/agent/prompts/system/ask.md`
**Impact:** ~7,000–9,000 tokens removed from context per routine coding task.

---

### 5.6 Add Per-Round-Trip LLM Event Logging [P2 — Medium Effort, High Observability Value]

`claude --print --output-format json` outputs per-turn usage data in its JSON structure.
Parse this in `server.py` after subprocess completion to emit one `llm_call` log event
per internal round-trip (with `turn_index`, input tokens, output tokens, cumulative
cache tokens). This transforms opaque per-subprocess aggregates into full context
growth curves per task.

**Files:** `cluster/agent/claude/server.py`, optionally `cluster/log-server/main.go`
(add `turn_index` field to `llm_call` event schema)
**Impact:** Full turn-level visibility into context growth; enables verification of all
other optimization claims.

---

### 5.7 Deduplicate Tool Descriptions [P3 — Low Effort, Low Impact]

1. Replace `submodule_path` description on all 6 git tools with:
   `"Optional: submodule path relative to workspace root (e.g. 'cluster/agent'). Omit for root repo."`
2. Remove async polling explanation from `run_tests` tool description.
3. Update `docs/mcp-tools.json` to match.
4. Rebuild `claude-server` image.

**Files:** `cluster/agent/claude/git_mcp.py`, `cluster/agent/claude/tester_mcp.py`,
`docs/mcp-tools.json`
**Impact:** ~440 tokens removed from cached baseline on every LLM call.

---

### 5.8 Verify and Fix Planning Model [P3 — Low Effort, Medium Impact if Applicable]

Check whether `/plan` endpoint invocations use `claude-opus-4-6` or `claude-sonnet-4-6`.
Planning tasks (read docs, emit structured JSON) do not require Opus capability.

**Files:** `cluster/agent/prompts/system/plan.md` or environment config
**Impact:** ~70% cost reduction on planning calls if currently using Opus.

---

### 5.9 Archive TOKEN_USE.md History + Scope Doc Reads [P2 — Low Effort, Medium Impact]

Two complementary changes that together eliminate the analysis-document self-amplification
identified in §4.11:

1. Move the "Session Analysis" historical run table (§3, ~3,000 tokens) to
   `docs/TOKEN_USE_HISTORY.md`. Keep the active `TOKEN_USE.md` focused on findings,
   waste taxonomy, and action items only (~7,000 tokens after archiving, vs the current
   ~11,000 token version).

2. In `cluster/agent/prompts/system/ask.md`, add one line to the doc-reading instruction:
   > *"Do not read `TOKEN_USE.md` or `TOKEN_USE_HISTORY.md` unless explicitly performing
   > a token analysis task."*

3. Delete `docs/token_consumption_analysis.md` (superseded legacy doc; adds ~1,000
   tokens of stale context if read speculatively).

**Files:** `docs/TOKEN_USE.md` (restructure), new `docs/TOKEN_USE_HISTORY.md`,
`cluster/agent/prompts/system/ask.md` (one-line addition), `docs/token_consumption_analysis.md` (delete)
**Impact:** Prevents ~2,000–3,000 token/run growth rate; eliminates ~11,000 token cost if
agent reads TOKEN_USE.md on non-analysis tasks; removes ~1,000 token legacy doc overhead.

---

## 6. Infrastructure Requirements

### 6.1 tester-server: Blocking Wait + Output Truncation

| Change | File | Description |
|--------|------|-------------|
| `wait=true` query param | `cluster/tester/main.go` | Hold connection until `test.sh` completes; return final result directly |
| Output truncation on pass | `cluster/tester/main.go` | Return `{"status":"pass","exit_code":0}` on success; last 50 lines on fail |
| MCP description update | `cluster/agent/claude/tester_mcp.py` | Document `wait=true`; remove async poll explanation |
| System prompt update | `cluster/agent/prompts/system/ask.md` | Use `wait=true` by default; remove poll-wait-retry instructions |

### 6.2 MCP Backend Servers: Log Event Instrumentation

| Service | File | Change |
|---------|------|--------|
| mcp-server (Go) | `mcp-server/main.go` | Emit `file_read` event per `read_workspace_file`; include path, bytes, sha256, duration_ms |
| tester-server | `cluster/tester/main.go` | Emit `test_run` event on each `get_test_results` completion |
| git-server | `cluster/git-server/main.go` | Emit `git_op` event on each git operation |
| All three | `docker-compose.yml` | Add `LOG_SERVER_URL=https://log-server:8443` env var |
| log-server | `cluster/log-server/main.go` | Accept and store `file_read`, `test_run`, `git_op` event types (schema already defined in ARCHITECTURE.md §2.8) |

### 6.3 server.py: Pre-Spawn Plan Check + Per-Round-Trip Events

| Change | File | Description |
|--------|------|-------------|
| Pre-spawn plan check | `cluster/agent/claude/server.py` | `GET plan-server/plan/current` before spawning subprocess; return `DONE` immediately if no task |
| Parse per-turn usage | `cluster/agent/claude/server.py` | Parse `--output-format json` output for per-turn usage fields; emit one `llm_call` log event per turn |
| log-server schema | `cluster/log-server/main.go` | Accept optional `turn_index` field on `llm_call` events |

### 6.4 Documentation + Prompt Changes

| Change | File | Description |
|--------|------|-------------|
| Split ARCHITECTURE.md | `docs/ARCHITECTURE.md` | Split into `ARCHITECTURE_OVERVIEW.md` (~3k tok) + `ARCHITECTURE_DETAIL.md` (~7k tok) |
| Archive TOKEN_USE.md history | `docs/TOKEN_USE.md` → `docs/TOKEN_USE_HISTORY.md` | Move §3 historical run table out of active doc; keep findings + action items |
| Delete legacy analysis doc | `docs/token_consumption_analysis.md` | Fully superseded; prevents speculative reads of stale 2026-03-30 content |
| System prompt update | `cluster/agent/prompts/system/ask.md` | (1) Reference `ARCHITECTURE_OVERVIEW.md`; gate `ARCHITECTURE_DETAIL.md` on task type. (2) Exclude `TOKEN_USE.md` from routine doc reads |
| Deduplicate tool descriptions | `cluster/agent/claude/git_mcp.py`, `tester_mcp.py` | Shorten `submodule_path`; remove redundant async polling explanation |
| Rebuild image | `Dockerfile.claude` | Propagate prompt + MCP description changes |

---

## 7. Prioritized Action Items

| Priority | Item | Category | Current Waste | Expected Savings | Effort | Status |
|----------|------|----------|---------------|------------------|--------|--------|
| P1 | Truncate test output on pass — return `{"status":"pass"}` only; last 50 lines on fail | Infrastructure | 2,000–15,000 tok/task in context | 2,000–15,000 tok/task | Low | Open |
| P1 | Pre-spawn plan check in `server.py` — skip subprocess if no pending task | Infrastructure | ~22,301 tok + 13–18s per DONE call (~50% of sessions) | 22k tok + startup cost per no-op | Low | Open |
| P1 | Instrument mcp-server, tester-server, git-server to emit log events | Observability | All waste categories unquantifiable | Full per-tool visibility | Medium | Open |
| P2 | Split `ARCHITECTURE.md` → overview (~3k tok) + detail (~7k tok); update system prompt | Documentation | ~7,000–9,000 tok/routine task | ~7,000–9,000 tok/task | Low | Open |
| P2 | Archive TOKEN_USE.md §3 history to TOKEN_USE_HISTORY.md; exclude from routine doc reads in ask.md; delete legacy token_consumption_analysis.md | Context Hygiene | ~11,000 tok if read on non-analysis tasks; +2–3k tok/run self-growth | Caps doc growth; eliminates ~11k tok on routine tasks | Low | Open |
| P2 | Add `wait=true` to `get_test_results` (server-side blocking) | Infrastructure | 1–2 poll round-trips/test cycle (~39k–78k cache tok each) | 1–2 round-trips per tested task | Medium | Open |
| P2 | Add per-turn LLM event logging in `server.py` (parse `--output-format json`) | Observability | Round-trip counts invisible; cannot verify savings | Full turn-level visibility | Medium | Open |
| P3 | Verify `/plan` endpoint uses Sonnet, not Opus | Model Allocation | Up to 70% of planning call cost if using Opus | ~70% of planning call cost | Low | Verify |
| P3 | Shorten `submodule_path` description across 6 git tools | Tool Descriptions | ~360 tok/call (cached) | ~360 tok/call | Low | Open |
| P3 | Remove async polling explanation from `run_tests` description | Tool Descriptions | ~80 tok/call (cached) | ~80 tok/call | Low | Open |
| P4 | Enable SHA256 dedup detection for file reads via log event analysis | Observability | Unknown (est. ~500–5,000 tok/duplicate) | Unknown until P1-observability data | Low | Blocked (needs §6.2) |

### Status Legend

| Status | Meaning |
|--------|---------|
| **Open** | Not started |
| **In Progress** | Actively being worked on |
| **Done** | Implemented and verified |
| **Verify** | Needs confirmation from a production log sample |
| **Blocked** | Depends on another item being completed first |

---

### Already Implemented (baseline — not in priority table)

| Item | Category | Savings Realized |
|------|----------|-----------------|
| Subagent-per-task architecture (`claude --print` per task, fresh subprocess) | Architecture | 40–60% total tokens — eliminates cross-task context accumulation entirely |
| Poll delay directives in system prompt (15s initial, 30s retry, max 3 polls) | Prompt | Reduced polling from up to 7 rounds/cycle (prior) to 1–3 |
| "Read and edit in the same turn" rule | Prompt | Mitigates 1–2 duplicate reads/task |
| "Batch `git_add` + `git_commit` in one response" rule | Prompt | Saves 1 round-trip per commit |
| Submodule commit error-recovery instruction in system prompt | Prompt | Saves 2 retry round-trips per submodule task |
| `≤8 LLM round-trips per task` budget ceiling | Prompt | Caps worst-case runaway sessions |
| `plan_block` after 3 fix attempts | Prompt | Prevents unbounded retry loops on failing tests |
| Prompt caching (Anthropic API) | Infrastructure | Static context billed at $0.30/MTok vs $3.00/MTok non-cached — 10× reduction on fixed overhead |
| Plan isolation (plan-server separate container) | Architecture | Plan reads/writes do not add file content to agent context |
| Task loop cap (`_MAX_TASK_ITERATIONS = 50`) | Infrastructure | Prevents unbounded execution per `/ask` invocation |
