# Threat Model: secure-claude

**Date:** 2026-04-11 (updated — added codex-server coverage, new MCP tools, RR-27)
**Scope:** secure-claude cluster — hardened containerised environment for running Claude Code and OpenAI Codex as autonomous AI agents
**Methodology:** STRIDE (Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege)
**Classification:** Internal Engineering Review

---

## 1. Assets Inventory

| Asset | Confidentiality | Integrity | Availability | Location |
|-------|----------------|-----------|--------------|----------|
| `ANTHROPIC_API_KEY` | Critical — billing/abuse if leaked | High — must not be altered | Medium | `proxy` container only (int_net, no direct internet), host `.secrets.env` |
| `OPENAI_API_KEY` | Critical — billing/abuse if leaked | High — must not be altered | Medium | `proxy` container only (int_net, no direct internet), host `.secrets.env` |
| `DYNAMIC_AGENT_KEY` | High — grants API access via proxy | High | High | `claude-server`, `codex-server`, `proxy` |
| `CLAUDE_API_TOKEN` | High — gates external agent invocation | High | High | `claude-server` only |
| `CODEX_API_TOKEN` | High — gates external codex invocation | High | High | `codex-server` only |
| `MCP_API_TOKEN` | High — mcp-server auth | High | High | `claude-server`, `codex-server`, `mcp-server` |
| `PLAN_API_TOKEN` | High — plan-server auth | High | High | `claude-server`, `codex-server`, `plan-server` |
| `TESTER_API_TOKEN` | High — tester-server auth | High | High | `claude-server`, `codex-server`, `tester-server` |
| `GIT_API_TOKEN` | High — git-server auth | High | High | `claude-server`, `codex-server`, `git-server` |
| `LOG_API_TOKEN` | Medium — log-server auth; grants read access to full session audit trail | High | Medium | `claude-server`, `codex-server`, `log-server` |
| TLS CA key (`ca.key`) | Critical — can sign arbitrary certs | Critical | Low (used only at build) | Host `cluster/certs/ca.key` (640 perms) |
| TLS leaf certs/keys | High — MITM if stolen | High | Medium | Per-container `/app/certs/` |
| `/workspace` source code | Medium — may contain business logic | Critical — agent commits changes | High | Host bind mount → `mcp-server` (rw), others (ro) |
| Git history (`.git`) | Medium | Critical — commits are permanent | High | Host `workspace/.git` → `/gitdir` in `git-server` |
| Plan state (`/plans`) | Low | High — directs agent work | High | Host `plans/` → `plan-server` |
| Session logs (`/logs`) | Medium — metadata: tool calls, file paths, token counts, timing | High — audit trail integrity | Medium | Host `logs/` → `log-server` (rw) |
| Test output | Low | High — misleading output could cause bad commits | Medium | In-memory, `tester-server` |
| System prompts (`/app/prompts/`) | High — defines agent behaviour | Critical — modification changes agent goals | Medium | Baked into `claude-server`/`codex-server` images, root-owned |
| Slash commands (`~/.claude/commands/`, `~/.codex/commands/`) | Medium | High | Medium | Baked into agent images, root-owned |
| Container environment variables | High | High | — | Runtime process memory |
| Docker socket | Critical — full host escape if accessible | Critical | — | Should NOT be accessible |

---

## 2. Trust Boundaries

```
[External Network]
       │  HTTPS/TLS 1.3, Bearer CLAUDE_API_TOKEN or CODEX_API_TOKEN
       ▼
[caddy-sidecar :8443]  ← only container on ext_net + int_net
  │    │  HTTPS, internal CA, no auth header added
  │    ▼
  │  [claude-server :8000]  ← int_net only
  │  [codex-server :8000]   ← int_net only (parallel agent)
  │    │  subprocess ANTHROPIC_API_KEY=DYNAMIC_AGENT_KEY (claude)
  │    │  subprocess OPENAI_API_KEY=DYNAMIC_AGENT_KEY (codex)
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
  [Anthropic API / OpenAI API (via proxy routing)]

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
| Internet → Caddy | TLS 1.3 + bearer token (CLAUDE_API_TOKEN / CODEX_API_TOKEN), constant-time compare |
| Caddy → claude-server | Internal CA; Caddy verifies `ca.crt` |
| Caddy → codex-server | Internal CA; Caddy verifies `ca.crt` |
| claude-server → mcp-server | Bearer MCP_API_TOKEN, TLS + internal CA |
| claude-server → git-server | Bearer GIT_API_TOKEN, TLS + internal CA |
| claude-server → plan-server | Bearer PLAN_API_TOKEN, TLS + internal CA |
| claude-server → tester-server | Bearer TESTER_API_TOKEN, TLS + internal CA |
| claude-server → log-server | Bearer LOG_API_TOKEN, TLS + internal CA |
| codex-server → mcp-server | Bearer MCP_API_TOKEN, TLS + internal CA |
| codex-server → plan-server | Bearer PLAN_API_TOKEN, TLS + internal CA |
| codex-server → log-server | Bearer LOG_API_TOKEN, TLS + internal CA |
| MCP stdio → Go/REST backends | mcp-watchdog intercepts all JSON-RPC before forwarding |
| Agent subprocess → filesystem | `/workspace` mounted ro in agent containers; writes only via mcp-server's os.OpenRoot jail |
| claude-server → Anthropic | DYNAMIC_AGENT_KEY only (not real key); route via proxy (int_net only) → caddy-sidecar:8081 → api.anthropic.com |
| codex-server → OpenAI | DYNAMIC_AGENT_KEY only (not real key); route via proxy (int_net only) → caddy-sidecar |
| proxy → Internet | **No direct access.** Proxy is int_net only; egress exclusively via caddy-sidecar:8081, hardcoded to api.anthropic.com:443 |
| Host → container | UID 1000, no Docker socket, `cap_drop: ALL` on all containers |
| plan-server ↔ workspace | Structurally separated — plan-server has no `/workspace` mount |
| log-server ↔ workspace/git/plans | Structurally separated — log-server has no `/workspace`, `/gitdir`, or `/plans` mount |

---

## 3. Threat Actors

### TA-1: Malicious External Caller
Network access to Caddy `:8443`. Does not hold `CLAUDE_API_TOKEN` or `CODEX_API_TOKEN`. Goal: invoke agent without auth, extract secrets, DoS.

### TA-2: Compromised LLM Output
Claude Code or Codex CLI produces adversarial tool calls — either due to a jailbreak, a model regression, or an upstream supply-chain issue. Has full access to all MCP tool surfaces.

### TA-3: Prompt Injection via Workspace Content
Malicious content in files the agent reads (`/workspace`, `/docs`, git history, plan files, test output). Attempts to override system prompt behaviour by embedding instructions in data.

### TA-4: Compromised Dependency
A malicious version of a pip/npm/Go package (e.g., `mcp`, `litellm`, `claude-code`, `codex`, `mcp-watchdog`) is installed and executes arbitrary code in-container. Has the permissions of the container's appuser.

### TA-5: Insider with Host Access
Can read `.secrets.env`, Docker volumes, container logs, `.env`, `.cluster_tokens.env`. May also modify `docker-compose.yml` or Dockerfiles before a rebuild.

---

## 4. Attack Vectors

### 4.1 Infrastructure Attacks

#### Container Escape
- **Attack:** Exploit kernel vulnerability, Docker breakout via mounted socket, or privileged container.
- **Prerequisites:** No Docker socket is mounted. No `--privileged`. UID 1000. All containers have `cap_drop: ALL`.
- **Impact:** Host compromise; access to `.secrets.env` and real API keys.
- **Residual risk:** Low — `cap_drop: ALL` covers all nine containers.

#### Network Segmentation Bypass
- **Attack:** Compromise `caddy-sidecar` (which sits on both `ext_net` and `int_net`) to pivot to internal services.
- **Prerequisites:** RCE in Caddy or its config. Config is mounted read-only. Caddy runs as non-root with `cap_drop: ALL`, `read_only: true`, `pids_limit: 100`.
- **Impact:** Direct access to `mcp-server`, `plan-server`, `tester-server`, `log-server` at HTTPS layer. Still requires per-service token for auth.

#### Volume Mount Traversal
- **Attack:** Abuse the git gitdir mount (`./workspace/.git:/gitdir`) — if `workspace` is a symlink pointing to a sensitive directory, `/gitdir` could expose unexpected content.
- **Prerequisites:** Attacker can influence what `workspace` symlinks to (host access).
- **Impact:** Agent git operations touching unexpected content.

#### Environment Variable Leakage
- **Attack:** `server.py` does `env={**os.environ, ...}` when spawning agent CLI, passing all parent env vars — including all service tokens — into the subprocess. Any code the CLI spawns inherits these.
- **Impact:** An adversarial MCP server injected by prompt injection could read these env vars. The CLI may also echo them in conversation output.
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
- **Specific risk:** All service tokens are in `os.environ` of the CLI subprocess via `env={**os.environ, ...}` in `server.py`.
- **Exfiltration channel:** Agent writes content to `/workspace` via `write_file`; committed to git history and accessible from host mount. Network exfiltration is blocked — egress locked to `api.anthropic.com`. Covert-channel encoding in API request bodies remains a theoretical risk.

#### File Duplication Abuse via copy_file (New — 2026-04-11)
- **Attack:** Agent is instructed (via prompt injection) to use `copy_file` to duplicate sensitive workspace files to predictable paths, or to overwrite critical files (e.g., `test.sh`, config files) with attacker-controlled content by first writing a payload via `write_file` then copying over the target with `overwrite=true`.
- **Prerequisites:** Prompt injection that causes the agent to issue copy_file with overwrite. The copy_file tool requires `overwrite=true` to replace existing files (409 Conflict otherwise).
- **Impact:** Medium — same blast radius as `write_file` (limited to `/workspace` via os.OpenRoot jail). The copy_file tool does not expand the attack surface beyond what write_file already provides, but it offers a more subtle attack vector that may evade content-based mcp-watchdog rules since the payload is already on disk.
- **Mitigation:** os.OpenRoot jail prevents escape. mcp-watchdog intercepts the tool call. No additional mitigation required beyond existing controls.

#### Log Exfiltration via log_mcp Tools
- **Attack:** Agent is instructed (via prompt injection) to call `list_sessions` and `query_logs`, harvesting session metadata (tool calls, file paths accessed, timing data) and embedding it in workspace files or commit messages.
- **Prerequisites:** Agent already has legitimate access to log_mcp tools. Prompt injection redirects use.
- **Impact:** Session audit trail exposed; patterns of prior operation (which files were accessed, what tasks were run, token consumption) revealed through git history.
- **Note:** Log content does not include file bodies (structural constraint), but file paths and tool call names are present and may be sensitive.

#### Recursive Self-Modification
- **Agent's `/app/` in claude-server/codex-server** cannot be reached by `mcp-server` (different containers). However, the agent can modify `docs/CONTEXT.md`, `docs/PLAN.md`, and workspace source files — shaping its own future context and instructions.

---

### 4.3 Authentication and Authorization Attacks

#### Token Replay / Theft
- **Attack:** Intercept `CLAUDE_API_TOKEN` or `CODEX_API_TOKEN` from a `query.sh` invocation (process list, network sniff, shell history) and replay requests.
- **Mitigation present:** Tokens are 64-character random hex, regenerated on every `run.sh`.
- **Gap:** No per-session or per-request nonce; stolen token valid until `run.sh` is re-run. No rate limiting (RR-8).

#### Privilege Escalation Between Token Scopes
- **Status (RR-4, resolved 2026-03-28):** Each backend now has its own token. Compromise of one token no longer grants access to other services.
- **Residual:** `claude-server` and `codex-server` hold all service tokens simultaneously. A token exfiltration from either agent container still exposes all tokens, but blast radius per token is bounded to a single backend.

#### Bypass of Token Validation
- All token comparisons use `secrets.compare_digest` (Python) or `subtle.ConstantTimeCompare` (Go). All services call `log.Fatal` on empty token at startup. No bypass risk identified.

#### ~~LOG_API_TOKEN Missing from proxy and caddy Isolation Checks~~ (RESOLVED — RR-19)
- **Resolution (2026-04-04):** `LOG_API_TOKEN` added to `FORBIDDEN_ENV_VARS["proxy"]` and `FORBIDDEN_ENV_VARS["caddy"]` in `verify_isolation.py`. Regression tests added.

#### Unauthenticated /health Endpoint (RR-22)
- **Attack:** The `/health` endpoint in `server.py` has no authentication requirement. An unauthenticated external caller (TA-1) can probe server availability.
- **Impact:** Low — information disclosure (service liveness). Combined with RR-8 (no rate limiting), enables availability probing.
- **Note:** Health endpoints are conventionally unauthenticated for load balancer integration.

#### docs_mcp.py Path Traversal via Prefix Matching (RR-23)
- **Attack:** `_safe_path()` in `docs_mcp.py` uses `resolved.startswith(os.path.realpath(DOCS_DIR))` without appending `os.sep`. A sibling directory sharing the `/docs` prefix would pass the check.
- **Impact:** Medium — agent could read files outside the intended docs directory. Mitigated by Docker mount isolation (no sibling directories exist in current layout).
- **Recommendation:** Append `os.sep` to the base path or check equality.

#### Unredacted stderr in HTTP Error Responses (RR-24)
- **Attack:** `server.py` returns raw `result.stderr` in HTTP error responses without passing through `_redact_secrets()`. Applies to both claude-server and codex-server.
- **Impact:** Medium — information disclosure of internal paths, dependency versions, and potentially token fragments in error messages.
- **Recommendation:** Apply `_redact_secrets()` to all `result.stderr` values before returning in HTTP responses.

#### Race Condition in tester_mcp.py Global State (RR-25)
- **Attack:** Unprotected global variables for the 3-strike hard stop mechanism. Concurrent async calls could race on these globals.
- **Impact:** Low — incorrect 3-strike enforcement under concurrent calls (unlikely in practice).

#### Generic Exception Info Disclosure in HTTP Responses (RR-26)
- **Attack:** Both `claude-server` and `codex-server` catch broad `Exception` and return `str(e)` in HTTP responses.
- **Impact:** Low — exception messages may leak internal details to authenticated callers.

#### Incomplete codex-server Isolation Checks (RR-27 — New)
- **Attack:** `verify_isolation.py` does not fully enforce environment variable rules for the `codex-server` role. `PLAN_API_TOKEN` and `LOG_API_TOKEN` are used by codex-server but not listed in `REQUIRED_ENV_VARS`. `TESTER_API_TOKEN` and `GIT_API_TOKEN` are injected via docker-compose but **not used** by codex-server, and are not listed in `FORBIDDEN_ENV_VARS`.
- **Prerequisites:** Misconfiguration in docker-compose or a compromised codex-server container.
- **Impact:** Medium — violates principle of least privilege. If codex-server is compromised, attackers gain access to TESTER_API_TOKEN and GIT_API_TOKEN unnecessarily. Missing REQUIRED checks mean codex-server could start without PLAN_API_TOKEN or LOG_API_TOKEN and fail at runtime rather than at startup.
- **Recommendation:**
  1. Add `PLAN_API_TOKEN`, `TESTER_API_TOKEN`, `GIT_API_TOKEN`, `LOG_API_TOKEN` to `REQUIRED_ENV_VARS["codex-server"]`.
  2. If codex-server does not use TESTER_API_TOKEN and GIT_API_TOKEN directly, remove them from docker-compose and add them to `FORBIDDEN_ENV_VARS["codex-server"]`.

---

### 4.4 Data Retention and Audit

#### RR-20: Session Log Data Retention — No Rotation or TTL Policy
- **Attack / Scenario:** JSONL log files in `/logs` accumulate indefinitely. Host-level compromise exposes all historical session metadata.
- **Severity:** Medium
- **Recommendation:** Document retention policy; add `LOG_RETENTION_DAYS` env var; set disk quota.

#### RR-21: Silent Log Drops — Incomplete Audit Trail
- **Attack / Scenario:** `_emit_log_event()` uses fire-and-forget daemon threads. Log-server unavailability causes silent event loss.
- **Severity:** Low
- **Recommendation:** Document git commit history as primary audit trail.

---

## 5. Existing Mitigations

### Credential Isolation
- Token matrix enforced at startup: `verify_isolation.py` (claude-server, codex-server), `proxy_wrapper.py` (proxy), `entrypoint.sh` scripts. Each container checks for forbidden env vars and refuses to start if violated.
- `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are never in agent containers at entrypoint time. `DYNAMIC_AGENT_KEY` is substituted at subprocess spawn time.

### Network Isolation
- `int_net` is `internal: true`. Only `caddy-sidecar` spans both networks.
- `proxy` is `int_net` only — no direct internet access since 2026-03-27.
- `log-server` is `int_net` only; no external routing.

### Filesystem Jail (Go os.OpenRoot)
- `mcp-server/main.go` calls `os.OpenRoot("/workspace")` at startup. All file operations (including copy_file and diff_files) use this root object. Go 1.24+ provides kernel-level jail enforcement.
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
- `verify_isolation.py` performs checks for all container roles (claude-server, codex-server, mcp-server, plan-server, tester-server, proxy, caddy, git-server, log-server). All containers verify forbidden/required env vars.

### Prompt Immutability
- `/app/prompts/` and command directories owned by `root:root`, mode `444`/`555`. UID 1000 agent cannot modify them.

### Non-root Containers
- All nine containers run as UID 1000 with `cap_drop: ALL`.

### Read-only Mounts
- `/workspace` mounted ro in `claude-server`, `codex-server`, and `tester-server`. `/docs` mounted ro in agent containers. Caddyfile and proxy config mounted ro.

### Plan and Tester Isolation
- `plan-server` has no `/workspace`, `/gitdir`, or secrets. `tester-server` has `/workspace:ro` only.

### Log Server Structural Isolation
- `log-server` has no access to `/workspace`, `/gitdir`, `/plans`, or other service tokens.

### TLS Everywhere (Internal)
- Internal CA generated fresh on each `run.sh`. All service-to-service over HTTPS with CA verification.
- `TLSConfig.MinVersion = tls.VersionTLS13` in all Go servers. Caddy ingress also TLS 1.3.

### MCP Config as Build Artifact
- `.mcp.json` baked into agent images at build time. Agent cannot modify it at runtime.

### Constant-time Token Comparison
- `secrets.compare_digest` (Python) and `subtle.ConstantTimeCompare` (Go) throughout.

### Egress Filtering (2026-03-27)
- Proxy on `int_net` only. All API calls route through `caddy-sidecar:8081`, hardcoded to `api.anthropic.com:443` with public TLS.

### Container Hardening
- All nine containers: `cap_drop: ALL`, `mem_limit`, `cpus`, `pids_limit`. `caddy-sidecar` and `proxy` additionally have `read_only: true`.

### Log Sanitization
- `_redact_secrets()` redacts known token values with `[REDACTED]` in both claude-server and codex-server.

### Model Allowlists
- claude-server: `claude-sonnet-4-6`, `claude-opus-4-6`, `claude-haiku-4-5-20251001`
- codex-server: `gpt-4o`, `gpt-5.3-codex`, `o3`
- Both validate `request.model` before subprocess invocation.

### Concurrency Control
- Both claude-server and codex-server enforce a semaphore limiting to 1 concurrent `/ask` or `/plan` request.

### New MCP Tools Security (2026-04-11)
- `copy_file`: Requires `overwrite=true` to replace existing files (409 Conflict otherwise). Source must exist (404). All paths constrained by os.OpenRoot.
- `diff_files`: Read-only operation returning unified diff text. Both paths constrained by os.OpenRoot.

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
`os.path.basename` + `PATH_BLACKLIST` check added.

### RR-8: No Rate Limiting on /ask and /plan Endpoints
- **Severity:** Medium
- **Likelihood:** Low (requires stolen token)
- **Description:** No rate limiting at the Caddy or FastAPI layer. An authenticated caller can submit unlimited concurrent requests. Note: both agent servers have a semaphore capping concurrent requests to 1 per server, which provides partial mitigation.
- **Recommendation:** Add a Caddy rate-limit directive or enforce at the infrastructure level.

### ~~RR-9: Missing cap_drop on Most Containers~~ — RESOLVED (2026-03-28)

### RR-10: Cert Validity 365 Days, No Rotation Mechanism
- **Severity:** Low
- **Likelihood:** Medium (over time)
- **Description:** All service certs valid for 365 days. No automated rotation. Expired certs silently break internal TLS.
- **Recommendation:** Add expiry monitoring. Consider 90-day cert lifetimes.

### ~~RR-11: Claude Code Subprocess Stdout/Stderr Logged Fully~~ — RESOLVED (2026-03-28)

### ~~RR-12: TLS Minimum Version TLS 1.2 on Internal Go Servers~~ — RESOLVED (2026-03-29)

### RR-13: Test Output Not Sanitised Before Presenting to Agent
- **Severity:** Medium
- **Likelihood:** Medium
- **Description:** `tester/main.go` returns full `cmd.CombinedOutput()` as the `output` field. Prompt-injection content in test output is included in the agent's context without sanitisation.
- **Recommendation:** Document as trust boundary. Add 64 KB output length cap.

### ~~RR-14: Plan Field-length Validation Missing~~ — RESOLVED (2026-03-30)

### ~~RR-15: Agent Model Parameter Not Validated~~ — RESOLVED (2026-03-30)

### ~~RR-16: Unbounded Request Body Size on /ask and /plan~~ — RESOLVED (2026-03-30)

### RR-17: Query Content Logged at INFO Level Without Truncation
- **Severity:** Low
- **Likelihood:** Medium (every invocation)
- **Description:** Both `claude-server` and `codex-server` log the full query at `INFO` level unconditionally.
- **Recommendation:** Truncate to 500 characters at INFO level; log full query at DEBUG level.

### ~~RR-18: GIT_API_TOKEN Absent from Log Redaction List~~ — RESOLVED (2026-03-30)

### ~~RR-19: LOG_API_TOKEN Missing from proxy and caddy Isolation Checks~~ — RESOLVED (2026-04-04)

### RR-20: Session Log Data Retention — No Rotation or TTL Policy
- **Severity:** Medium
- **Likelihood:** Certain (logs grow on every run)
- **Description:** JSONL log files in `/logs` accumulate indefinitely with no retention policy or disk quota.
- **Recommendation:** Add `LOG_RETENTION_DAYS` env var; set disk quota on `./logs` volume.

### RR-21: Silent Log Drops — Incomplete Audit Trail
- **Severity:** Low
- **Likelihood:** Low (requires log-server unavailability)
- **Description:** `_emit_log_event()` uses fire-and-forget daemon threads. Log-server unavailability causes silent event loss.
- **Recommendation:** Document git commit history as primary audit trail.

### RR-22: Unauthenticated /health Endpoint
- **Severity:** Low
- **Description:** `/health` in both agent servers has no bearer token check. Aids reconnaissance if Caddy routes it externally.
- **Recommendation:** Block at Caddy layer or document as accepted risk.

### RR-23: docs_mcp.py Path Traversal via startswith() Prefix Matching
- **Severity:** Medium
- **Likelihood:** Low (no sibling directories in current Docker layout)
- **Description:** `_safe_path()` validates using `startswith()` without `os.sep` suffix. Latent flaw activated by mount layout changes.
- **Recommendation:** Append `os.sep` to base path. Add unit test.

### RR-24: Unredacted stderr in HTTP Error Responses
- **Severity:** Medium
- **Likelihood:** Medium (occurs on every subprocess failure)
- **Description:** Both claude-server and codex-server return raw `result.stderr` in HTTP error responses without `_redact_secrets()`.
- **Recommendation:** Apply `_redact_secrets()` to stderr before returning. Truncate to 4 KB.

### RR-25: Race Condition in tester_mcp.py 3-Strike Global State
- **Severity:** Low
- **Likelihood:** Low (sequential tool calls in practice)
- **Description:** Unprotected global variables for 3-strike hard stop.
- **Recommendation:** Protect with `asyncio.Lock`.

### RR-26: Generic Exception Info Disclosure in HTTP Responses
- **Severity:** Low
- **Description:** Broad `Exception` catch returns `str(e)` in HTTP responses.
- **Recommendation:** Return generic error message; log full exception server-side.

### RR-27: Incomplete codex-server Isolation Checks (New — 2026-04-11)
- **Severity:** Medium
- **Likelihood:** Medium (misconfiguration path exists today)
- **Description:** `verify_isolation.py` has incomplete environment variable rules for the `codex-server` role:
  - `PLAN_API_TOKEN` and `LOG_API_TOKEN` are **used** by codex-server (for plan queries and log emission) but **not listed** in `REQUIRED_ENV_VARS["codex-server"]`. If these tokens are missing from docker-compose, codex-server starts successfully but fails at runtime when accessing plan-server or log-server.
  - `TESTER_API_TOKEN` and `GIT_API_TOKEN` are **injected** via docker-compose but **not used** by codex-server's `server.py`. They are present in the process environment unnecessarily and are **not listed** in `FORBIDDEN_ENV_VARS["codex-server"]`.
  - This violates the principle of least privilege and weakens the isolation check's ability to detect misconfiguration.
- **Recommendation:**
  1. Add `PLAN_API_TOKEN`, `LOG_API_TOKEN` to `REQUIRED_ENV_VARS["codex-server"]`.
  2. Either: (a) add `TESTER_API_TOKEN`, `GIT_API_TOKEN` to `REQUIRED_ENV_VARS` if codex-server needs them for MCP wrappers, or (b) remove them from docker-compose and add to `FORBIDDEN_ENV_VARS` if not needed.
  3. Add regression tests for codex-server isolation rules in `test_isolation.py`.

---

## 7. Token Isolation Matrix

| Token | claude-server | codex-server | proxy | mcp-server | plan-server | tester-server | git-server | log-server | caddy |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| ANTHROPIC_API_KEY | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| OPENAI_API_KEY | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| DYNAMIC_AGENT_KEY | ✓ required | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| CLAUDE_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | — |
| CODEX_API_TOKEN | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | — |
| MCP_API_TOKEN | ✓ required | ✓ required | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| PLAN_API_TOKEN | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| TESTER_API_TOKEN | ✓ required | ⚠️ injected | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| GIT_API_TOKEN | ✓ required | ⚠️ injected | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden |
| LOG_API_TOKEN | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden |

> **⚠️ injected:** Token is present in the codex-server environment (via docker-compose) but not directly used by codex-server's `server.py`. Likely needed by shared MCP wrappers but should be validated. See RR-27.

---

## 8. STRIDE Summary Table

| Component | Spoofing | Tampering | Repudiation | Info Disclosure | DoS | Elevation of Privilege |
|-----------|----------|-----------|-------------|-----------------|-----|----------------------|
| **Caddy ingress** | Token theft (RR-8 no rate limit); unauthenticated /health (RR-22) | ~~tls_insecure_skip_verify~~ (RR-1 ✅) | No request audit log | Query content in logs (RR-17) | No rate limit (RR-8) | — |
| **claude-server** | — | Prompt injection via workspace (§4.2) | Query logged at INFO (RR-17) | Unredacted stderr (RR-24); exception info (RR-26); env vars in subprocess | Unlimited subprocesses mitigated by semaphore (RR-8) | ~~Slash command traversal (RR-7)~~ ✅ |
| **codex-server** | — | Prompt injection via workspace (§4.2) | Query logged at INFO (RR-17) | Unredacted stderr (RR-24); exception info (RR-26); unnecessary tokens in env (RR-27) | Semaphore limits to 1 concurrent | Incomplete isolation checks (RR-27) |
| **docs_mcp.py** | — | — | — | startswith() prefix escape (RR-23) | — | — |
| **mcp-watchdog** | — | Bypassed by crafted tool responses | — | — | — | — |
| **files_mcp.py** | — | ~~URL param injection (RR-6)~~ ✅ | — | — | — | — |
| **mcp-server (Go)** | — | copy_file overwrite (mitigated by os.OpenRoot) | ~~File content logged (RR-5)~~ ✅ | — | — | cap_drop: ALL ✓ |
| **git-server** | — | Submodule path accepted without extra validation | — | Git history poisoning (§4.2) | — | — |
| **plan-server** | — | ~~Plan content injection (RR-14)~~ ✅ | — | — | — | cap_drop: ALL ✓ |
| **tester-server** | — | Test oracle manipulation (§4.2) | — | Test output injection (RR-13) | ~~No timeout (RR-2)~~ ✅ | cap_drop: ALL ✓ |
| **tester_mcp.py** | — | 3-strike race condition (RR-25) | — | — | — | — |
| **log-server** | LOG_API_TOKEN theft | Log file tampering (host-level only) | Silent drops (RR-21) | Session metadata exfiltration (§4.2) | Log accumulation (RR-20) | cap_drop: ALL ✓ |
| **proxy (LiteLLM)** | DYNAMIC_AGENT_KEY as master_key | ~~Model routing manipulation~~ (RR-15 ✅) | — | Real API keys in memory (egress locked) | — | cap_drop: ALL ✓, read_only ✓, int_net only ✓ |
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
10. **DYNAMIC_AGENT_KEY substitution** — the agent never holds real API keys.
11. **MCP config as a build artifact** — the agent cannot modify which tools it has access to at runtime.
12. **Domain-locked egress filtering** — proxy on `int_net` only; all outbound traffic hardcoded to `api.anthropic.com:443`.
13. **Read-only root filesystems** on internet-adjacent containers (caddy-sidecar, proxy).
14. **Per-service token scoping** — 8 distinct service tokens; compromise of one does not grant access to other backends.
15. **Plan field-length validation** — all text fields bounded; oversized payloads rejected at HTTP 400.
16. **Dual model allowlists** — separate allowlists for Claude and OpenAI models prevent arbitrary model usage.
17. **Concurrency semaphore** — both agent servers limit to 1 concurrent request, providing partial DoS mitigation.

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
| **P3** | **RR-27** | Complete codex-server isolation checks in `verify_isolation.py` — add missing REQUIRED/FORBIDDEN env vars | **Open** |
| **P3** | **RR-8** | Add rate limiting or concurrency cap on `/ask`/`/plan` endpoints | **Open** |
| **P3** | **RR-23** | Fix `startswith()` prefix matching in `docs_mcp.py` — append `os.sep` | **Open** |
| **P3** | **RR-24** | Apply `_redact_secrets()` to `result.stderr` before returning in HTTP responses | **Open** |
| **P3** | **RR-20** | Add log retention/rotation policy to log-server; document TTL | **Open** |
| ~~P4~~ | ~~RR-19~~ | ~~Add `LOG_API_TOKEN` to proxy/caddy FORBIDDEN lists~~ | ✅ Done 2026-04-04 |
| **P4** | **RR-17** | Truncate query logging to 500 chars at INFO level | **Open** |
| P4 | RR-13 | Document test output as trust boundary; add 64 KB output length cap | Open |
| ~~P4~~ | ~~RR-15~~ | ~~Whitelist allowed model names~~ | ✅ Done 2026-03-30 |
| P4 | RR-10 | Add cert expiry monitoring; document rotation procedure | Open |
| P4 | RR-21 | Document git history as primary audit trail; expose dropped-event counter | Open |
| P4 | RR-22 | Block `/health` at Caddy layer or document as accepted risk | Open |
| P4 | RR-25 | Add `asyncio.Lock` to tester_mcp.py 3-strike globals | Open |
| P4 | RR-26 | Return generic error messages in HTTP responses; log full exceptions server-side | Open |
