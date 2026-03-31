# Planning Document: Token Consumption Modeling Skill & Infrastructure

**Date:** 2026-03-31
**Status:** Planning
**Scope:** `/token-model` slash command and supporting infrastructure for LLM token consumption analysis

---

## 1. Overview

This document plans the implementation of a **token consumption modeling skill** (`/token-model`) and the infrastructure changes required to support it. The skill analyzes how an AI agent spends tokens across a session, identifies waste, and produces a prioritized optimization plan.

### Design Principles

1. **Project-agnostic** — The skill prompt contains no hardcoded paths. It references `docs/ARCHITECTURE.md` and generic project conventions, making it reusable across any workspace that follows the workspace interface.
2. **Context minimization as a first-class rule** — Modeled after `/threat-model`'s security-first approach: just as the threat model enforces security assessment before code review, the token model enforces context hygiene assessment before flow analysis.
3. **Log-driven analysis** — Requires real session data from server logs, necessitating a new MCP log service.
4. **Actionable output** — The analysis ends with a prioritized table of action items (matching the format established by `docs/THREAT_MODEL.md`).

---

## 2. Skill Prompt Design

### Location

```
cluster/agent/prompts/commands/token-model.md
```

Baked into the claude-server image at build time via `COPY agent/prompts/commands/ /home/appuser/.claude/commands/`. Invoked as `/token-model`.

### Structure (Modeled on `/threat-model`)

The `/threat-model` prompt follows this pattern:
1. Role assignment → 2. Objective → 3. Step-by-step instructions → 4. Output format requirements

The `/token-model` prompt follows the same pattern but adds an explicit **Rules** section (placed before Instructions) to enforce mandatory analysis ordering:

| Section | Purpose |
|---------|---------|
| **Role** | "Expert in LLM token economics and AI agent efficiency" |
| **Objective** | Analyze token consumption, identify waste, produce prioritized optimization plan |
| **Rule 1: Context Minimization** | Mandatory first assessment — project structure, session isolation, doc scoping, tool description bloat, file read discipline. Findings reported before any flow analysis. |
| **Rule 2: Use Architecture Docs** | Read `docs/ARCHITECTURE.md`, map components to token-consuming operations |
| **Rule 3: Use Server Logs** | Query log MCP service for real data; if unavailable, specify what data is needed |
| **Rule 4: Quantify Everything** | Every finding requires: current cost, proposed fix, expected savings, effort level |
| **Instructions** | 7-step analysis workflow |
| **Output Format** | Structured `docs/TOKEN_USE.md` ending with prioritized action items table |

### Rule 1: Context Minimization — Rationale

This is the most important design decision. Just as `/threat-model` starts with trust boundaries before analyzing attack vectors, `/token-model` starts with **structural context decisions** before analyzing token flows.

Context size is the single largest driver of token cost. Every LLM round-trip re-sends the full conversation history. Structural decisions that reduce context have **multiplicative** savings:

| Context Minimization Check | What It Catches |
|----------------------------|-----------------|
| Project decomposition into sub-projects with own `docs/`, `CLAUDE.md`, `CONTEXT.md` | Monolith projects where the agent ingests the entire codebase context for every task |
| Documentation scoping | Bloated `CONTEXT.md` files with irrelevant information re-sent on every call |
| Session isolation (one session per task vs. accumulated) | Task N paying for the context of tasks 1..N-1 |
| Tool description bloat | Verbose MCP tool schemas multiplied by round-trip count |
| File read discipline | Duplicate reads, reading files that aren't edited |

These are reported as **context debt** — the token equivalent of tech debt.

### Output Format — Prioritized Action Items

Following the pattern from `docs/THREAT_MODEL.md`, the analysis must end with a prioritized action table:

```markdown
## 7. Prioritized Action Items

| Priority | Item | Category | Current Waste | Expected Savings | Effort | Status |
|----------|------|----------|---------------|------------------|--------|--------|
| P1 | Sub-agent per task (session isolation) | Architecture | ~40-60% context waste | 40-60% total tokens | High | Open |
| P1 | Increase test poll delays to 15s/30s | Prompt | 5+ wasted polls/cycle | ~30% per-task | Low | Open |
| P2 | Make run_tests blocking | Infrastructure | All poll round-trips | 100% poll waste | Medium | Open |
| P2 | Truncate test output on success | Infrastructure | Full stdout in context | Variable | Low | Open |
| P3 | Route planning to Sonnet | Configuration | Opus cost on simple tasks | ~70% planning cost | Low | Open |
| P3 | Trim MCP tool descriptions | Prompt | Verbose schemas × N calls | Variable | Low | Open |
| P4 | Read-and-edit-in-same-turn prompt rule | Prompt | 1-2 duplicate reads/task | 1-2 round-trips/task | Low | Open |
```

The table uses `Open / In Progress / Done` status tracking, matching the threat model's convention. Items are ordered by impact-to-effort ratio.

---

## 3. Infrastructure Requirements

### 3.1 Log MCP Service (New)

The token model skill requires access to server logs for real session analysis. Currently, logs are only available inside container stdout/stderr and are not queryable by the agent.

**Proposed: `log-server`** — A new MCP service providing structured log queries.

#### Requirements

| Requirement | Detail |
|-------------|--------|
| **Data sources** | LLM call logs (timestamps, model, token counts), MCP tool call logs (tool name, request/response sizes), test execution logs, file read logs (path, size, SHA256) |
| **Query interface** | MCP tools: `query_logs(session_id, filter, time_range)`, `list_sessions()`, `get_session_summary(session_id)` |
| **Security** | Own API token (`LOG_API_TOKEN`), `int_net` only, read-only access to log storage, no access to `/workspace`, `/gitdir`, `/plans`, or secrets |
| **Storage** | Structured JSON log files or SQLite, rotated by session. Stored in a host bind mount (`logs/`) separate from workspace |
| **Privacy** | No file content in logs (only paths and SHA256). No token values in logs (redacted). Query content truncated |
| **Network** | `int_net` only, `:8443` (internal HTTPS), internal CA cert |

#### Architecture Fit

```
claude-server
  └─ log_mcp.py (new stdio wrapper) ─HTTPS→ log-server:8443 (LOG_API_TOKEN)

Log ingestion:
  claude-server stdout/stderr ─→ Docker log driver ─→ log-server storage
  (or: each MCP server writes structured logs to shared log volume)
```

#### MCP Tools

| Tool | Parameters | Returns |
|------|-----------|---------|
| `list_sessions` | `limit`, `since` | Session IDs with timestamps and summary stats |
| `get_session_summary` | `session_id` | Total LLM calls, total tokens, tool call counts, task count, duration |
| `query_logs` | `session_id`, `event_type` (llm_call, tool_call, file_read, test_run), `time_range` | Structured log entries matching filter |
| `get_token_breakdown` | `session_id` | Per-call token counts: input tokens, output tokens, cache read/write, model |

#### Log Events to Capture

| Source | Event | Fields |
|--------|-------|--------|
| claude-server | LLM call start/end | timestamp, model, input_tokens, output_tokens, cache_read_tokens, duration_ms |
| claude-server | Tool call | timestamp, tool_name, request_size_bytes, response_size_bytes |
| mcp-server | File read | timestamp, path, size_bytes, sha256 |
| mcp-server | File write | timestamp, path, size_bytes |
| tester-server | Test start/end | timestamp, exit_code, duration_ms, output_size_bytes |
| git-server | Git operation | timestamp, operation, submodule_path |
| plan-server | Plan operation | timestamp, operation, task_id |

### 3.2 Changes to Existing Services

| Service | Change | Purpose |
|---------|--------|---------|
| **tester-server** | Add `wait=true` parameter to `get_test_results` (blocks server-side until done, with timeout) | Eliminates poll loop — zero wasted round-trips on test waiting |
| **tester-server** | Truncate output to `{"status": "pass"}` on success; include stderr only on failure (last 50 lines) | Prevents successful test output from bloating context |
| **claude-server** | Structured JSON logging with token counts per LLM call | Provides data for log-server ingestion |
| **claude-server** | Sub-agent per task: spawn fresh `claude --print` session per plan task instead of accumulating context | Eliminates cross-task context accumulation (40-60% savings) |

### 3.3 Prompt Changes

| File | Change | Rationale |
|------|--------|-----------|
| System prompt (ask) | "Read and edit in same turn" | Prevents duplicate file reads |
| System prompt (ask) | Test poll delays: 15s initial, 30s retry, max 3 polls | Cuts 7+ polls to 2-3 |
| System prompt (ask) | "Batch git_add + git_commit in one response" | Saves 1 round-trip per commit |
| System prompt (plan) | Add round-trip budget constraint (≤8) | Planner creates tasks sized to executor budget |

---

## 4. Relationship to Existing Documents

| Document | Relationship |
|----------|-------------|
| `docs/ARCHITECTURE.md` | Input — the token model reads this to map components to token flows |
| `docs/THREAT_MODEL.md` | Pattern reference — the output format (prioritized action items table) follows this document's convention |
| `docs/token_consumption_analysis.md` | Predecessor — manual analysis that motivated this skill. The skill automates and extends this analysis |
| `cluster/agent/prompts/commands/threat-model.md` | Structural reference — the `/token-model` prompt mirrors the `/threat-model` prompt structure (role → objective → instructions → output format) |

---

## 5. Implementation Tasks

| # | Task | Files | Dependencies |
|---|------|-------|-------------|
| 1 | Create `/token-model` slash command prompt | `cluster/agent/prompts/commands/token-model.md` | None |
| 2 | Design log-server MCP service (API contract, log event schema) | `cluster/log-server/` (new) | None |
| 3 | Implement log-server Go service | `cluster/log-server/main.go` | Task 2 |
| 4 | Create `log_mcp.py` stdio wrapper in claude-server | `cluster/agent/src/log_mcp.py` | Task 3 |
| 5 | Add structured logging to claude-server | `cluster/agent/src/server.py` | Task 2 (schema) |
| 6 | Add structured logging to mcp-server, git-server, tester-server | Respective `main.go` files | Task 2 (schema) |
| 7 | Add log-server to Docker Compose | `docker-compose.yml`, certs, tokens | Tasks 3-4 |
| 8 | Implement blocking `wait=true` on `get_test_results` | `cluster/tester/main.go` | None |
| 9 | Implement test output truncation on success | `cluster/tester/main.go` | None |
| 10 | Add sub-agent-per-task mode to claude-server | `cluster/agent/src/server.py` | None |

---

## 6. Security Considerations

The log-server introduces a new component that must follow existing security patterns:

- **Own API token** (`LOG_API_TOKEN`) — added to token isolation matrix
- **No workspace access** — structurally separated, like plan-server
- **No secrets access** — verified at startup
- **Read-only log storage** — log-server reads; writers are the other services
- **Log content safety** — no file content, no token values, truncated queries (aligns with RR-5, RR-11, RR-17)
- **`int_net` only** — no external network access
- **`cap_drop: ALL`**, resource limits, non-root, internal CA TLS — matching all other containers
- **Startup isolation checks** — verify forbidden env vars and paths

---

## 7. Open Questions

1. **Log ingestion mechanism** — Docker log driver → shared volume, or each service writes directly to a shared log volume? Direct writes are simpler but create a shared mount.
2. **Log retention** — How many sessions to retain? Disk budget?
3. **Sub-agent isolation** — When spawning fresh sessions per task, how to pass task-specific context without re-reading all docs? Pre-populate a minimal context payload?
4. **Blocking test API** — Should `wait=true` be the default, or opt-in? If default, what's the timeout before fallback to async?
