# Threat Model: secure-claude

**Date:** 2026-03-30 (updated 2026-03-30 — full refresh)
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
| TLS CA key (`ca.key`) | Critical — can sign arbitrary certs | Critical | Low (used only at build) | Host `cluster/certs/ca.key` (640 perms) |
| TLS leaf certs/keys | High — MITM if stolen | High | Medium | Per-container `/app/certs/` |
| `/workspace` source code | Medium — may contain business logic | Critical — agent commits changes | High | Host bind mount → `mcp-server` (rw), others (ro) |
| Git history (`.git`) | Medium | Critical — commits are permanent | High | Host `workspace/.git` → `/gitdir` in `git-server` |
| Plan state (`/plans`) | Low | High — directs agent work | High | Host `plans/` → `plan-server` |
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

[Host ↔ Container]
  - Docker volume mounts (workspace rw, git rw, plans rw, certs rw)
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
| MCP stdio → Go/REST backends | mcp-watchdog intercepts all JSON-RPC before forwarding |
| Agent subprocess → filesystem | `/workspace` mounted ro in claude-server; writes only via mcp-server's os.OpenRoot jail |
| claude-server → Anthropic | DYNAMIC_AGENT_KEY only (not real key); route via proxy (int_net only) → caddy-sidecar:8081 → api.anthropic.com |
| proxy → Internet | **No direct access.** Proxy is int_net only; egress exclusively via caddy-sidecar:8081, hardcoded to api.anthropic.com:443 |
| Host → container | UID 1000, no Docker socket, `cap_drop: ALL` on all containers |
| plan-server ↔ workspace | Structurally separated — plan-server has no `/workspace` mount |

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
- **Residual risk:** Low — `cap_drop: ALL` covers all seven containers.

#### Network Segmentation Bypass
- **Attack:** Compromise `caddy-sidecar` (which sits on both `ext_net` and `int_net`) to pivot to internal services.
- **Prerequisites:** RCE in Caddy or its config. Config is mounted read-only. Caddy runs as non-root with `cap_drop: ALL`, `read_only: true`, `pids_limit: 100`.
- **Impact:** Direct access to `mcp-server`, `plan-server`, `tester-server` at HTTPS layer. Still requires per-service token for auth.

#### Volume Mount Traversal
- **Attack:** Abuse the git gitdir mount (`./workspace/.git:/gitdir`) — if `workspace` is a symlink pointing to a sensitive directory, `/gitdir` could expose unexpected content.
- **Prerequisites:** Attacker can influence what `workspace` symlinks to (host access).
- **Impact:** Agent git operations touching unexpected content.

#### Environment Variable Leakage
- **Attack:** `server.py` does `env={**os.environ, ...}` when spawning Claude Code, passing all parent env vars — including `MCP_API_TOKEN`, `PLAN_API_TOKEN`, `TESTER_API_TOKEN`, `GIT_API_TOKEN`, `CLAUDE_API_TOKEN` — into the Claude Code subprocess. Any code Claude Code spawns inherits these.
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
- **Specific risk:** All service tokens (`MCP_API_TOKEN`, `PLAN_API_TOKEN`, `TESTER_API_TOKEN`, `GIT_API_TOKEN`, `DYNAMIC_AGENT_KEY`, `CLAUDE_API_TOKEN`) are in `os.environ` of the Claude Code subprocess via `env={**os.environ, ...}` in `server.py`.
- **Exfiltration channel:** Agent writes content to `/workspace` via `write_file`; committed to git history and accessible from host mount. Network exfiltration is blocked — egress locked to `api.anthropic.com`. Covert-channel encoding in API request bodies remains a theoretical risk.

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
- **Residual:** `claude-server` holds all four service tokens simultaneously. A token exfiltration from claude-server still exposes all four, but blast radius per token is bounded to a single backend.

#### Bypass of Token Validation
- All token comparisons use `secrets.compare_digest` (Python) or `subtle.ConstantTimeCompare` (Go). All services call `log.Fatal` on empty token at startup. No bypass risk identified.

---

### 4.4 New / Previously Untracked Vectors

#### RR-16: Unbounded Request Body Size on /ask and /plan
- **Attack:** An authenticated caller submits a POST with a very large `query` field (e.g., 100 MB of text). FastAPI has no default body size limit. The full string is:
  1. Held in memory by FastAPI/uvicorn
  2. Logged at INFO level: `logger.info(f"Received authenticated query: {request.query}...")`
  3. Passed as a CLI argument to the `claude` subprocess (`-- <query>`)
- **Impact:** Memory exhaustion in `claude-server` (which has a 4 GB mem_limit); log volume explosion; potential subprocess argument size limit error (Linux `ARG_MAX` ≈ 2 MB).
- **Severity:** Medium
- **Recommendation:** Add a `max_length` constraint on the `query` and `model` fields in `QueryRequest` (Pydantic `Field(max_length=N)`) and/or a Caddy body size limit directive.

#### RR-17: Query Content Logged at INFO Level Without Truncation
- **Attack:** The full user query is logged at `INFO` level unconditionally (`logger.info(f"Received authenticated query: {request.query}...")`). Unlike subprocess stdout (which was moved to DEBUG in RR-11), the *input* query is always logged.
- **Scenarios:**
  - A legitimate user accidentally includes a secret or PII in their query string — it is stored permanently in logs.
  - A large adversarial query fills log storage.
  - An adversary with log read access (TA-5) sees the full query content of every invocation.
- **Impact:** Low–Medium (depends on log storage security and query content sensitivity).
- **Recommendation:** Truncate the logged query to a maximum length (e.g., 500 characters) at INFO level; log the full query at DEBUG level.

#### RR-18: GIT_API_TOKEN Absent from Log Redaction List
- **Description:** `server.py` builds `_SECRET_TOKENS` from:
  ```python
  _SECRET_TOKENS = [
      t for t in [CLAUDE_API_TOKEN, DYNAMIC_AGENT_KEY, MCP_API_TOKEN, PLAN_API_TOKEN, TESTER_API_TOKEN]
      if t
  ]
  ```
  `GIT_API_TOKEN` is **not included**. However, `GIT_API_TOKEN` is present in the claude-server process environment (passed to the Claude Code subprocess via `**os.environ`). If the agent echoes the git token in its response text (e.g., via prompt injection or accidental inclusion in a commit message), `_redact_secrets()` will **not** redact it from `DEBUG`-level log output.
- **Impact:** Medium — GIT_API_TOKEN could appear unredacted in debug logs if `LOG_LEVEL=DEBUG`.
- **Recommendation:** Import `GIT_API_TOKEN` from `runenv` and add it to `_SECRET_TOKENS`.

---

## 5. Existing Mitigations

### Credential Isolation
- Token matrix enforced at startup: `verify_isolation.py` (claude-server), `proxy_wrapper.py` (proxy), `entrypoint.sh` scripts. Each container checks for forbidden env vars and refuses to start if violated.
- `ANTHROPIC_API_KEY` is never in `claude-server` at entrypoint time. Injected only into Claude Code subprocess scope as `DYNAMIC_AGENT_KEY`.

### Network Isolation
- `int_net` is `internal: true`. Only `caddy-sidecar` spans both networks.
- `proxy` is `int_net` only — no direct internet access since 2026-03-27.

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
- `verify_isolation.py` performs 26 checks for `claude-server`. All containers verify forbidden/required env vars.

### Prompt Immutability
- `/app/prompts/` and `/home/appuser/.claude/commands/` owned by `root:root`, mode `444`/`555`. UID 1000 agent cannot modify them.

### Non-root Containers
- All seven containers run as UID 1000 with `cap_drop: ALL`.

### Read-only Mounts
- `/workspace` mounted ro in `claude-server` and `tester-server`. `/docs` mounted ro in `claude-server`. Caddyfile and proxy config mounted ro.

### Plan and Tester Isolation
- `plan-server` has no `/workspace`, `/gitdir`, or secrets. `tester-server` has `/workspace:ro` only.

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
- All seven containers: `cap_drop: ALL`, `mem_limit`, `cpus`, `pids_limit`. `caddy-sidecar` and `proxy` additionally have `read_only: true`. `no-new-privileges` deferred (kernel 6.17.0-19 does not support it).

### Log Sanitization
- `server.py`: subprocess stdout/stderr at DEBUG level; `_redact_secrets()` redacts known token values with `[REDACTED]` before any log output. (Gap: `GIT_API_TOKEN` not currently included — see RR-18.)

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
Per-service tokens: `MCP_API_TOKEN`, `PLAN_API_TOKEN`, `TESTER_API_TOKEN`, `GIT_API_TOKEN`.

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
All seven containers now have `cap_drop: ALL`.

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
- **Severity:** Low
- **Likelihood:** Low
- **Description:** `server.py` passes `request.model` directly to `--model` flag. Shell injection is not possible (subprocess args are a list). However, an attacker with `CLAUDE_API_TOKEN` could specify arbitrary model names, potentially causing errors or unintended API usage.
- **Status: Fixed** — `ALLOWED_MODELS` frozenset (`claude-sonnet-4-6`, `claude-opus-4-6`, `claude-haiku-4-5-20251001`) defined in `server.py`. `_validate_model()` is called at the top of both `/ask` and `/plan` before any subprocess is spawned; unknown models are rejected with HTTP 400. Five unit tests cover reject/accept/empty/prefix-attack cases.

### RR-16: Unbounded Request Body Size on /ask and /plan *(NEW)*
- **Severity:** Medium
- **Likelihood:** Low (requires stolen CLAUDE_API_TOKEN)
- **Description:** `QueryRequest` has `query: str` and `model: str` with no length constraints. FastAPI has no default body size limit. A very large `query` (e.g., 100 MB) is:
  1. Held in memory by uvicorn
  2. Logged at INFO level in full
  3. Passed as a CLI argument to the `claude` subprocess (Linux `ARG_MAX` ≈ 2 MB)
  This could exhaust the `claude-server` 4 GB memory limit or trigger subprocess errors.
- **Recommendation:** Add `query: str = Field(max_length=100_000)` and `model: str = Field(max_length=200)` to `QueryRequest`. Optionally add a Caddy `request_body` size limit directive.

### RR-17: Query Content Logged at INFO Level Without Truncation *(NEW)*
- **Severity:** Low
- **Likelihood:** Medium (every invocation)
- **Description:** `server.py` lines 140 and 197 log the full query at `INFO` level unconditionally:
  ```python
  logger.info(f"Received authenticated query: {request.query} for model: {request.model}")
  ```
  Unlike subprocess stdout (moved to DEBUG in RR-11), the input query is always logged regardless of `LOG_LEVEL`. This means:
  - Large queries permanently consume log storage.
  - Any sensitive data accidentally included in a query is stored in logs.
  - An insider (TA-5) with log access sees the full content of every invocation.
- **Recommendation:** Truncate the logged query to 500 characters at INFO level; log the full query at DEBUG level:
  ```python
  logger.info(f"Received authenticated query ({len(request.query)} chars): {request.query[:500]!r}...")
  ```

### RR-18: GIT_API_TOKEN Absent from Log Redaction List *(NEW)*
- **Severity:** Medium
- **Likelihood:** Low (only manifests at DEBUG log level or if agent echoes token)
- **Description:** `server.py` builds `_SECRET_TOKENS` from `[CLAUDE_API_TOKEN, DYNAMIC_AGENT_KEY, MCP_API_TOKEN, PLAN_API_TOKEN, TESTER_API_TOKEN]`. `GIT_API_TOKEN` is **not included**, even though it is present in the claude-server process environment and is passed to the Claude Code subprocess via `**os.environ`. If the agent echoes the git token in its response text (e.g., via prompt injection), `_redact_secrets()` will not redact it from DEBUG-level log output.
- **Recommendation:** Import `GIT_API_TOKEN` from `runenv` and add it to `_SECRET_TOKENS`:
  ```python
  from runenv import CLAUDE_API_TOKEN, DYNAMIC_AGENT_KEY, ANTHROPIC_BASE_URL, \
      MCP_API_TOKEN, PLAN_API_TOKEN, TESTER_API_TOKEN, GIT_API_TOKEN, \
      SYSTEM_PROMPT, PLAN_SYSTEM_PROMPT
  
  _SECRET_TOKENS = [
      t for t in [CLAUDE_API_TOKEN, DYNAMIC_AGENT_KEY, MCP_API_TOKEN,
                  PLAN_API_TOKEN, TESTER_API_TOKEN, GIT_API_TOKEN]
      if t
  ]
  ```

---

## 7. STRIDE Summary Table

| Component | Spoofing | Tampering | Repudiation | Info Disclosure | DoS | Elevation of Privilege |
|-----------|----------|-----------|-------------|-----------------|-----|----------------------|
| **Caddy ingress** | Token theft (RR-8 no rate limit) | ~~tls_insecure_skip_verify~~ (RR-1 ✅) | No request audit log (RR-17) | Query content in logs (RR-17) | No rate limit (RR-8); large body (RR-16) | — |
| **claude-server** | — | Prompt injection via workspace (§4.2) | Query logged at INFO (RR-17) | GIT_API_TOKEN not redacted (RR-18); Env vars in subprocess scope | Unlimited concurrent subprocesses (RR-8); unbounded body (RR-16) | ~~Slash command path traversal (RR-7)~~ ✅ |
| **mcp-watchdog** | — | Bypassed by crafted tool responses | — | — | — | — |
| **files_mcp.py** | — | ~~URL param injection (RR-6)~~ ✅ | — | — | — | — |
| **mcp-server (Go)** | — | — | ~~File content fully logged (RR-5)~~ ✅ | ~~File content in logs (RR-5)~~ ✅ | ~~No resource limits (RR-3)~~ ✅ | cap_drop: ALL ✓ |
| **git-server** | — | Submodule path accepted without extra validation | — | Git history poisoning (§4.2) | — | — |
| **plan-server** | — | ~~Plan content injection (RR-14)~~ ✅ | — | — | — | cap_drop: ALL ✓ |
| **tester-server** | — | Test oracle manipulation (§4.2) | — | Test output injection (RR-13) | ~~No subprocess timeout (RR-2)~~ ✅; ~~no resource limits (RR-3)~~ ✅ | cap_drop: ALL ✓ |
| **proxy (LiteLLM)** | DYNAMIC_AGENT_KEY as master_key | ~~Model routing manipulation~~ (RR-15 fixed) | — | Real API key in memory (egress locked) | — | cap_drop: ALL ✓, read_only ✓, int_net only ✓ |
| **Host / Volumes** | — | .secrets.env readable by host users | — | plans/, .git, certs on host disk | — | TA-5 insider |

---

## 8. Observations: Where This System Exceeds Typical Deployment Security

1. **Structural, not filtered, filesystem jail** (`os.OpenRoot`) — traversal blocked by the kernel, not regex.
2. **3-layer git hook prevention** — tmpfs shadow + separated gitdir + `core.hooksPath=/dev/null` + `--no-verify`.
3. **Baseline commit floor** for `git_reset_soft` — agent cannot rewrite pre-session history.
4. **Prompt immutability via filesystem ownership** — root-owned system prompts, verified at startup.
5. **mcp-watchdog** intercepting all tool calls before they reach MCP servers.
6. **Plan-server structural isolation** — the planning tool cannot read workspace or commit files by design.
7. **Startup isolation checks with sys.exit(1)** — containers refuse to start if security invariants are violated.
8. **Constant-time token comparison** in all token verification paths.
9. **DYNAMIC_AGENT_KEY substitution** — the agent never holds the real Anthropic API key.
10. **MCP config as a build artifact** — the agent cannot modify which tools it has access to at runtime.
11. **Domain-locked egress filtering** — proxy on `int_net` only; all outbound traffic routes through a dedicated Caddy endpoint hardcoded to `api.anthropic.com:443` only.
12. **Read-only root filesystems** on internet-adjacent containers (caddy-sidecar, proxy).
13. **Per-service token scoping** — compromise of one token does not grant access to other backends.
14. **Plan field-length validation** — all text fields bounded; oversized payloads rejected at HTTP 400.

---

## 9. Recommended Mitigations (Priority Order)

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
| **P3** | **RR-18** | Add `GIT_API_TOKEN` to `_SECRET_TOKENS` in `server.py` | **Open** |
| **P3** | **RR-16** | Add `max_length` to `QueryRequest.query` and `QueryRequest.model`; add Caddy body size limit | **Open** |
| **P3** | **RR-8** | Add rate limiting or concurrency cap on `/ask`/`/plan` endpoints | **Open** |
| **P4** | **RR-17** | Truncate query logging to 500 chars at INFO level | **Open** |
| P4 | RR-13 | Document test output as trust boundary; add output length cap | Open |
| ~~P4~~ | ~~RR-15~~ | ~~Whitelist allowed model names in `/ask` and `/plan`~~ | ✅ Done 2026-03-30 |
| P4 | RR-10 | Add cert expiry monitoring; document rotation procedure | Open |
