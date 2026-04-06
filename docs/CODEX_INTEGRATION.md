# Codex Integration Plan

**Objective:** Introduce OpenAI's Codex agent (`@openai/codex`) to the Secure Claude architecture as a parallel, isolated service (`codex-server`). This allows utilizing both Claude Code and Codex on the same workspace, sharing the same MCP tools, while maintaining zero-trust credential handling and network isolation.

---

## 1. Container & Infrastructure Layer

### Dockerfile (`cluster/Dockerfile.codex`)
* **Base:** Create a new Dockerfile cloning the structure of `Dockerfile.claude`.
* **Dependencies:** Install Python (for FastAPI server) and Node.js.
* **Agent Installation:** Run `npm install -g @openai/codex` instead of Claude Code.
* **Permissions:** Ensure the `appuser` (UID 1000) owns the necessary config directories (e.g., `~/.codex`).
* **Prompt immutability:** `/app/prompts/` and any command directories must be owned by `root:root`, mode `444`/`555` — agent (UID 1000) cannot modify them at runtime.
* **MCP config as build artifact:** Bake `.mcp.json` into the image at build time so it cannot be runtime-modified.

### Docker Compose (`docker-compose.yml`)
* Add `codex-server` service alongside `claude-server`.
* **Build Context:** Point to `Dockerfile.codex`.
* **Network:** Attach strictly to `int_net` (no external network access).
* **Volumes:**
    * Mount `./workspace:/workspace` (same as Claude).
    * Mount `certs/` for TLS.
    * Mount `docs/` as read-only at `/docs` (for docs MCP access).
    * Mount `plans/` at `/plans` (if codex-server needs direct plan access).
    * Mount `logs/` at `/logs` (for log-server shared storage).
* **Container Hardening** (match claude-server):
    * `cap_drop: ALL`
    * `mem_limit: 4g`
    * `cpus: 2.0`
    * `pids_limit: 200`
    * `user: 1000`
* **Environment Variables:**
    * `OPENAI_BASE_URL=http://proxy:4000/v1` (Forces traffic through LiteLLM).
    * `OPENAI_API_KEY=${DYNAMIC_AGENT_KEY}` (Zero-trust ephemeral token).
    * `CODEX_API_TOKEN=${CODEX_API_TOKEN}` (Ingress protection).
    * `MCP_API_TOKEN=${MCP_API_TOKEN}` (Auth for mcp-server).
    * `GIT_API_TOKEN=${GIT_API_TOKEN}` (Auth for git-server).
    * `PLAN_API_TOKEN=${PLAN_API_TOKEN}` (Auth for plan-server).
    * `TESTER_API_TOKEN=${TESTER_API_TOKEN}` (Auth for tester-server).
    * `LOG_API_TOKEN=${LOG_API_TOKEN}` (Auth for log-server).
    * `LOG_SERVER_URL=https://log-server:8443` (Log ingest + query endpoint).
    * `PLAN_SERVER_URL=https://plan-server:8443` (Plan loop control).

### Caddy Configuration (`cluster/caddy/Caddyfile`)
* **Inbound Rules:** Add a reverse proxy route for the host to access `codex-server`.
    * Map a new port (e.g., `:8444` or base it on path `/codex`) routing to `https://codex-server:8000`.
* **Outbound Rules (Proxy):** Ensure Caddy still strictly prevents external egress for `codex-server`, forcing all outbound LLM traffic to hit the `proxy` service.
* **Request body size limit:** Cap at 256 KB (matching claude-server's Caddy config).

---

## 2. Certificates & Authentication

### Initialization Script (`init_build.sh`)
* **Token Generation:** Add logic to generate a `CODEX_API_TOKEN` alongside the existing `CLAUDE_API_TOKEN`. Write this to `.secrets.env`.
* **Certificates:** Add `codex-server` to the `mkcert` generation loop so it gets trusted internal TLS certificates.

### Proxy Configuration (`cluster/proxy/proxy_config.yaml`)
* **LiteLLM Routing:** Add model endpoints for Codex (e.g., `openai/gpt-5.3-codex` or `openai/gpt-4o`).
* **Key Mapping:** Bind these models to `os.environ/OPENAI_API_KEY` (the real key stored in `.secrets.env`).

---

## 3. Service Implementation (`codex-server`)

### Server Wrapper (`cluster/codex-server/server.py`)
* Implement a FastAPI wrapper identical in contract to `claude-server/server.py`.
* **SSL:** Serve on `0.0.0.0:8000` with internal CA certificates (`agent.key`/`agent.crt`).
* **Endpoints Required:**
    * `GET /health` — Liveliness probe (unauthenticated).
    * `POST /ask` (Executes standard Codex prompt — matches claude-server's endpoint name).
    * `POST /plan` (Executes Codex with strict instructions to interact with `plan-server`).
* **Subprocess Execution:** Invoke the Codex CLI using `subprocess.Popen`, capturing stdout/stderr and streaming it back to the client.
* **Auth Guard:** Validate `Authorization: Bearer` header against `CODEX_API_TOKEN` using `secrets.compare_digest` (timing-attack resistant).
* **Request Validation:**
    * **Model allowlist:** Validate `request.model` against a `ALLOWED_MODELS` frozenset (e.g., `{"gpt-4o", "gpt-5.3-codex", "o3"}`). Reject unknown models with HTTP 400.
    * **Max query length:** Pydantic `max_length=100_000` on query field.
    * **Max model length:** Pydantic `max_length=200` on model field.
* **Subprocess timeout:** 600 seconds per invocation, returning timeout error on expiry.

### Slash Command System
* Load markdown command files from a `COMMANDS_DIR` (e.g., `/home/appuser/.codex/commands`).
* Expand slash-prefixed queries (e.g., `/architecture-doc`) by loading the corresponding `.md` file.
* **Path traversal protection:** Apply `os.path.basename()` + `PATH_BLACKLIST` (null byte, `..`, `~`, `;`, `|`, `&`, backtick, `$`, etc.) to prevent directory traversal.

### Error Handling
* **Upstream error detection:** Parse subprocess stderr for:
    * Auth failures ("authentication_error", "OAuth token has expired") → HTTP 502.
    * Rate limits ("rate_limit_error", "429", "Too Many Requests") → HTTP 429.
* **Secret redaction:** Regex-mask all known token values in stderr/logs with `[REDACTED]` before output.

### Plan-Based Task Looping
* **Plan detection:** Call `PLAN_SERVER_URL/current` to check for active tasks before execution.
* **Loop parameters:** `MAX_TASK_ITERATIONS = 50`.
* **Loop flow:**
    1. Check plan-server for active task.
    2. If no active task → single ad-hoc invocation with adhoc system prompt.
    3. If active task → loop up to 50 times with plan-based system prompt.
    4. Per iteration: spawn subagent, log token usage, check for `DONE` marker in stdout.
    5. Stop on `DONE` marker or when plan-server reports no remaining tasks.
    6. Combine all responses with `"\n\n---\n\n"` separator.
* **Three system prompts:** `ask.md` (plan-driven loop), `ask-adhoc.md` (single ad-hoc), `plan.md` (planning only).

### Session Management
* Generate per-invocation session IDs using `secrets.token_hex(8)` (16-char hex string).
* Pass session_id to all log events for correlation.
* Support multi-turn token tracking with per-turn `turn_number` field.

### MCP Integration
* Codex needs an MCP configuration file (similar to Claude's tool config).
* Generate a `.mcp.json` (or Codex equivalent) during container build that points Codex to:
    * `https://mcp-server:8443` (Filesystem) — via `files_mcp.py` stdio wrapper.
    * `https://git-server:8443` (Git) — via `git_mcp.py` stdio wrapper.
    * `https://tester-server:8443` (Tests) — via `tester_mcp.py` stdio wrapper.
    * `https://plan-server:8443` (Planner) — via `plan_mcp.py` stdio wrapper.
    * `https://log-server:8443` (Logs) — via `log_mcp.py` stdio wrapper.
    * `/docs` (Docs) — via `docs_mcp.py` stdio wrapper (local read-only mount).
* All MCP wrappers must be intercepted by `mcp-watchdog` (blocks 40+ attack classes on JSON-RPC traffic).
* Ensure all tool definitions inject the respective subsystem tokens (`MCP_API_TOKEN`, etc.) via `Authorization: Bearer` headers.
* `.mcp.json` baked into image at build time — not runtime-configurable.

---

## 4. Log-Server Integration

### Event Emission (`log_emit.py`)
* Port the shared `log_emit.py` module (or equivalent) into `codex-server`.
* **Emit function:** `_emit_log_event(event_data)` posts to `LOG_SERVER_URL/ingest` with `Bearer LOG_API_TOKEN`.
* **Fire-and-forget:** Run each POST in a daemon thread so logging never blocks execution.
* **Timeout:** 5-second timeout per POST; failures are non-fatal (log warning, continue).
* **TLS verification:** Verify internal CA at `/app/certs/ca.crt` on all HTTPS requests.

### Event Types to Emit

| Event Type | Source | Fields |
|:---|:---|:---|
| `llm_call` | `server.py` (after each subagent turn) | `timestamp` (ISO 8601 UTC), `session_id`, `model`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `turn_number` (1-indexed), `duration_ms` (on last turn) |
| `file_read` | `files_mcp.py` (on successful read) | `timestamp`, `session_id`, `event_type`, `path`, `size_bytes` |
| `git_op` | `git_mcp.py` (on every operation) | `timestamp`, `session_id`, `event_type`, `operation` (`git_status`, `git_diff`, `git_add`, `git_commit`, `git_log`, `git_reset_soft`), `duration_ms`, `submodule_path` (if applicable) |
| `test_run` | `tester_mcp.py` (on completion) | `timestamp`, `session_id`, `event_type`, `exit_code`, `output_size_bytes`, `duration_ms` |
| `tool_call` | MCP wrappers (general) | `timestamp`, `session_id`, `event_type`, `tool_name` |

### LLM Token Extraction
* Parse Codex CLI output (adapt to its output format — may differ from Claude's `stream-json`).
* Extract per-turn token usage: `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`.
* Emit one `llm_call` event per turn; attach `duration_ms` only to the last turn in multi-turn sessions.

### Log MCP Wrapper (`log_mcp.py`)
* Expose log-server as 5 MCP tools so the agent can query its own session history:

| Tool | Description | HTTP Endpoint |
|:---|:---|:---|
| `list_sessions(limit?, since?)` | List recent sessions with timestamps and summary stats | `GET /sessions` |
| `get_session_summary(session_id)` | LLM calls, tokens, tool calls, task count, duration | `GET /sessions/{id}/summary` |
| `query_logs(session_id, event_type?, time_range?)` | Query structured log entries filtered by type/time | `POST /sessions/{id}/query` |
| `get_token_breakdown(session_id)` | Per-call token counts (input, output, cache read/write, model) | `GET /sessions/{id}/tokens` |
| `get_file_dedup_report(session_id)` | Duplicate file reads grouped by SHA256 with wasted token estimates | `GET /sessions/{id}/file-dedup` |

### Log Ingestion Endpoint Contract

```
POST /ingest
  Headers: Authorization: Bearer {LOG_API_TOKEN}
  Body: {
    "timestamp": "2026-04-06T12:00:00Z",
    "session_id": "a1b2c3d4e5f6g7h8",
    "event_type": "llm_call",
    ...event-specific fields...
  }
  Response: 200 OK
```

### Log Sanitization
* `_redact_secrets()` replaces all known token values (`CODEX_API_TOKEN`, `DYNAMIC_AGENT_KEY`, `MCP_API_TOKEN`, `PLAN_API_TOKEN`, `TESTER_API_TOKEN`, `GIT_API_TOKEN`, `LOG_API_TOKEN`) with `[REDACTED]`.
* Subprocess stdout/stderr logged at DEBUG level only.
* Structured file-access logging: only metadata (`FILE_READ: <path> (<n> bytes, sha256=<hex>)`), never file content.

---

## 5. Startup Isolation Checks (`verify_isolation.py`)

### Required Environment Variables
codex-server must validate at startup:

| Variable | Requirement |
|:---|:---|
| `OPENAI_API_KEY` / `DYNAMIC_AGENT_KEY` | ✓ Required (ephemeral proxy token) |
| `CODEX_API_TOKEN` | ✓ Required (ingress auth) |
| `MCP_API_TOKEN` | ✓ Required |
| `GIT_API_TOKEN` | ✓ Required |
| `PLAN_API_TOKEN` | ✓ Required |
| `TESTER_API_TOKEN` | ✓ Required |
| `LOG_API_TOKEN` | ✓ Required |
| `LOG_SERVER_URL` | ✓ Required |
| `PLAN_SERVER_URL` | ✓ Required |

### Forbidden Environment Variables
| Variable | Requirement |
|:---|:---|
| `ANTHROPIC_API_KEY` | ✗ Forbidden (real key, proxy-only) |
| `CLAUDE_API_TOKEN` | ✗ Forbidden (claude-server's ingress token) |

### Forbidden Paths
* `/app/.secrets.env`, `/app/.cluster_tokens.env`, `/app/docker-compose.yml`, `/app/proxy_config.yaml`, `/app/Caddyfile`
* `/workspace/certs`

### Required Paths
* `/app/server.py`, `/app/files_mcp.py`, `/app/verify_isolation.py`
* `/app/prompts` (system prompts directory)
* `/app/certs/ca.crt` (internal CA for TLS verification)
* `.mcp.json` (MCP config)

### Additional Checks
* Scan `/app` and `/home/appuser` for `.env` files (must not exist).
* Validate `.mcp.json` structure (must have expected MCP server entries).
* Verify prompt directories are root-owned and read-only (blocks runtime modification).
* All token comparisons use `secrets.compare_digest` (timing-attack resistant).

---

## 6. Client Shell Scripts

### Parameter Modification: `query.sh` and `plan.sh`
* **Current Signature:** `./query.sh <model> "<query>"`
* **New Signature:** `./query.sh -a <agent> -m <model> "<query>"` (e.g., `./query.sh -a codex -m gpt-4o "do work"`).
* **Fallback/Default:** If `-a` is not provided, default to `claude` to prevent breaking existing developer workflows.
* **Routing Logic:**
    * If `agent == claude`, curl `https://localhost:8443` with `CLAUDE_API_TOKEN`.
    * If `agent == codex`, curl the new route (e.g., `https://localhost:8444`) with `CODEX_API_TOKEN`.

### Log Tailer (`logs.sh`)
* Add `codex-server` to the `docker compose logs -f` command.
* Color-code `codex-server` output differently from `claude-server` for readability.

---

## 7. Security & Integration Testing

### Test Script (`test-integration.sh`)
* Add endpoint liveliness checks for `codex-server`.
* Run a dummy execution test specifically invoking `./query.sh -a codex -m gpt-4o "echo hello"` to verify end-to-end execution and MCP tool binding.
* Verify log-server receives events from codex-server (query `/sessions` after test run).

### Security Assertions (`check_isolation.py`)
* Add a dedicated role and test suite for `codex-server`.
* **Test 1 (Network Egress):** Assert `docker exec codex-server ping 8.8.8.8` fails.
* **Test 2 (Proxy Access):** Assert `docker exec codex-server curl http://proxy:4000/v1/models` succeeds.
* **Test 3 (Filesystem Jail):** Assert `codex-server` cannot access host mounts outside of `/workspace` via tool calls.
* **Test 4 (Key Exposure):** Assert `codex-server` environment variables *do not* contain the real `OPENAI_API_KEY`, only the ephemeral proxy token.
* **Test 5 (Cross-Agent Token Isolation):** Assert `codex-server` does not have `CLAUDE_API_TOKEN` and `claude-server` does not have `CODEX_API_TOKEN`.
* **Test 6 (Log-Server Connectivity):** Assert `codex-server` can POST to `log-server:8443/ingest` with valid `LOG_API_TOKEN`.
* **Test 7 (Log Event Correctness):** After a test invocation, query `log-server` sessions and verify events with correct `session_id` and `event_type` fields exist.

### Token Isolation Matrix Update

| Token | claude-server | codex-server | proxy | mcp-server | plan-server | tester-server | git-server | log-server | caddy |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| ANTHROPIC_API_KEY | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| OPENAI_API_KEY (real) | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| DYNAMIC_AGENT_KEY | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| CLAUDE_API_TOKEN | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | — |
| CODEX_API_TOKEN | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | — |
| MCP_API_TOKEN | ✓ | ✓ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| PLAN_API_TOKEN | ✓ | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ |
| TESTER_API_TOKEN | ✓ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ |
| GIT_API_TOKEN | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |
| LOG_API_TOKEN | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ |

---

## 8. Documentation Updates

### Secrets Environment (`.secrets.env.example`)
* Add `OPENAI_API_KEY=sk-proj-...`
* Add `CODEX_API_TOKEN=gen_...` (auto-generated placeholder).

### Login Instructions / Readme
* Update `README.md` to explain the dual-agent architecture.
* Document how to choose between agents using the `-a` flag.
* *(Optional)* Document the Alternative Authentication flow: If a user wants to use a ChatGPT Plus subscription instead of an API key, explain how to run `codex login` on the host machine and bind-mount `~/.codex/auth.json` to the container (noting the trade-off regarding LiteLLM MITM compatibility).

### Claude's Context (`CLAUDE.md`)
* Update the system architecture diagram/description so Claude understands it has a sibling container (`codex-server`).
* Outline the script signature changes so Claude writes correct commands when creating shell execution plans.

### Architecture Docs
* Update `ARCHITECTURE_OVERVIEW.md` to add codex-server to the system components table (9 containers).
* Update `ARCHITECTURE_DETAIL.md`:
    * Add codex-server to the network topology diagram.
    * Add codex-server to the service-to-service routing diagram.
    * Update the token isolation matrix.
    * Add codex-server to the container hardening table.
    * Add codex-server to the startup isolation checks table.
