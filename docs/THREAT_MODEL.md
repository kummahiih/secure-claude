# Threat Model: secure-claude

**Date:** 2026-04-19 (updated — reviewed post Go-client landing; confirmed open residuals RR-8, RR-10, RR-13, RR-17, RR-20, RR-21, RR-22, RR-23, RR-24, RR-25, RR-26, RR-27; added RR-28, RR-29)
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
| `CLAUDE_API_TOKEN` | High — gates external agent invocation | High | High | `claude-server` only; also host `.cluster_tokens.env` for CLI client |
| `CODEX_API_TOKEN` | High — gates external codex invocation | High | High | `codex-server` only; also host `.cluster_tokens.env` |
| `MCP_API_TOKEN` | High — mcp-server auth | High | High | `claude-server`, `codex-server`, `mcp-server` |
| `PLAN_API_TOKEN` | High — plan-server auth | High | High | `claude-server`, `codex-server`, `plan-server` |
| `TESTER_API_TOKEN` | High — tester-server auth | High | High | `claude-server`, `codex-server`, `tester-server` |
| `GIT_API_TOKEN` | High — git-server auth | High | High | `claude-server`, `codex-server`, `git-server` |
| `LOG_API_TOKEN` | Medium — grants read access to full session audit trail | High | Medium | `claude-server`, `codex-server`, `log-server` |
| TLS CA key (`ca.key`) | Critical — can sign arbitrary certs | Critical | Low (used only at build) | Host `cluster/certs/ca.key` (640 perms) |
| TLS leaf certs/keys | High — MITM if stolen | High | Medium | Per-container `/app/certs/` |
| `/workspace` source code | Medium | Critical — agent commits changes | High | Host bind mount → `mcp-server` (rw), others (ro) |
| Git history (`.git`) | Medium | Critical — commits are permanent | High | Host `workspace/.git` → `/gitdir` in `git-server` |
| Plan state (`/plans`) | Low | High — directs agent work | High | Host `plans/` → `plan-server` |
| Session logs (`/logs`) | Medium — tool calls, file paths, token counts, timing | High — audit trail integrity | Medium | Host `logs/` → `log-server` (rw) |
| Test output | Low | High — misleading output could cause bad commits | Medium | In-memory, `tester-server` |
| System prompts (`/app/prompts/`) | High | Critical | Medium | Baked into agent images, root-owned |
| Slash commands (`~/.claude/commands/`, `~/.codex/commands/`) | Medium | High | Medium | Baked into agent images, root-owned |
| Host `.cluster_tokens.env` (new) | High — grants `/ask`/`/plan` invocation | High | Medium | Parent repo working dir; read by Go client |
| Container environment variables | High | High | — | Runtime process memory |
| Docker socket | Critical — host escape if accessible | Critical | — | Must NOT be accessible |

---

## 2. Trust Boundaries

```
[External Network / Host CLI user]
       │  HTTPS/TLS 1.3, Bearer CLAUDE_API_TOKEN or CODEX_API_TOKEN
       │  ─── Go client (cluster/client/cmd/{ask,plan}) reads
       │      .cluster_tokens.env + ./cluster/certs/ca.crt from host
       ▼
[caddy-sidecar :8443]  ← only container on ext_net + int_net
  │    │  HTTPS, internal CA, no auth header added by Caddy
  │    ▼
  │  [claude-server :8000]  ← int_net only
  │  [codex-server :8000]   ← int_net only (parallel agent)
  │    │  subprocess env[ANTHROPIC_API_KEY]=DYNAMIC_AGENT_KEY (claude)
  │    │  subprocess env[OPENAI_API_KEY]=DYNAMIC_AGENT_KEY    (codex)
  │    ├──────────────────────────────────────────────────────►[proxy :4000]
  │    │                                                        (int_net only)
  │    │  stdio JSON-RPC  ┌──────────────────────────┐          │
  │    ├──────────────────► mcp-watchdog (in-process) │          │
  │    │                  └──────────┬───────────────┘          │
  │    │                             │ blocks 40+ attack classes│
  │    │                  ┌──────────▼───────────────┐          │
  │    │  HTTPS REST over │ files_mcp.py → mcp-server:8443      │
  │    │  internal CA     │ plan_mcp.py  → plan-server:8443     │
  │    │                  │ tester_mcp.py→ tester-server:8443   │
  │    │                  │ git_mcp.py   → git-server:8443      │
  │    │                  │ docs_mcp.py  → /docs read-only      │
  │    │                  │ log_mcp.py   → log-server:8443      │
  │    │                  └──────────────────────────┘          │
  │    │                                                        │
  │  [caddy-sidecar :8081]  ◄──────────────────────────────────┘
  │    │  Egress proxy — hardcoded upstream: api.anthropic.com:443 only
  │    ▼
  [Anthropic API / OpenAI API (via proxy routing)]

[mcp-server :8443]     os.OpenRoot jail at /workspace
[plan-server :8443]    /plans only
[tester-server :8443]  /workspace:ro
[git-server :8443]     /gitdir:rw, /workspace:ro
[log-server :8443]     /logs:rw

[Host ↔ Container]
  - Docker volume mounts only (no Docker socket)
  - No privileged containers; UID 1000 everywhere
```

### Key Boundary Properties

| Boundary | Enforcement Mechanism |
|----------|----------------------|
| Internet → Caddy | TLS 1.3 + bearer token (CLAUDE_API_TOKEN / CODEX_API_TOKEN), constant-time compare |
| Caddy → {claude,codex}-server | Internal CA verification; Caddy trusts `ca.crt` only |
| Agent servers → each backend | Per-service bearer token over TLS 1.3, internal CA |
| MCP stdio → Go/REST backends | mcp-watchdog intercepts all JSON-RPC before forwarding |
| Agent subprocess → filesystem | `/workspace` is ro in agent containers; writes only via mcp-server's os.OpenRoot jail |
| Agents → Anthropic/OpenAI | DYNAMIC_AGENT_KEY only; routed via proxy (int_net only) → caddy-sidecar:8081 → api.anthropic.com |
| proxy → Internet | No direct access — int_net only; egress exclusively via caddy-sidecar:8081 |
| Host → container | UID 1000, no Docker socket, `cap_drop: ALL` on all containers |
| plan-server ↔ workspace/git | Structurally separated — no `/workspace` or `/gitdir` mount |
| log-server ↔ workspace/git/plans | Structurally separated — no workspace/git/plans mounts |
| Host CLI ↔ Cluster (new) | Go client loads `.cluster_tokens.env` + `ca.crt` from host disk; no additional auth factor |

---

## 3. Threat Actors

### TA-1: Malicious External Caller
Network access to Caddy `:8443`. Does not hold `CLAUDE_API_TOKEN` or `CODEX_API_TOKEN`. Goal: invoke agent without auth, extract secrets, DoS.

### TA-2: Compromised LLM Output
Claude Code or Codex CLI produces adversarial tool calls — due to jailbreak, model regression, or upstream supply-chain issue. Has full access to all MCP tool surfaces.

### TA-3: Prompt Injection via Workspace Content
Malicious content in files the agent reads (`/workspace`, `/docs`, git history, plan files, test output). Attempts to override system prompt by embedding instructions in data.

### TA-4: Compromised Dependency
Malicious version of pip/npm/Go package (e.g., `mcp`, `litellm`, `claude-code`, `codex`, `mcp-watchdog`) is installed and executes arbitrary code in-container. Has the permissions of the container's appuser.

### TA-5: Insider with Host Access
Can read `.secrets.env`, `.cluster_tokens.env`, Docker volumes, container logs. May also modify `docker-compose.yml` or Dockerfiles before a rebuild.

### TA-6: Malicious Process on the Operator Host (new)
Non-privileged process sharing the operator account can read `.cluster_tokens.env` or the Go client binary's memory/argv, stealing `CLAUDE_API_TOKEN`/`CODEX_API_TOKEN` and invoking the cluster as a legitimate user.

---

## 4. Attack Vectors

### 4.1 Infrastructure Attacks

#### Container Escape
- **Attack:** Exploit kernel vulnerability, Docker breakout via mounted socket, or privileged container.
- **Prerequisites:** No Docker socket is mounted. No `--privileged`. UID 1000. `cap_drop: ALL`.
- **Impact:** Host compromise; access to `.secrets.env` and real API keys.
- **Residual risk:** Low.

#### Network Segmentation Bypass
- **Attack:** Compromise `caddy-sidecar` (spans `ext_net` + `int_net`) to pivot to internal services.
- **Prerequisites:** RCE in Caddy or its config. Config mounted read-only. Caddy runs non-root with `cap_drop: ALL`, `read_only: true`, `pids_limit: 100`.
- **Impact:** Direct access to backends at HTTPS layer; still requires per-service token.

#### Volume Mount Traversal
- **Attack:** Abuse git gitdir mount (`./workspace/.git:/gitdir`) — if `workspace` is a symlink to a sensitive directory, `/gitdir` could expose unexpected content.
- **Prerequisites:** Attacker can influence symlink (host access).

#### Environment Variable Leakage
- **Attack:** `server.py` uses `env={**os.environ, ...}` when spawning agent CLI, passing all parent env vars (incl. all service tokens) into subprocess.
- **Impact:** An adversarial MCP server injected via prompt injection could read these env vars; CLI may echo them.
- **Note:** By design (MCP stdio wrappers need the tokens) — blast radius is all service tokens simultaneously in the subprocess environment.

#### TLS Downgrade / MITM on Internal Network
- **Egress path (RESOLVED 2026-03-27):** Replaced with a dedicated `:8081` listener using proper public TLS to `api.anthropic.com:443`. Proxy is now `int_net` only.
- **Internal:** All Go servers require TLS 1.3 (RR-12 resolved).

---

### 4.2 LLM-Specific Attacks

#### Prompt Injection via Workspace Files
- **Attack:** A file in `/workspace` contains injected instructions; agent reads via `read_workspace_file` or `grep_files` and acts on content.
- **Impact:** Agent performs unintended actions — exfiltrates tokens by writing them to workspace files, deletes code, or marks tasks complete without completing them.
- **Note:** `mcp-watchdog` blocks tool *calls*, not *return values*.

#### Tool Poisoning via MCP Response Manipulation
- **Attack:** Adversary modifies HTTPS traffic between MCP wrappers and backends, crafting responses that trigger unintended agent actions.
- **Prerequisites:** Network position or compromised `mcp-watchdog`/`requests` library.

#### Plan Manipulation
- **Attack:** Agent (via prompt injection) calls `plan_create` with adversarial task definitions directing future sessions to exfiltrate secrets, install backdoors, or alter source code.
- **Note:** Plan field lengths validated (RR-14 resolved); semantic content not checked.

#### Indirect Prompt Injection via Docs
- **Attack:** `docs_mcp.py` reads files in `/docs`. If agent is tricked into writing malicious content to `docs/CONTEXT.md` via `mcp-server`, injected instructions are re-ingested as documentation context.
- **Impact:** Persistent system-level injection surviving across sessions.

#### Git History Poisoning
- **Attack:** Prior commits contain prompt-injection payloads. When agent runs `git_log` or reads changed files, it ingests adversarial instructions.
- **Impact:** Durable, hard-to-detect injection surviving file deletions.

#### Test Oracle Manipulation
- **Attack:** A workspace test fixture produces output that misleads the agent — e.g., a test that always prints "All tests passed" regardless of outcome.
- **Impact:** Agent commits broken or backdoored code believing tests pass.

#### Token Exfiltration via Tool Calls
- **Attack:** Agent (via prompt injection) calls `grep_files` targeting secret markers and writes results to a file or embeds them in a commit message.
- **Specific risk:** All service tokens reside in `os.environ` of the CLI subprocess via `env={**os.environ, ...}`.
- **Exfiltration channel:** Agent writes to `/workspace` via `write_file`; committed to git history and accessible from host mount. Network exfiltration blocked — egress locked to `api.anthropic.com`. Covert-channel encoding in API request bodies remains a theoretical risk.

#### File Duplication Abuse via copy_file
- **Attack:** Agent uses `copy_file` with `overwrite=true` to duplicate sensitive files or overwrite critical ones (e.g., `test.sh`).
- **Impact:** Medium — same blast radius as `write_file` (os.OpenRoot jail). No expansion of attack surface; may evade content-based watchdog rules since payload is already on disk.
- **Mitigation:** os.OpenRoot jail prevents escape. mcp-watchdog intercepts the tool call.

#### Log Exfiltration via log_mcp Tools
- **Attack:** Agent (via prompt injection) calls `list_sessions` and `query_logs`, harvesting session metadata (tool calls, file paths, timing) and embedding it in workspace files or commit messages.
- **Note:** Log content does not include file bodies but file paths and tool call names are present and may be sensitive.

#### Recursive Self-Modification
- `/app/` inside agent containers cannot be reached by `mcp-server` (different containers). Agent can modify `docs/CONTEXT.md`, `docs/PLAN.md`, and workspace source — shaping its own future context.

---

### 4.3 Authentication and Authorization Attacks

#### Token Replay / Theft
- **Attack:** Intercept `CLAUDE_API_TOKEN` / `CODEX_API_TOKEN` from `query.sh`/`plan.sh` invocation (process list, network sniff, shell history, `.cluster_tokens.env` on host) and replay requests.
- **Mitigation:** 64-char random hex tokens regenerated on every `run.sh`; Bearer over TLS 1.3.
- **Gap:** No per-session or per-request nonce; stolen token valid until next `run.sh`. No rate limiting (RR-8).

#### Privilege Escalation Between Token Scopes
- **Status:** Each backend has its own token (RR-4 resolved). `claude-server` and `codex-server` still hold all service tokens simultaneously — agent-container compromise exposes all tokens at once, but blast radius per token is bounded to one backend.

#### Bypass of Token Validation
- All token comparisons use `secrets.compare_digest` (Python) or `subtle.ConstantTimeCompare` (Go). Services call `log.Fatal` on empty token at startup. No bypass identified.

#### Unauthenticated `/health` Endpoint (RR-22)
- **Attack:** `/health` has no auth. External caller can probe liveness; combined with RR-8 enables availability probing.

#### docs_mcp.py Path Traversal via Prefix Matching (RR-23)
- **Attack:** `_safe_path()` uses `resolved.startswith(os.path.realpath(DOCS_DIR))` without `os.sep`. A sibling directory sharing the `/docs` prefix would pass.
- **Impact:** Medium — latent flaw activated by mount layout changes.
- **Recommendation:** Append `os.sep` to the base path or check equality.

#### Unredacted stderr in HTTP Error Responses (RR-24)
- **Attack:** Both agent servers return raw `result.stderr` in HTTP error responses without `_redact_secrets()` or truncation (see `server.py:367-369, 386-388, 466-468`).
- **Impact:** Medium — information disclosure of internal paths, dependency versions, potential token fragments.
- **Recommendation:** Apply `_redact_secrets()` and 4 KB cap before returning.

#### Race Condition in tester_mcp.py Global State (RR-25)
- **Attack:** Unprotected globals for 3-strike hard-stop. Concurrent async calls could race on these globals.
- **Recommendation:** Protect with `asyncio.Lock`.

#### Generic Exception Info Disclosure (RR-26)
- **Attack:** Both `claude-server` and `codex-server` catch broad `Exception` and return `str(e)` in HTTP responses.
- **Recommendation:** Return generic message; log exception server-side.

#### Incomplete codex-server Isolation Checks (RR-27)
- **Attack:** `verify_isolation.py` does not fully enforce env-var rules for `codex-server`:
  - `PLAN_API_TOKEN` and `LOG_API_TOKEN` are used by codex-server but not listed in `REQUIRED_ENV_VARS["codex-server"]`.
  - `TESTER_API_TOKEN` and `GIT_API_TOKEN` are injected via docker-compose but not used by codex-server's `server.py`, and are not listed in `FORBIDDEN_ENV_VARS["codex-server"]`.
- **Impact:** Medium — violates least-privilege; misconfiguration yields silent runtime failure instead of startup failure.

#### Host Token File Exposure (RR-28 — New)
- **Attack:** `cluster/client/cmd/ask/main.go` and `cluster/client/cmd/plan/main.go` read `.cluster_tokens.env` from the CWD (default path) with no permission check. File is generated by `run.sh` and, if created with default umask, readable by any local user.
- **Prerequisites:** TA-6 (malicious local process or secondary account on the operator host).
- **Impact:** Medium — token theft grants full `/ask`/`/plan` access until next `run.sh`. No nonce/rotation.
- **Recommendation:** `chmod 600 .cluster_tokens.env` on creation in `run.sh`; have the Go client `os.Stat` the file and refuse if mode bits beyond `0600` are set or the owner differs from the current UID. Consider loading tokens from a user-keyring or `gpg`-encrypted store.

#### Unrestricted CA Trust in Go Client (RR-29 — New)
- **Attack:** `client.PostJSON` calls `x509.SystemCertPool()` then `pool.AppendCertsFromPEM(caBytes)`. The CA pool trusted by the client is (system CAs) ∪ (internal CA). A compromised public CA could impersonate `localhost:8443`; internal CA pinning is not enforced.
- **Prerequisites:** Attacker with access to a trusted public CA, or a malicious CA installed in the host system trust store.
- **Impact:** Low — traffic targets `https://localhost:8443`, reducing real-world exploitability; still a deviation from the strict internal-CA-only boundary enforced inside the cluster.
- **Recommendation:** Use a fresh `x509.NewCertPool()` seeded only with `cluster/certs/ca.crt` for internal HTTPS calls; do not merge system CAs.

---

### 4.4 Data Retention and Audit

#### RR-20: Session Log Data Retention — No Rotation or TTL Policy
- JSONL log files in `/logs` accumulate indefinitely. Host compromise exposes all historical metadata.
- **Recommendation:** `LOG_RETENTION_DAYS` env var + disk quota on `./logs`.

#### RR-21: Silent Log Drops — Incomplete Audit Trail
- `_emit_log_event()` uses fire-and-forget daemon threads; log-server unavailability causes silent drops.
- **Recommendation:** Document git commit history as primary audit trail; surface dropped-event counter.

---

## 5. Existing Mitigations

### Credential Isolation
- Token matrix enforced at startup across `verify_isolation.py`, `proxy_wrapper.py`, container `entrypoint.sh` scripts.
- `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` never in agent containers at entrypoint time; `DYNAMIC_AGENT_KEY` substituted at subprocess spawn.

### Network Isolation
- `int_net` is `internal: true`; only `caddy-sidecar` spans both networks.
- `proxy` on `int_net` only since 2026-03-27 — no direct internet.
- `log-server` on `int_net` only.

### Filesystem Jail (Go os.OpenRoot)
- `mcp-server/main.go` calls `os.OpenRoot("/workspace")`. All file ops (incl. `copy_file`, `diff_files`) go through this root. Kernel-level enforcement.

### Git Hook Prevention (3-layer)
1. tmpfs `/workspace/.git` (ro, size=0) in `mcp-server`.
2. Separated gitdir: `GIT_DIR=/gitdir`, `GIT_WORK_TREE=/workspace`.
3. `-c core.hooksPath=/dev/null` on every invocation. `git_commit` passes `--no-verify`.

### Baseline Commit Floor
- `entrypoint.sh` captures `HEAD` at startup. `git_reset_soft` enforces this as a floor. Per-submodule baselines captured.

### mcp-watchdog
- All MCP stdio servers wrapped: `"command": "mcp-watchdog"` intercepts JSON-RPC, blocking 40+ attack classes.

### Startup Isolation Checks
- `verify_isolation.py` runs for all container roles, failing hard on any violation.

### Prompt Immutability
- `/app/prompts/` and command directories owned by `root:root`, mode `444`/`555`. UID 1000 cannot modify.

### Non-root Containers
- All nine containers run as UID 1000 with `cap_drop: ALL`.

### Read-only Mounts
- `/workspace` ro in agent and tester containers. `/docs` ro in agent containers. Caddyfile and proxy config ro.

### Plan/Tester/Log Structural Isolation
- `plan-server` has no `/workspace`, `/gitdir`, or secrets.
- `tester-server` has `/workspace:ro` only.
- `log-server` has no `/workspace`, `/gitdir`, `/plans`, or other service tokens.

### TLS Everywhere (Internal)
- Fresh internal CA every `run.sh`. All internal traffic HTTPS with `TLSConfig.MinVersion = tls.VersionTLS13`.

### MCP Config as Build Artifact
- `.mcp.json` baked into agent images; not runtime-configurable.

### Constant-time Token Comparison
- `secrets.compare_digest` / `subtle.ConstantTimeCompare` throughout.

### Egress Filtering
- Proxy on `int_net` only; all API calls via `caddy-sidecar:8081`, hardcoded to `api.anthropic.com:443` with public TLS.

### Container Hardening
- All nine containers have `cap_drop: ALL`, `mem_limit`, `cpus`, `pids_limit`. `caddy-sidecar` and `proxy` additionally `read_only: true`.

### Log Sanitization
- `_redact_secrets()` replaces token values with `[REDACTED]` in agent stdout/stderr DEBUG logs.

### Model Allowlists
- claude-server: `claude-sonnet-4-6`, `claude-opus-4-6`, `claude-opus-4-7`, `claude-haiku-4-5-20251001`.
- codex-server: `gpt-4o`, `gpt-5.3-codex`, `o3`.

### Concurrency Control
- Both agent servers semaphore-cap to 1 concurrent `/ask` or `/plan`.

### New MCP Tools Security
- `copy_file`: requires `overwrite=true` to replace existing files (409 otherwise); source must exist (404). All paths under os.OpenRoot.
- `diff_files`: read-only; both paths under os.OpenRoot.

### Go Client CLI (2026-04-15)
- `client.PostJSON` pins TLS 1.3 minimum, uses internal CA, 10-minute total timeout, Bearer token over HTTPS.
- Go binaries under `cluster/client/cmd/{ask,plan}` are covered by `cluster/client` unit tests (`*_test.go`).

---

## 6. Residual Risks

### ~~RR-1..RR-7, RR-9, RR-11, RR-12, RR-14..RR-16, RR-18, RR-19~~ — RESOLVED
See `docs/HARDENING.md` and section 10 below for resolution dates.

### RR-8: No Rate Limiting on /ask and /plan Endpoints
- **Severity:** Medium · **Likelihood:** Low (requires stolen token)
- No rate limit at Caddy or FastAPI. Semaphore caps concurrency to 1 per agent — partial mitigation only.
- **Recommendation:** Caddy rate-limit directive or per-token counter.

### RR-10: Cert Validity 365 Days, No Rotation
- **Severity:** Low
- All service certs valid 365 days, no automated rotation. Expired certs silently break internal TLS.
- **Recommendation:** Expiry monitoring; consider 90-day cert lifetimes.

### RR-13: Test Output Not Sanitised Before Presenting to Agent
- **Severity:** Medium
- `tester/main.go` returns full `cmd.CombinedOutput()` as `output`. Prompt injection in test output reaches agent context.
- **Recommendation:** 64 KB cap; document as trust boundary.

### RR-17: Query Content Logged at INFO Without Truncation
- **Severity:** Low · **Likelihood:** every invocation
- **Recommendation:** Truncate to 500 chars at INFO; full query at DEBUG.

### RR-20: Session Log Data Retention — No Rotation/TTL
- **Severity:** Medium · **Likelihood:** Certain
- **Recommendation:** `LOG_RETENTION_DAYS`; disk quota on `./logs`.

### RR-21: Silent Log Drops — Incomplete Audit Trail
- **Severity:** Low
- **Recommendation:** Document git history as primary audit; expose dropped-event counter.

### RR-22: Unauthenticated /health Endpoint
- **Severity:** Low
- **Recommendation:** Block at Caddy or document as accepted risk.

### RR-23: docs_mcp.py Path Traversal via startswith()
- **Severity:** Medium · **Likelihood:** Low (no sibling dirs today)
- **Recommendation:** Append `os.sep` to base path; add unit test.

### RR-24: Unredacted stderr in HTTP Error Responses
- **Severity:** Medium · **Likelihood:** Medium (every subprocess failure)
- Code sites: `cluster/agent/claude/server.py:369, 388, 468`; `cluster/agent/codex/server.py:300, 316, …`.
- **Recommendation:** Apply `_redact_secrets()` + 4 KB cap before returning.

### RR-25: Race Condition in tester_mcp.py Global State
- **Severity:** Low · **Likelihood:** Low
- **Recommendation:** Protect with `asyncio.Lock`.

### RR-26: Generic Exception `str(e)` in HTTP Responses
- **Severity:** Low
- **Recommendation:** Generic message; log server-side.

### RR-27: Incomplete codex-server Isolation Checks
- **Severity:** Medium · **Likelihood:** Medium
- `PLAN_API_TOKEN`, `LOG_API_TOKEN` missing from `REQUIRED_ENV_VARS["codex-server"]`; `TESTER_API_TOKEN`, `GIT_API_TOKEN` injected but not used nor forbidden.
- **Recommendation:**
  1. Add `PLAN_API_TOKEN`, `LOG_API_TOKEN` to `REQUIRED_ENV_VARS["codex-server"]`.
  2. Either add `TESTER_API_TOKEN`, `GIT_API_TOKEN` to `REQUIRED_ENV_VARS` if the MCP wrappers need them, or remove from docker-compose and add to `FORBIDDEN_ENV_VARS`.
  3. Add regression tests in `test_isolation.py`.

### RR-28: Host Token File Exposure (new 2026-04-19)
- **Severity:** Medium · **Likelihood:** Low (requires non-privileged local access)
- `cluster/client/cmd/ask/main.go` and `cmd/plan/main.go` load `.cluster_tokens.env` from the parent repo CWD without permission checks.
- **Recommendation:**
  1. Enforce `chmod 600 .cluster_tokens.env` in `run.sh` after write.
  2. In `client.LoadTokens`, `os.Stat` the file and refuse if mode ≠ `0600` or owner UID ≠ current UID.
  3. Optional: load via user keyring / gpg-encrypted store.

### RR-29: Unrestricted CA Trust in Go Client (new 2026-04-19)
- **Severity:** Low · **Likelihood:** Low
- `client.PostJSON` merges system CAs with the internal CA. A compromised public CA could impersonate `localhost:8443`.
- **Recommendation:** Use a fresh `x509.NewCertPool()` with only `cluster/certs/ca.crt` for in-cluster calls.

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
| PLAN_API_TOKEN | ✓ required | ⚠️ used, not required | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| TESTER_API_TOKEN | ✓ required | ⚠️ injected, unused | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| GIT_API_TOKEN | ✓ required | ⚠️ injected, unused | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden |
| LOG_API_TOKEN | ✓ required | ⚠️ used, not required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden |

> **⚠️:** Anomalies captured as RR-27. The token is present in the codex-server environment but not properly reflected in its isolation-check profile.

---

## 8. STRIDE Summary Table

| Component | Spoofing | Tampering | Repudiation | Info Disclosure | DoS | Elevation of Privilege |
|-----------|----------|-----------|-------------|-----------------|-----|----------------------|
| **Caddy ingress** | Token theft (RR-8, RR-28); unauthenticated /health (RR-22) | ✅ (RR-1) | No request audit log | Query content (RR-17) | No rate limit (RR-8) | — |
| **Host CLI / Go client** | Local token theft (RR-28); weak CA pinning (RR-29) | — | CLI invocations not logged server-side pre-auth | `.cluster_tokens.env` on disk | — | — |
| **claude-server** | — | Prompt injection via workspace (§4.2) | Query logged at INFO (RR-17) | Unredacted stderr (RR-24); exception info (RR-26); env vars in subprocess | Semaphore cap = 1 mitigates (RR-8) | ✅ (RR-7) |
| **codex-server** | — | Prompt injection (§4.2) | Query at INFO (RR-17) | Unredacted stderr (RR-24); `str(e)` (RR-26); unnecessary tokens in env (RR-27) | Semaphore cap = 1 | Incomplete isolation checks (RR-27) |
| **docs_mcp.py** | — | — | — | startswith() prefix escape (RR-23) | — | — |
| **mcp-watchdog** | — | Bypassed by crafted tool *responses* | — | — | — | — |
| **files_mcp.py** | — | ✅ (RR-6) | — | — | — | — |
| **mcp-server (Go)** | — | copy_file overwrite bounded by os.OpenRoot | ✅ (RR-5) | — | — | cap_drop: ALL ✓ |
| **git-server** | — | Submodule path accepted w/o extra validation | — | Git history poisoning (§4.2) | — | — |
| **plan-server** | — | ✅ (RR-14) | — | — | — | cap_drop: ALL ✓ |
| **tester-server** | — | Test oracle manipulation (§4.2) | — | Test output injection (RR-13) | ✅ (RR-2) | cap_drop: ALL ✓ |
| **tester_mcp.py** | — | 3-strike race (RR-25) | — | — | — | — |
| **log-server** | LOG_API_TOKEN theft | Host-level log tampering | Silent drops (RR-21) | Session metadata exfiltration (§4.2) | Log accumulation (RR-20) | cap_drop: ALL ✓ |
| **proxy (LiteLLM)** | DYNAMIC_AGENT_KEY as master_key | ✅ (RR-15) | — | Real API keys in memory (egress locked) | — | cap_drop: ALL ✓, read_only ✓, int_net only ✓ |
| **Host / Volumes** | — | `.secrets.env` / `.cluster_tokens.env` on disk | — | plans/, .git, logs/, certs on host | — | TA-5 insider / TA-6 local process |

---

## 9. Observations: Where This System Exceeds Typical Deployment Security

1. **Structural filesystem jail** (`os.OpenRoot`) — traversal blocked by kernel, not regex.
2. **3-layer git hook prevention** — tmpfs shadow + separated gitdir + `core.hooksPath=/dev/null` + `--no-verify`.
3. **Baseline commit floor** — agent cannot rewrite pre-session history.
4. **Prompt immutability** via root ownership and startup verification.
5. **mcp-watchdog** on every JSON-RPC call.
6. **Plan-server structural isolation** — planning tool cannot read workspace or commit files.
7. **Log-server structural isolation** — metadata-only, no workspace/git/plans access.
8. **Startup isolation checks** with `sys.exit(1)` on any violation.
9. **Constant-time token comparison** throughout.
10. **DYNAMIC_AGENT_KEY substitution** — agent never holds real API keys.
11. **MCP config as build artifact** — not runtime-configurable.
12. **Domain-locked egress** — `api.anthropic.com:443` only.
13. **Read-only root filesystems** on internet-adjacent containers.
14. **Per-service token scoping** — 8 distinct tokens; compromise of one bounds blast radius.
15. **Plan field-length validation** — bounded text fields.
16. **Dual model allowlists** — Claude and OpenAI each constrained.
17. **Concurrency semaphore** — 1 concurrent request per agent server.
18. **Go client** pins TLS 1.3 and internal CA (modulo RR-29) instead of relying on `curl` flags.

---

## 10. Prioritised Mitigation Plan

Priority key: **Critical** (immediate action, high impact × high exploitability), **High** (remediate within one release cycle), **Medium** (plan/schedule), **Low** (defer or accept).

### Critical
*(None open.)* The previously-critical items (RR-1 egress TLS skip, RR-4 shared MCP token, RR-2 missing tester timeout) have been resolved.

### High
- [ ] **RR-24** — Apply `_redact_secrets()` and a 4 KB cap to all `result.stderr` values returned in HTTP error paths of `claude-server` and `codex-server`. _(Info disclosure, every failure.)_
- [ ] **RR-27** — Complete codex-server isolation rules in `cluster/agent/isolation/verify_isolation.py`:
  1. Add `PLAN_API_TOKEN`, `LOG_API_TOKEN` to `REQUIRED_ENV_VARS["codex-server"]`.
  2. Decide `TESTER_API_TOKEN` / `GIT_API_TOKEN` fate — required or forbidden, not both.
  3. Add regression tests in `cluster/agent/isolation/test_isolation.py`.
- [ ] **RR-28** — Protect `.cluster_tokens.env` on the host:
  1. `chmod 600` immediately after creation in `run.sh`.
  2. Reject the file in `client.LoadTokens` if mode ≠ `0600` or owner differs from current UID.

### Medium
- [ ] **RR-8** — Add a Caddy `rate_limit` directive (per-token bucket) in front of `/ask` and `/plan`.
- [ ] **RR-13** — Cap `cmd.CombinedOutput()` to 64 KB in `tester/main.go`; document test output as a trust boundary.
- [ ] **RR-20** — Implement log retention: `LOG_RETENTION_DAYS` env var in log-server + disk quota on `./logs` volume.
- [ ] **RR-23** — Fix `docs_mcp.py` `_safe_path()` by appending `os.sep` or using equality check; add a unit test that exercises the sibling-dir case.

### Low
- [ ] **RR-10** — Cert expiry monitoring; plan rotation (aim for 90-day certs).
- [ ] **RR-17** — Truncate `/ask` and `/plan` query bodies to 500 chars at INFO; log full query at DEBUG.
- [ ] **RR-21** — Document git history as primary audit trail; expose a counter for dropped log events.
- [ ] **RR-22** — Block `/health` at Caddy for external callers, or document as an accepted convention.
- [ ] **RR-25** — Guard `tester_mcp.py` 3-strike globals with `asyncio.Lock`.
- [ ] **RR-26** — Return generic error messages in HTTP responses; keep full exception text in server-side logs.
- [ ] **RR-29** — Replace `x509.SystemCertPool()` with a pool seeded only from `cluster/certs/ca.crt` in `cluster/client/client.go::PostJSON`.

### Resolved (for reference)
| Priority (was) | ID | Resolution |
|----------------|----|------------|
| P1 | RR-1 | Dedicated egress listener w/ public TLS (2026-03-27) |
| P1 | RR-2 | `context.WithTimeout` on tester (2026-03-27) |
| P2 | RR-3 | Resource limits on all containers (2026-03-28) |
| P2 | RR-4 | Per-service tokens (2026-03-28) |
| P2 | RR-5 | File content removed from mcp-server logs (2026-03-28) |
| P2 | RR-11 | Subprocess output redacted, DEBUG-level (2026-03-28) |
| P3 | RR-6 | `params=` kwarg in `files_mcp.py` (2026-03-28) |
| P3 | RR-7 | Slash-command path traversal hardening (2026-03-29) |
| P3 | RR-9 | `cap_drop: ALL` on all containers (2026-03-28) |
| P3 | RR-12 | TLS 1.3 min on all Go servers (2026-03-29) |
| P3 | RR-14 | Plan field-length validation (2026-03-30) |
| P3 | RR-15 | Model allowlists (2026-03-30) |
| P3 | RR-16 | Request body size limits (2026-03-30) |
| P3 | RR-18 | `GIT_API_TOKEN` + `LOG_API_TOKEN` in `_SECRET_TOKENS` (2026-03-30) |
| P4 | RR-19 | `LOG_API_TOKEN` in proxy/caddy FORBIDDEN lists (2026-04-04) |
