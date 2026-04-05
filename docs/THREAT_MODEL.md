# Threat Model: secure-claude

**Date:** 2026-04-05 (updated 2026-04-05 — code reconnaissance: 5 new findings RR-22 through RR-26)
**Scope:** secure-claude cluster — hardened containerised environment for running Claude Code as an autonomous AI agent
**Methodology:** STRIDE (Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege)
**Classification:** Internal Engineering Review

---

## 1. Assets Inventory

| Asset | Confidentiality | Integrity | Availability | Location |
|-------|----------------|-----------|--------------|----------|
| `ANTHROPIC_API_KEY` | Critical — billing/abuse if leaked | High — must not be altered | Medium | `proxy` container only (int_net, no direct internet), host `.secrets.env` |
| `DYNAMIC_AGENT_KEY` | High — grants API access via proxy | High | High | `claude-server`, `proxy` |
| `CLAUDE_API_TOKEN` | High — gates external agent invocation | High | High | `claude-server` only |
| `MCP_API_TOKEN` | High — mcp-server auth | High | High | `claude-server`, `mcp-server` |
| `PLAN_API_TOKEN` | High — plan-server auth | High | High | `claude-server`, `plan-server` |
| `TESTER_API_TOKEN` | High — tester-server auth | High | High | `claude-server`, `tester-server` |
| `GIT_API_TOKEN` | High — git-server auth | High | High | `claude-server`, `git-server` |
| `LOG_API_TOKEN` | Medium — log-server auth; grants read access to full session audit trail | High | Medium | `claude-server`, `log-server` |
| TLS CA key (`ca.key`) | Critical — can sign arbitrary certs | Critical | Low (used only at build) | Host `cluster/certs/ca.key` (640 perms) |
| TLS leaf certs/keys | High — MITM if stolen | High | Medium | Per-container `/app/certs/` |
| `/workspace` source code | Medium — may contain business logic | Critical — agent commits changes | High | Host bind mount → `mcp-server` (rw), others (ro) |
| Git history (`.git`) | Medium | Critical — commits are permanent | High | Host `workspace/.git` → `/gitdir` in `git-server` |
| Plan state (`/plans`) | Low | High — directs agent work | High | Host `plans/` → `plan-server` |
| Session logs (`/logs`) | Medium — metadata: tool calls, file paths, token counts, timing | High — audit trail integrity | Medium | Host `logs/` → `log-server` (rw) |
| Test output | Low | High — misleading output could cause bad commits | Medium | In-memory, `tester-server` |
| System prompts (`/app/prompts/`) | High — defines agent behaviour | Critical — modification changes agent goals | Medium | Baked into `claude-server` image, root-owned |
| Slash commands (`~/.claude/commands/`) | Medium | High | Medium | Baked into `claude-server` image, root-owned |
| Container environment variables | High | High | — | Runtime process memory |
| Docker socket | Critical — full host escape if accessible | Critical | — | Should NOT be accessible |

---

## 2. Trust Boundaries

```
[External Network]
       │  HTTPS/TLS 1.3, Bearer CLAUDE_API_TOKEN
       ▼
[caddy-sidecar :8443]  ← only container on ext_net + int_net
  │    │  HTTPS, internal CA, no auth header added
  │    ▼
  │  [claude-server :8000]  ← int_net only
  │    │  subprocess ANTHROPIC_API_KEY=DYNAMIC_AGENT_KEY
  │    ├──────────────────────────────────────────────────────►[proxy :4000]
  │    │                                                        (int_net only)
  │    │  stdio JSON-RPC  ┌──────────────────────────┐          │
  │    ├──────────────────► mcp-watchdog (in-process) │          │
  │    │                  └──────────┬───────────────┘          │
  │    │                             │ blocks 40+ attack classes│
  │    │                  ┌──────────▼───────────────┐          │
  │    │  HTTPS REST over │ files_mcp.py → mcp-server:8443      │
  │    │  internal CA     │ plan_mcp.py → plan-server:8443      │
  │    │                  │ tester_mcp.py → tester-server:8443  │
  │    │                  │ git_mcp.py → git-server:8443        │
  │    │                  │ docs_mcp.py → /docs read-only       │
  │    │                  │ log_mcp.py → log-server:8443        │
  │    │                  └──────────────────────────┘          │
  │    │                                                        │
  │  [caddy-sidecar :8081]  ◄──────────────────────────────────┘
  │    │  Egress proxy — hardcoded upstream: api.anthropic.com:443 only
  │    ▼
  [Anthropic API]

[mcp-server :8443]     os.OpenRoot jail at /workspace
[plan-server :8443]    /plans only, no workspace/git/secrets
[tester-server :8443]  /workspace:ro, no git/plans/secrets
[git-server :8443]     /gitdir:rw, /workspace:ro
[log-server :8443]     /logs:rw, no workspace/git/plans/secrets

[Host ↔ Container]
  - Docker volume mounts (workspace rw, git rw, plans rw, logs rw, certs rw)
  - No Docker socket inside any container
  - No privileged containers
```

### Key Boundary Properties

| Boundary | Enforcement Mechanism |
|----------|----------------------|
| Internet → Caddy | TLS 1.3 + bearer token (CLAUDE_API_TOKEN), constant-time compare |
| Caddy → claude-server | Internal CA; Caddy verifies `ca.crt` |
| claude-server → mcp-server | Bearer MCP_API_TOKEN, TLS + internal CA |
| claude-server → git-server | Bearer GIT_API_TOKEN, TLS + internal CA |
| claude-server → plan-server | Bearer PLAN_API_TOKEN, TLS + internal CA |
| claude-server → tester-server | Bearer TESTER_API_TOKEN, TLS + internal CA |
| claude-server → log-server | Bearer LOG_API_TOKEN, TLS + internal CA |
| MCP stdio → Go/REST backends | mcp-watchdog intercepts all JSON-RPC before forwarding |
| Agent subprocess → filesystem | `/workspace` mounted ro in claude-server; writes only via mcp-server's os.OpenRoot jail |
| claude-server → Anthropic | DYNAMIC_AGENT_KEY only (not real key); route via proxy (int_net only) → caddy-sidecar:8081 → api.anthropic.com |
| proxy → Internet | **No direct access.** Proxy is int_net only; egress exclusively via caddy-sidecar:8081, hardcoded to api.anthropic.com:443 |
| Host → container | UID 1000, no Docker socket, `cap_drop: ALL` on all containers |
| plan-server ↔ workspace | Structurally separated — plan-server has no `/workspace` mount |
| log-server ↔ workspace/git/plans | Structurally separated — log-server has no `/workspace`, `/gitdir`, or `/plans` mount |

---

## 3. Threat Actors

### TA-1: Malicious External Caller
Network access to Caddy `:8443`. Does not hold `CLAUDE_API_TOKEN`. Goal: invoke agent without auth, extract secrets, DoS.

### TA-2: Compromised LLM Output
Claude Code itself produces adversarial tool calls — either due to a jailbreak, a model regression, or an upstream supply-chain issue at Anthropic. Has full access to all MCP tool surfaces.

### TA-3: Prompt Injection via Workspace Content
Malicious content in files the agent reads (`/workspace`, `/docs`, git history, plan files, test output). Attempts to override system prompt behaviour by embedding instructions in data.

### TA-4: Compromised Dependency
A malicious version of a pip/npm/Go package (e.g., `mcp`, `litellm`, `claude-code`, `mcp-watchdog`) is installed and executes arbitrary code in-container. Has the permissions of the container's appuser.

### TA-5: Insider with Host Access
Can read `.secrets.env`, Docker volumes, container logs, `.env`, `.cluster_tokens.env`. May also modify `docker-compose.yml` or Dockerfiles before a rebuild.

---

## 4. Attack Vectors

### 4.1 Infrastructure Attacks

#### Container Escape
- **Attack:** Exploit kernel vulnerability, Docker breakout via mounted socket, or privileged container.
- **Prerequisites:** No Docker socket is mounted. No `--privileged`. UID 1000. All containers have `cap_drop: ALL`.
- **Impact:** Host compromise; access to `.secrets.env` and real API key.
- **Residual risk:** Low — `cap_drop: ALL` covers all eight containers.

#### Network Segmentation Bypass
- **Attack:** Compromise `caddy-sidecar` (which sits on both `ext_net` and `int_net`) to pivot to internal services.
- **Prerequisites:** RCE in Caddy or its config. Config is mounted read-only. Caddy runs as non-root with `cap_drop: ALL`, `read_only: true`, `pids_limit: 100`.
- **Impact:** Direct access to `mcp-server`, `plan-server`, `tester-server`, `log-server` at HTTPS layer. Still requires per-service token for auth.

#### Volume Mount Traversal
- **Attack:** Abuse the git gitdir mount (`./workspace/.git:/gitdir`) — if `workspace` is a symlink pointing to a sensitive directory, `/gitdir` could expose unexpected content.
- **Prerequisites:** Attacker can influence what `workspace` symlinks to (host access).
- **Impact:** Agent git operations touching unexpected content.

#### Environment Variable Leakage
- **Attack:** `server.py` does `env={**os.environ, ...}` when spawning Claude Code, passing all parent env vars — including `MCP_API_TOKEN`, `PLAN_API_TOKEN`, `TESTER_API_TOKEN`, `GIT_API_TOKEN`, `LOG_API_TOKEN`, `CLAUDE_API_TOKEN` — into the Claude Code subprocess. Any code Claude Code spawns inherits these.
- **Impact:** An adversarial MCP server injected by prompt injection could read these env vars. Claude Code may also echo them in conversation output.
- **Note:** This is by design (MCP stdio wrappers need the tokens), but the blast radius is that all service tokens are in the subprocess environment simultaneously.

#### TLS Downgrade / MITM on Internal Network
- **Egress path (RESOLVED 2026-03-27):** Replaced with a dedicated `:8081` listener using proper public TLS to `api.anthropic.com:443`. Proxy is now `int_net` only.
- **Impact (internal):** Internal services verify `ca.crt` — mitigated by TLS 1.3 minimum on all Go servers (resolved 2026-03-29).

---

### 4.2 LLM-Specific Attacks

#### Prompt Injection via Workspace Files
- **Attack:** A file in `/workspace` contains injected instructions (`IGNORE PREVIOUS INSTRUCTIONS...`). The agent reads the file via `read_workspace_file` or `grep_files` and acts on the injected content.
- **Prerequisites:** Attacker can write content to workspace via prior git commit, third-party library, or crafted test fixture.
- **Impact:** Agent performs unintended actions — exfiltrates tokens by writing them to workspace files, deletes code, or marks tasks complete without completing them.
- **Note:** `mcp-watchdog` blocks on tool *calls*, not *return values*. Injected content in file reads is not sanitised.

#### Tool Poisoning via MCP Response Manipulation
- **Attack:** An adversary intercepts or modifies HTTPS traffic between MCP wrappers and backend servers, crafting responses that cause unintended agent actions.
- **Prerequisites:** Network position or compromised mcp-watchdog/requests library.
- **Impact:** High if tool responses are manipulated — agent fully trusts MCP tool results.

#### Plan Manipulation
- **Attack:** Agent is instructed (via prompt injection) to call `plan_create` with adversarial task definitions, directing future sessions to exfiltrate secrets, install backdoors, or permanently alter source code.
- **Prerequisites:** Agent must be tricked into `plan_create`. Plan field lengths are now validated (RR-14, resolved), but content semantics are not checked.
- **Impact:** Plans persist in `/plans` across sessions. A malicious plan directs future agent runs long after the initial injection.

#### Indirect Prompt Injection via Docs
- **Attack:** `docs_mcp.py` reads files in `/docs`. If an attacker writes malicious content to `docs/CONTEXT.md` via `mcp-server`, injected instructions are read as documentation context.
- **Prerequisites:** Agent tricked into writing malicious content to `docs/`. The `docs/` path is read-only in `claude-server` but read-write in `mcp-server`.
- **Impact:** Persistent system-level injection surviving across sessions.

#### Git History Poisoning
- **Attack:** Prior commits contain prompt-injection payloads. When the agent runs `git_log` or reads changed files, it ingests adversarial instructions.
- **Prerequisites:** Attacker has write access to git history (compromised contributor or prior agent session).
- **Impact:** Durable, hard-to-detect injection surviving file deletions.

#### Test Oracle Manipulation
- **Attack:** A workspace file (e.g., a test fixture) produces output that misleads the agent — e.g., a test that always prints `All tests passed` regardless of actual outcome.
- **Prerequisites:** Attacker can write to workspace test files.
- **Impact:** Agent marks tasks complete without genuine verification, potentially committing broken or backdoored code.

#### Token Exfiltration via Tool Calls
- **Attack:** Agent is instructed (via prompt injection) to call `grep_files` targeting secret markers in code and write results to a file or embed them in a commit message.
- **Specific risk:** All service tokens (`MCP_API_TOKEN`, `PLAN_API_TOKEN`, `TESTER_API_TOKEN`, `GIT_API_TOKEN`, `LOG_API_TOKEN`, `DYNAMIC_AGENT_KEY`, `CLAUDE_API_TOKEN`) are in `os.environ` of the Claude Code subprocess via `env={**os.environ, ...}` in `server.py`.
- **Exfiltration channel:** Agent writes content to `/workspace` via `write_file`; committed to git history and accessible from host mount. Network exfiltration is blocked — egress locked to `api.anthropic.com`. Covert-channel encoding in API request bodies remains a theoretical risk.

#### Log Exfiltration via log_mcp Tools
- **Attack:** Agent is instructed (via prompt injection) to call `list_sessions` and `query_logs`, harvesting session metadata (tool calls, file paths accessed, timing data) and embedding it in workspace files or commit messages.
- **Prerequisites:** Agent already has legitimate access to log_mcp tools. Prompt injection redirects use.
- **Impact:** Session audit trail exposed; patterns of prior operation (which files were accessed, what tasks were run, token consumption) revealed through git history.
- **Note:** Log content does not include file bodies (structural constraint), but file paths and tool call names are present and may be sensitive.

#### Recursive Self-Modification
- **Agent's `/app/` in claude-server** cannot be reached by `mcp-server` (different containers). However, the agent can modify `docs/CONTEXT.md`, `docs/PLAN.md`, and workspace source files — shaping its own future context and instructions.

---

### 4.3 Authentication and Authorization Attacks

#### Token Replay / Theft
- **Attack:** Intercept `CLAUDE_API_TOKEN` from a `query.sh` invocation (process list, network sniff, shell history) and replay requests.
- **Mitigation present:** Tokens are 64-character random hex, regenerated on every `run.sh`.
- **Gap:** No per-session or per-request nonce; stolen token valid until `run.sh` is re-run. No rate limiting (RR-8).

#### Privilege Escalation Between Token Scopes
- **Status (RR-4, resolved 2026-03-28):** Each backend now has its own token. Compromise of one token no longer grants access to other services.
- **Residual:** `claude-server` holds all service tokens simultaneously. A token exfiltration from claude-server still exposes all tokens, but blast radius per token is bounded to a single backend.

#### Bypass of Token Validation
- All token comparisons use `secrets.compare_digest` (Python) or `subtle.ConstantTimeCompare` (Go). All services call `log.Fatal` on empty token at startup. No bypass risk identified.

#### ~~LOG_API_TOKEN Missing from proxy and caddy Isolation Checks~~ (RESOLVED — RR-19)
- **Attack:** `LOG_API_TOKEN` was absent from `FORBIDDEN_ENV_VARS["proxy"]` and `FORBIDDEN_ENV_VARS["caddy"]` in `verify_isolation.py`. If `LOG_API_TOKEN` were to leak into the `proxy` or `caddy` container environments (e.g., via a misconfigured `docker-compose.yml`), startup isolation checks would not detect it.
- **Impact:** Confidentiality of LOG_API_TOKEN slightly weakened — a compromised proxy or caddy could read it from env and query session logs from log-server. Log-server is on `int_net` and requires the token, limiting the direct blast radius.
- **Severity:** Low (requires misconfiguration AND container compromise).
- **Resolution (2026-04-04):** `LOG_API_TOKEN` added to `FORBIDDEN_ENV_VARS["proxy"]` and `FORBIDDEN_ENV_VARS["caddy"]` in `verify_isolation.py`. Regression tests `test_log_api_token_in_proxy_forbidden_list` and `test_log_api_token_in_caddy_forbidden_list` added to `test_isolation.py`.

#### Unauthenticated /health Endpoint (RR-22)
- **Attack:** The `/health` endpoint in `server.py` has no authentication requirement (`@app.get("/health")` with no `verify_token` dependency). An unauthenticated external caller (TA-1) can probe server availability, confirm the service is running, and fingerprint response timing.
- **Prerequisites:** Network access to Caddy `:8443`. No token required.
- **Impact:** Low — information disclosure (service liveness). However, combined with RR-8 (no rate limiting), enables availability probing for timing-based attacks.
- **Note:** Health endpoints are conventionally unauthenticated for load balancer integration. Risk is accepted if Caddy does not expose `/health` externally; elevated if it does.

#### docs_mcp.py Path Traversal via Prefix Matching (RR-23)
- **Attack:** `_safe_path()` in `docs_mcp.py` uses `resolved.startswith(os.path.realpath(DOCS_DIR))` without appending `os.sep` to the base directory. If a sibling directory exists whose name shares the `/docs` prefix (e.g., `/docs_backup`), the `startswith` check passes: `"/docs_backup/secret.md".startswith("/docs")` → `True`.
- **Prerequisites:** A directory on the filesystem shares a prefix with `DOCS_DIR` (e.g., `/docs_internal`, `/docs_backup`). In the current Docker setup, `/docs` is a specific bind mount and no sibling exists — but this is a latent vulnerability if mount layout changes.
- **Impact:** Medium — agent could read files outside the intended docs directory. Mitigated by Docker mount isolation (no sibling directories exist in current layout).
- **Recommendation:** Append `os.sep` to the base path: `resolved.startswith(os.path.realpath(DOCS_DIR) + os.sep)` or check `resolved == os.path.realpath(DOCS_DIR)`.

#### Unredacted stderr in HTTP Error Responses (RR-24)
- **Attack:** `server.py` returns raw `result.stderr` in HTTP error responses (e.g., `return {"error": result.stderr}`) without passing through `_redact_secrets()`. If the Claude Code subprocess emits tokens, internal paths, or stack traces to stderr, these are returned verbatim to the authenticated caller.
- **Prerequisites:** Authenticated caller (holds `CLAUDE_API_TOKEN`). Claude Code subprocess must produce stderr containing sensitive content.
- **Impact:** Medium — information disclosure of internal paths, dependency versions, and potentially token fragments in error messages. The caller is already authenticated, which limits the blast radius, but stderr may contain more than the caller should see.
- **Recommendation:** Apply `_redact_secrets()` to all `result.stderr` values before including in HTTP responses. Truncate stderr to a reasonable length (e.g., 4 KB).

#### Race Condition in tester_mcp.py Global State (RR-25)
- **Attack:** `tester_mcp.py` uses unprotected global variables (`_consecutive_failures`, `_failure_counted_for_current_run`) to implement a 3-strike hard stop. In an async MCP server context, concurrent tool calls can race on these globals: one coroutine reads the counter while another increments it, leading to either a bypassed hard stop (counter not incremented) or a false hard stop (counter double-incremented).
- **Prerequisites:** Multiple concurrent `run_tests` / `get_test_results` MCP calls. In practice, Claude Code issues tool calls sequentially, making exploitation unlikely under normal operation.
- **Impact:** Low — incorrect 3-strike enforcement. Bypass allows unlimited test retries (wasting compute); false trigger causes premature task failure. Neither leads to data compromise.
- **Recommendation:** Protect global state with `asyncio.Lock` or use `threading.Lock` if called from sync context.

#### Generic Exception Info Disclosure in HTTP Responses (RR-26)
- **Attack:** `server.py` catches broad `Exception` in `/ask` and `/plan` handlers and returns `str(e)` in the HTTP response body. Depending on the exception type, this may leak internal file paths, library versions, database connection strings, or other implementation details.
- **Prerequisites:** Authenticated caller. An unexpected exception must occur during request processing.
- **Impact:** Low — information disclosure to an already-authenticated caller. Exception messages are typically opaque but may occasionally contain internal details useful for further attacks.
- **Recommendation:** Return a generic error message in production responses; log the full exception server-side. Example: `return {"error": "Internal agent execution error"}`.

---

### 4.4 New / Previously Untracked Vectors

#### RR-20: Session Log Data Retention — No Rotation or TTL Policy
- **Attack / Scenario:** JSONL log files in `/logs` accumulate indefinitely with no documented rotation, archival, or deletion policy. Over time, `log-server` stores the full metadata history of every agent session: tool calls made, file paths accessed, LLM token counts and timing, session IDs.
- **Impact:**
  - **Confidentiality:** A host-level compromise (TA-5) exposes all historical session metadata. While file content is never logged, the access patterns (which files were read repeatedly, which tasks ran, what models were used) can leak architectural and operational intelligence.
  - **Availability:** Unbounded log growth can fill the host disk partition, degrading all services sharing the same storage.
- **Severity:** Medium
- **Recommendation:**
  1. Document a log retention policy (e.g., 30-day TTL).
  2. Add a log rotation mechanism to `log-server` (e.g., a configurable `LOG_RETENTION_DAYS` env var that deletes or archives JSONL files on startup or via a daily cron within the container).
  3. Set a host-level disk quota on the `./logs` mount or use a separate volume with a size cap.

#### RR-21: Silent Log Drops — Incomplete Audit Trail
- **Attack / Scenario:** `_emit_log_event()` in `server.py` runs in a daemon thread with fire-and-forget semantics. If `log-server` is unavailable (crashed, restarting, overloaded), the `requests.post` raises an exception that is caught and logged only at `WARNING` level — the LLM call event is silently discarded. A malicious actor who can make `log-server` unavailable (e.g., via DoS targeting that one container, RR-8 style) can cause agent sessions to run without being recorded.
- **Impact:** Loss of audit trail integrity; security-relevant events (tool calls, file writes, commits) go unrecorded. This undermines the repudiation defense the logging system is intended to provide.
- **Severity:** Low (fire-and-forget is a deliberate design tradeoff; log-server has its own `pids_limit` and resource caps; log events are supplementary to git history).
- **Recommendation:** Document that git commit history is the primary audit trail and log-server is supplementary. Optionally add a counter of dropped log events exposed at `/health` or in `claude-server` metrics.

---

## 5. Existing Mitigations

### Credential Isolation
- Token matrix enforced at startup: `verify_isolation.py` (claude-server), `proxy_wrapper.py` (proxy), `entrypoint.sh` scripts. Each container checks for forbidden env vars and refuses to start if violated.
- `ANTHROPIC_API_KEY` is never in `claude-server` at entrypoint time. Injected only into Claude Code subprocess scope as `DYNAMIC_AGENT_KEY`.

### Network Isolation
- `int_net` is `internal: true`. Only `caddy-sidecar` spans both networks.
- `proxy` is `int_net` only — no direct internet access since 2026-03-27.
- `log-server` is `int_net` only; no external routing.

### Filesystem Jail (Go os.OpenRoot)
- `mcp-server/main.go` calls `os.OpenRoot("/workspace")` at startup. All file operations use this root object. Go 1.24+ provides kernel-level jail enforcement.
- Tests in `mcp_test.go` explicitly verify path traversal is blocked.

### Git Hook Prevention (3-layer)
1. **tmpfs shadow:** `/workspace/.git` is `tmpfs:ro,size=0` in `mcp-server`.
2. **Separated gitdir:** `GIT_DIR=/gitdir`, `GIT_WORK_TREE=/workspace`.
3. **core.hooksPath=/dev/null:** Every git invocation passes `-c core.hooksPath=/dev/null`. `git_commit` additionally passes `--no-verify`.

### Baseline Commit Floor
- `entrypoint.sh` captures `HEAD` at container startup. `git_reset_soft` enforces this as a floor. Per-submodule baselines also captured.

### mcp-watchdog
- All MCP stdio servers wrapped: `"command": "mcp-watchdog"` intercepting JSON-RPC, blocking 40+ attack classes.

### Startup Isolation Checks
- `verify_isolation.py` performs checks for all 8 container roles (claude-server, mcp-server, plan-server, tester-server, proxy, caddy, git-server, log-server). All containers verify forbidden/required env vars.

### Prompt Immutability
- `/app/prompts/` and `/home/appuser/.claude/commands/` owned by `root:root`, mode `444`/`555`. UID 1000 agent cannot modify them.

### Non-root Containers
- All eight containers run as UID 1000 with `cap_drop: ALL`.

### Read-only Mounts
- `/workspace` mounted ro in `claude-server` and `tester-server`. `/docs` mounted ro in `claude-server`. Caddyfile and proxy config mounted ro.

### Plan and Tester Isolation
- `plan-server` has no `/workspace`, `/gitdir`, or secrets. `tester-server` has `/workspace:ro` only.

### Log Server Structural Isolation
- `log-server` has no access to `/workspace`, `/gitdir`, `/plans`, or other service tokens. `LOG_API_TOKEN` is isolated exclusively to `log-server` and `claude-server`.
- Log writes from `claude-server` are fire-and-forget daemon threads — failures non-fatal (availability tradeoff documented).
- Structural logging constraint: only metadata is stored (session_id, event_type, token counts, duration, file paths/SHA256); no file content ever enters log storage.

### TLS Everywhere (Internal)
- Internal CA generated fresh on each `run.sh`. All service-to-service over HTTPS with CA verification.
- `TLSConfig.MinVersion = tls.VersionTLS13` in all Go servers (resolved 2026-03-29). Caddy ingress also TLS 1.3.

### MCP Config as Build Artifact
- `.mcp.json` baked into `claude-server` image at build time. Agent cannot modify it at runtime.

### Constant-time Token Comparison
- `secrets.compare_digest` (Python) and `subtle.ConstantTimeCompare` (Go) throughout.

### Egress Filtering (2026-03-27)
- Proxy on `int_net` only. All Anthropic API calls route through `caddy-sidecar:8081`, hardcoded to `api.anthropic.com:443` with public TLS. `tls_insecure_skip_verify` removed.

### Container Hardening
- All eight containers: `cap_drop: ALL`, `mem_limit`, `cpus`, `pids_limit`. `caddy-sidecar` and `proxy` additionally have `read_only: true`. `no-new-privileges` deferred (kernel 6.17.0-19 does not support it).

### Log Sanitization
- `server.py`: subprocess stdout/stderr at DEBUG level; `_redact_secrets()` redacts known token values with `[REDACTED]` before any log output. All service tokens (`CLAUDE_API_TOKEN`, `DYNAMIC_AGENT_KEY`, `MCP_API_TOKEN`, `PLAN_API_TOKEN`, `TESTER_API_TOKEN`, `GIT_API_TOKEN`, `LOG_API_TOKEN`) are included.

### Plan Field-length Validation (2026-03-30)
- `plan_server.py` enforces maximum lengths on all text fields. Oversized payloads rejected with HTTP 400.

### Slash Command Hardening (2026-03-29)
- `os.path.basename()` strips directory components; `PATH_BLACKLIST` rejects dangerous characters.

---

## 6. Residual Risks

### ~~RR-1: tls_insecure_skip_verify on Egress Proxy~~ — RESOLVED (2026-03-27)
Replaced with dedicated `:8081` listener → `api.anthropic.com:443` with public TLS. Proxy moved to `int_net` only.

### ~~RR-2: No Timeout on Test Subprocess~~ — RESOLVED (2026-03-27)
`context.WithTimeout` (300s) + `cmd.WaitDelay = 10s`. Timed-out tests return exit code 124.

### ~~RR-3: No Resource Limits on Containers~~ — RESOLVED (2026-03-28)
All containers now have `mem_limit`, `cpus`, `pids_limit`.

### ~~RR-4: Shared MCP_API_TOKEN Across Three Services~~ — RESOLVED (2026-03-28)
Per-service tokens: `MCP_API_TOKEN`, `PLAN_API_TOKEN`, `TESTER_API_TOKEN`, `GIT_API_TOKEN`, `LOG_API_TOKEN`.

### ~~RR-5: File Content Logged in Plaintext~~ — RESOLVED (2026-03-28)
`FILE_READ: <path> (<n> bytes, sha256=<hex>)` only. Regression test added.

### ~~RR-6: URL Path Parameter Not URL-Encoded~~ — RESOLVED (2026-03-28)
All path query parameters in `files_mcp.py` use `params=` kwarg.

### ~~RR-7: Slash Command Path Traversal Not Hardened~~ — RESOLVED (2026-03-29)
`os.path.basename` + `PATH_BLACKLIST` check added. 11 unit tests cover traversal and blacklist cases.

### RR-8: No Rate Limiting on /ask and /plan Endpoints
- **Severity:** Medium
- **Likelihood:** Low (requires stolen CLAUDE_API_TOKEN)
- **Description:** No rate limiting at the Caddy or FastAPI layer. An authenticated caller can submit unlimited concurrent requests, each spawning a 600-second `claude` subprocess.
- **Recommendation:** Add a Caddy rate-limit directive or a FastAPI semaphore. Enforce a maximum of N concurrent agent subprocesses.

### ~~RR-9: Missing cap_drop on Most Containers~~ — RESOLVED (2026-03-28)
All eight containers now have `cap_drop: ALL`.

### RR-10: Cert Validity 365 Days, No Rotation Mechanism
- **Severity:** Low
- **Likelihood:** Medium (over time)
- **Description:** All service certs valid for 365 days, signed at image build time. No automated rotation. Expired certs silently break internal TLS.
- **Recommendation:** Add expiry monitoring. Rotate CA periodically. Consider 90-day cert lifetimes.

### ~~RR-11: Claude Code Subprocess Stdout/Stderr Logged Fully~~ — RESOLVED (2026-03-28)
Subprocess output at DEBUG level; `_redact_secrets()` redacts all known tokens. `LOG_LEVEL` env var configurable.

### ~~RR-12: TLS Minimum Version TLS 1.2 on Internal Go Servers~~ — RESOLVED (2026-03-29)
Both `mcp-server/main.go` and `tester/main.go` now use `tls.VersionTLS13`. Unit tests verify TLS 1.2 is rejected.

### RR-13: Test Output Not Sanitised Before Presenting to Agent
- **Severity:** Medium
- **Likelihood:** Medium
- **Description:** `tester/main.go` returns `string(out)` (all of `cmd.CombinedOutput()`) as the `output` field. If `test.sh` produces output containing embedded prompt-injection content, it is included in the agent's context without sanitisation. The mcp-watchdog intercepts tool *calls*, not *responses*.
- **Recommendation:** Document as an explicit trust boundary. Consider truncating output length (e.g., 64 KB cap).

### ~~RR-14: Plan Field-length Validation Missing~~ — RESOLVED (2026-03-30)
Max-length constants + `_validate_field_lengths()` in `plan_server.py`. 11 unit tests added.

### ~~RR-15: Agent Model Parameter Not Validated~~ — RESOLVED (2026-03-30)
`ALLOWED_MODELS` frozenset defined in `server.py`. `_validate_model()` called at top of both `/ask` and `/plan`; unknown models rejected with HTTP 400. Five unit tests cover reject/accept/empty/prefix-attack cases.

### ~~RR-16: Unbounded Request Body Size on /ask and /plan~~ — RESOLVED (2026-03-30)
`QueryRequest.query` has `max_length=100_000` and `QueryRequest.model` has `max_length=200` via Pydantic `Field`. Caddy `:8443` additionally enforces `request_body { max_size 256KB }`. Five unit tests cover boundary conditions.

### RR-17: Query Content Logged at INFO Level Without Truncation
- **Severity:** Low
- **Likelihood:** Medium (every invocation)
- **Description:** `server.py` logs the full query at `INFO` level unconditionally:
  ```python
  logger.info(f"Received authenticated query: {request.query} for model: {request.model}")
  ```
  Unlike subprocess stdout (moved to DEBUG in RR-11), the *input* query is always logged regardless of `LOG_LEVEL`. This means:
  - Large queries permanently consume log storage.
  - Any sensitive data accidentally included in a query is stored in logs.
  - An insider (TA-5) with log access sees the full content of every invocation.
- **Recommendation:** Truncate the logged query to 500 characters at INFO level; log the full query at DEBUG level:
  ```python
  logger.info(f"Received authenticated query ({len(request.query)} chars): {request.query[:500]!r}...")
  ```

### ~~RR-18: GIT_API_TOKEN Absent from Log Redaction List~~ — RESOLVED (2026-03-30)
`GIT_API_TOKEN` added to `_SECRET_TOKENS` in `server.py`. `LOG_API_TOKEN` also included. Dedicated unit test `test_git_api_token_is_redacted` verifies redaction.

### ~~RR-19: LOG_API_TOKEN Missing from proxy and caddy Isolation Checks~~ — RESOLVED (2026-04-04)
`LOG_API_TOKEN` added to `FORBIDDEN_ENV_VARS["proxy"]` and `FORBIDDEN_ENV_VARS["caddy"]` in `verify_isolation.py`. Regression tests added to `test_isolation.py`.

### RR-20: Session Log Data Retention — No Rotation or TTL Policy
- **Severity:** Medium
- **Likelihood:** Certain (logs grow on every run)
- **Description:** JSONL log files in `/logs` accumulate indefinitely with no documented retention policy, rotation mechanism, or disk quota. Over time this creates: (a) a growing historical store of session metadata exposable by host compromise, and (b) a potential disk-exhaustion vector if invoked at high frequency.
- **Recommendation:**
  1. Document a retention policy (e.g., 30-day TTL).
  2. Add a configurable `LOG_RETENTION_DAYS` env var to `log-server` that prunes old JSONL files at startup.
  3. Consider setting a size cap on the `./logs` Docker volume.

### RR-21: Silent Log Drops — Incomplete Audit Trail
- **Severity:** Low
- **Likelihood:** Low (requires log-server unavailability)
- **Description:** `_emit_log_event()` uses fire-and-forget daemon threads. Log-server unavailability causes silent event loss with only a `WARNING` log in `claude-server`. The audit trail is incomplete for those sessions.
- **Recommendation:** Document that git commit history is the primary, authoritative audit record. Optionally expose a dropped-event counter at `/health` or in a metrics endpoint.

### RR-22: Unauthenticated /health Endpoint
- **Severity:** Low
- **Likelihood:** Medium (always accessible if Caddy routes it)
- **Description:** `server.py` exposes `GET /health` with no bearer token check. If Caddy forwards `/health` to `claude-server`, any network-reachable caller can confirm service liveness without authentication. This aids reconnaissance (TA-1) and can be combined with RR-8 for availability probing.
- **Recommendation:** Either (a) block `/health` at the Caddy layer from external access, or (b) accept the risk — health endpoints are conventionally unauthenticated for load balancer probes. Document the decision.

### RR-23: docs_mcp.py Path Traversal via startswith() Prefix Matching
- **Severity:** Medium
- **Likelihood:** Low (requires sibling directory with shared prefix; none exist in current Docker layout)
- **Description:** `_safe_path()` in `docs_mcp.py` validates paths using `resolved.startswith(os.path.realpath(DOCS_DIR))` without appending `os.sep`. A sibling directory whose name shares the prefix (e.g., `/docs_backup`) would pass the check. In the current Docker layout, `/docs` is an isolated bind mount with no siblings — but this is a latent flaw activated by any mount layout change.
- **Recommendation:** Change to `resolved.startswith(os.path.realpath(DOCS_DIR) + os.sep)` or add `resolved == os.path.realpath(DOCS_DIR)` as an additional condition. Add a unit test for the boundary case.

### RR-24: Unredacted stderr in HTTP Error Responses
- **Severity:** Medium
- **Likelihood:** Medium (occurs on every subprocess failure)
- **Description:** `server.py` returns raw `result.stderr` in HTTP error responses without applying `_redact_secrets()`. While logs are properly redacted, HTTP responses may expose internal paths, stack traces, dependency versions, or token fragments to the authenticated caller. The `_redact_secrets()` function exists but is only applied to log output, not to HTTP response bodies.
- **Recommendation:** Apply `_redact_secrets()` to all `result.stderr` values before including in HTTP responses. Truncate to 4 KB maximum. Example: `return {"error": _redact_secrets(result.stderr)[:4096]}`.

### RR-25: Race Condition in tester_mcp.py 3-Strike Global State
- **Severity:** Low
- **Likelihood:** Low (Claude Code issues sequential tool calls in practice)
- **Description:** `tester_mcp.py` uses unprotected global variables (`_consecutive_failures`, `_failure_counted_for_current_run`) for the 3-strike hard stop mechanism. Concurrent async calls could race on these globals, either bypassing the hard stop (counter not incremented) or triggering a false hard stop (counter double-incremented).
- **Recommendation:** Protect with `asyncio.Lock`. Low urgency given sequential tool call pattern, but defensive coding prevents future issues if concurrency increases.

### RR-26: Generic Exception Info Disclosure in HTTP Responses
- **Severity:** Low
- **Likelihood:** Low (requires unexpected exception during request processing)
- **Description:** `server.py` catches broad `Exception` and returns `str(e)` in HTTP responses for `/ask` and `/plan`. Exception messages may contain internal file paths, library versions, or other implementation details.
- **Recommendation:** Return a generic error message (`"Internal agent execution error"`) in HTTP responses; log the full exception server-side at ERROR level.

---

## 7. Token Isolation Matrix

| Token | claude-server | proxy | mcp-server | plan-server | tester-server | git-server | log-server | caddy |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| ANTHROPIC_API_KEY | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| DYNAMIC_AGENT_KEY | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| CLAUDE_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | — |
| MCP_API_TOKEN | ✓ required | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| PLAN_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| TESTER_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| GIT_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden |
| LOG_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden |

---

## 8. STRIDE Summary Table

| Component | Spoofing | Tampering | Repudiation | Info Disclosure | DoS | Elevation of Privilege |
|-----------|----------|-----------|-------------|-----------------|-----|----------------------|
| **Caddy ingress** | Token theft (RR-8 no rate limit); unauthenticated /health (RR-22) | ~~tls_insecure_skip_verify~~ (RR-1 ✅) | No request audit log | Query content in logs (RR-17) | No rate limit (RR-8) | — |
| **claude-server** | — | Prompt injection via workspace (§4.2) | Query logged at INFO (RR-17) | Unredacted stderr in errors (RR-24); exception info disclosure (RR-26); env vars in subprocess scope | Unlimited concurrent subprocesses (RR-8) | ~~Slash command path traversal (RR-7)~~ ✅ |
| **docs_mcp.py** | — | — | — | startswith() prefix escape (RR-23) | — | — |
| **mcp-watchdog** | — | Bypassed by crafted tool responses | — | — | — | — |
| **files_mcp.py** | — | ~~URL param injection (RR-6)~~ ✅ | — | — | — | — |
| **mcp-server (Go)** | — | — | ~~File content fully logged (RR-5)~~ ✅ | ~~File content in logs (RR-5)~~ ✅ | ~~No resource limits (RR-3)~~ ✅ | cap_drop: ALL ✓ |
| **git-server** | — | Submodule path accepted without extra validation | — | Git history poisoning (§4.2) | — | — |
| **plan-server** | — | ~~Plan content injection (RR-14)~~ ✅ | — | — | — | cap_drop: ALL ✓ |
| **tester-server** | — | Test oracle manipulation (§4.2) | — | Test output injection (RR-13) | ~~No subprocess timeout (RR-2)~~ ✅; ~~no resource limits (RR-3)~~ ✅ | cap_drop: ALL ✓ |
| **tester_mcp.py** | — | 3-strike race condition (RR-25) | — | — | — | — |
| **log-server** | LOG_API_TOKEN theft | Log file tampering (host-level only) | Silent drops (RR-21) | Session metadata exfiltration via log_mcp (§4.2) | Log accumulation → disk exhaustion (RR-20) | cap_drop: ALL ✓ |
| **proxy (LiteLLM)** | DYNAMIC_AGENT_KEY as master_key | ~~Model routing manipulation~~ (RR-15 ✅) | — | Real API key in memory (egress locked) | — | cap_drop: ALL ✓, read_only ✓, int_net only ✓ |
| **Host / Volumes** | — | .secrets.env readable by host users | — | plans/, .git, logs/, certs on host disk | — | TA-5 insider |

---

## 9. Observations: Where This System Exceeds Typical Deployment Security

1. **Structural, not filtered, filesystem jail** (`os.OpenRoot`) — traversal blocked by the kernel, not regex.
2. **3-layer git hook prevention** — tmpfs shadow + separated gitdir + `core.hooksPath=/dev/null` + `--no-verify`.
3. **Baseline commit floor** for `git_reset_soft` — agent cannot rewrite pre-session history.
4. **Prompt immutability via filesystem ownership** — root-owned system prompts, verified at startup.
5. **mcp-watchdog** intercepting all tool calls before they reach MCP servers.
6. **Plan-server structural isolation** — the planning tool cannot read workspace or commit files by design.
7. **Log-server structural isolation** — session logging has no access to workspace, git, or plans; logs metadata only.
8. **Startup isolation checks with sys.exit(1)** — containers refuse to start if security invariants are violated.
9. **Constant-time token comparison** in all token verification paths.
10. **DYNAMIC_AGENT_KEY substitution** — the agent never holds the real Anthropic API key.
11. **MCP config as a build artifact** — the agent cannot modify which tools it has access to at runtime.
12. **Domain-locked egress filtering** — proxy on `int_net` only; all outbound traffic routes through a dedicated Caddy endpoint hardcoded to `api.anthropic.com:443` only.
13. **Read-only root filesystems** on internet-adjacent containers (caddy-sidecar, proxy).
14. **Per-service token scoping** — 7 distinct service tokens; compromise of one token does not grant access to other backends.
15. **Plan field-length validation** — all text fields bounded; oversized payloads rejected at HTTP 400.

---

## 10. Recommended Mitigations (Priority Order)

| Priority | Risk | Action | Status |
|----------|------|--------|--------|
| ~~P1~~ | ~~RR-1~~ | ~~Remove `tls_insecure_skip_verify`; domain-locked egress~~ | ✅ Done 2026-03-27 |
| ~~P1~~ | ~~RR-2~~ | ~~Add timeout to tester subprocess~~ | ✅ Done 2026-03-27 |
| ~~P2~~ | ~~RR-3~~ | ~~Add resource limits to all containers~~ | ✅ Done 2026-03-28 |
| ~~P2~~ | ~~RR-4~~ | ~~Per-service tokens~~ | ✅ Done 2026-03-28 |
| ~~P2~~ | ~~RR-5~~ | ~~Remove file content from mcp-server logs~~ | ✅ Done 2026-03-28 |
| ~~P2~~ | ~~RR-11~~ | ~~Redact secrets from log output; move stdout to DEBUG~~ | ✅ Done 2026-03-28 |
| ~~P3~~ | ~~RR-6~~ | ~~URL-encode path parameters in files_mcp.py~~ | ✅ Done 2026-03-28 |
| ~~P3~~ | ~~RR-7~~ | ~~Slash command path traversal hardening~~ | ✅ Done 2026-03-29 |
| ~~P3~~ | ~~RR-9~~ | ~~Add `cap_drop: ALL` to all containers~~ | ✅ Done 2026-03-28 |
| ~~P3~~ | ~~RR-12~~ | ~~Upgrade Go servers to TLS 1.3~~ | ✅ Done 2026-03-29 |
| ~~P3~~ | ~~RR-14~~ | ~~Plan field-length validation~~ | ✅ Done 2026-03-30 |
| ~~P3~~ | ~~RR-18~~ | ~~Add `GIT_API_TOKEN` and `LOG_API_TOKEN` to `_SECRET_TOKENS`~~ | ✅ Done 2026-03-30 |
| ~~P3~~ | ~~RR-16~~ | ~~Add `max_length` to `QueryRequest`; add Caddy body size limit~~ | ✅ Done 2026-03-30 |
| **P3** | **RR-8** | Add rate limiting or concurrency cap on `/ask`/`/plan` endpoints | **Open** |
| **P3** | **RR-20** | Add log retention/rotation policy to log-server; document TTL | **Open** |
| ~~P4~~ | ~~RR-19~~ | ~~Add `LOG_API_TOKEN` to `FORBIDDEN_ENV_VARS["proxy"]` and `FORBIDDEN_ENV_VARS["caddy"]` in `verify_isolation.py`~~ | ✅ Done 2026-04-04 |
| **P4** | **RR-17** | Truncate query logging to 500 chars at INFO level | **Open** |
| P4 | RR-13 | Document test output as trust boundary; add 64 KB output length cap | Open |
| ~~P4~~ | ~~RR-15~~ | ~~Whitelist allowed model names in `/ask` and `/plan`~~ | ✅ Done 2026-03-30 |
| **P3** | **RR-23** | Fix `startswith()` prefix matching in `docs_mcp.py` — append `os.sep` to base path | **Open** |
| **P3** | **RR-24** | Apply `_redact_secrets()` to `result.stderr` before returning in HTTP responses | **Open** |
| P4 | RR-10 | Add cert expiry monitoring; document rotation procedure | Open |
| P4 | RR-21 | Document git history as primary audit trail; optionally expose dropped-event counter | Open |
| P4 | RR-22 | Block `/health` at Caddy layer or document as accepted risk | Open |
| P4 | RR-25 | Add `asyncio.Lock` to tester_mcp.py 3-strike globals | Open |
| P4 | RR-26 | Return generic error messages in HTTP responses; log full exceptions server-side | Open |
