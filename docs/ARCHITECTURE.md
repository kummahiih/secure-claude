# secure-claude: Architecture Documentation

## Overview

**secure-claude** is a hardened, containerized environment for running Claude Code as an autonomous AI coding agent. The system enables a *plan-then-execute* agentic loop where Claude Code can read, modify, test, and commit source code without holding real API credentials or having direct internet access. Security is enforced structurally — through container isolation, network segmentation, per-service token scoping, and filesystem jails — rather than by filtering.

> **Note:** This file (`ARCHITECTURE.md`) is the combined architecture reference. The system prompt (`ask.md`) references split files `ARCHITECTURE_OVERVIEW.md` and `ARCHITECTURE_DETAIL.md` for token efficiency. Those files should be generated via `/architecture-doc` when needed. Until then, this document is the authoritative source.

---

## System Components

### 1. caddy-sidecar
- **Role:** TLS termination, external ingress, and egress proxy.
- **Ports:** `:8443` (external ingress from host) and `:8081` (internal egress to `api.anthropic.com` only).
- **Networks:** `int_net` (internal) + `ext_net` (external, for host binding and Anthropic egress).
- **Technology:** Caddy 2 (Alpine), file capabilities stripped (`setcap -r`), `cap_drop: ALL`, `read_only: true`.
- **Key constraint:** The `:8081` listener is hardcoded to forward exclusively to `api.anthropic.com:443`, preventing exfiltration to arbitrary domains.

### 2. claude-server
- **Role:** Main application server. Spawns Claude Code CLI as a subprocess and manages six MCP stdio server processes.
- **Port:** `:8000` (internal only, behind Caddy).
- **Networks:** `int_net` only.
- **Technology:** Python / FastAPI, Claude Code CLI subprocess (`@2.1.74`), Node.js runtime.
- **Endpoints:**
  - `POST /ask` — executes code changes following the active plan (system prompt: `ask.md`).
  - `POST /plan` — creates plans only, no code execution (system prompt: `plan.md`).
- **MCP stdio servers** (each is a Python subprocess inside claude-server):

  | Wrapper | Backend | Tools |
  |:---|:---|:---|
  | `files_mcp.py` | mcp-server:8443 | read/write/list/grep/delete workspace files |
  | `git_mcp.py` | git-server:8443 | git status/diff/add/commit/log/reset |
  | `docs_mcp.py` | `/docs` (local ro mount) | list_docs, read_doc |
  | `plan_mcp.py` | plan-server:8443 | plan CRUD + current task lifecycle |
  | `tester_mcp.py` | tester-server:8443 | run_tests, get_test_results |
  | `log_mcp.py` | log-server:8443 | session log queries and token breakdowns |

- **Security:** `verify_isolation.py` (26 checks at startup), `_redact_secrets()` on all log output, model allowlist (`ALLOWED_MODELS`: `claude-sonnet-4-6`, `claude-opus-4-6`, `claude-haiku-4-5-20251001`), request body size limits (`max_length=100_000` on query, `max_length=200` on model), slash-command name hardening (`os.path.basename` + `PATH_BLACKLIST`).
- **mcp-watchdog:** Intercepts all MCP JSON-RPC between Claude Code and MCP wrappers, blocking 40+ attack classes before they reach backend servers.

### 3. proxy (LiteLLM)
- **Role:** LLM API gateway. Holds the real `ANTHROPIC_API_KEY`; translates Claude Code requests to Anthropic API calls.
- **Networks:** `int_net` only (no direct internet access — security decision).
- **Technology:** LiteLLM (`ghcr.io/berriai/litellm:main-v1.82.3-stable.patch.2`), pinned image, `read_only: true`, `cap_drop: ALL`.
- **Egress:** All outbound traffic routed through `caddy-sidecar:8081` → `api.anthropic.com:443`. The agent uses a short-lived `DYNAMIC_AGENT_KEY`, never the real `ANTHROPIC_API_KEY`.
- **Config:** `proxy_config.yaml` sets `api_base: https://caddy-sidecar:8081`.

### 4. mcp-server
- **Role:** Filesystem operations server. Provides read/write access to `/workspace` for the agent.
- **Port:** `:8443` (internal TLS).
- **Networks:** `int_net` only.
- **Technology:** Go REST server, `os.OpenRoot` jail at `/workspace` (traversal blocked at runtime level).
- **Security:** `entrypoint.sh` env + `.env` scan; tmpfs shadows `/workspace/.git` (size=0, ro) to prevent git hook execution; structured file-access logging (path + SHA256 only, no content in logs).

### 5. git-server
- **Role:** Git operations server (status, diff, add, commit, log, reset).
- **Port:** `:8443` (internal TLS).
- **Networks:** `int_net` only.
- **Technology:** Go REST server.
- **Submodule support:** `parse_gitmodules` + `git_env_for` in `git_mcp.py` route operations to the correct submodule `GIT_DIR` (`/gitdir/modules/<path>`). All tools accept optional `submodule_path`.
- **Security:** Separated gitdir (`/gitdir` bind mount, rw) + `/workspace` (ro); baseline commit floor enforced at startup; `core.hooksPath=/dev/null` prevents hook execution; per-submodule baseline floors for `git_reset_soft`.

### 6. plan-server
- **Role:** Plan lifecycle management (create, read, update, block, complete tasks).
- **Port:** `:8443` (internal TLS).
- **Networks:** `int_net` only.
- **Technology:** Python FastAPI, JSON plan files persisted in `/plans`.
- **Security:** `PLAN_API_TOKEN` scoped exclusively to this service; field-length validation on all text fields (HTTP 400 on overflow); no access to `/workspace`, `/gitdir`, or other service secrets.

### 7. tester-server
- **Role:** Test execution server. Runs `/workspace/test.sh` as a subprocess and returns results.
- **Port:** `:8443` (internal TLS).
- **Networks:** `int_net` only.
- **Technology:** Go REST server; 300s subprocess timeout (`context.WithTimeout`) + 10s `WaitDelay`; exit code 124 on timeout.
- **Security:** `/workspace` mounted read-only; no access to `/gitdir`, `/plans`, or secrets; `pids_limit: 1024` for compiler subprocesses; concurrent-run rejection (409 Conflict).

### 8. log-server
- **Role:** Structured session log storage and query service.
- **Port:** `:8443` (internal TLS).
- **Networks:** `int_net` only.
- **Technology:** Go REST server, JSONL log files in `/logs`.
- **Security:** `LOG_API_TOKEN` scoped exclusively to this service; no access to workspace, gitdir, or plans; log writes from `claude-server` are fire-and-forget (non-fatal failures); no file content in logs.

---

## Data Flow

### Request Flow (POST /ask)

```
External user
  └─ HTTPS (Bearer CLAUDE_API_TOKEN) ─→ Caddy:8443
       └─ HTTP ─→ claude-server:8000 (FastAPI verifies token)
            └─ subprocess: claude --print --mcp-config .mcp.json ...
                 ├─ plan_current ─→ mcp-watchdog ─→ plan_mcp.py ─→ plan-server:8443
                 ├─ read_workspace_file ─→ mcp-watchdog ─→ files_mcp.py ─→ mcp-server:8443
                 ├─ git_add/commit ─→ mcp-watchdog ─→ git_mcp.py ─→ git-server:8443
                 ├─ run_tests ─→ mcp-watchdog ─→ tester_mcp.py ─→ tester-server:8443
                 ├─ list_sessions ─→ mcp-watchdog ─→ log_mcp.py ─→ log-server:8443
                 └─ LLM call ─→ ANTHROPIC_BASE_URL=proxy:4000
                      └─ LiteLLM ─→ caddy-sidecar:8081 ─→ api.anthropic.com:443
```

### Plan-Execute Loop

```
1. POST /plan  →  Claude (plan mode) creates JSON plan  →  plan-server persists it
2. POST /ask   →  Claude calls plan_current → gets next pending task
3. Claude reads files (fileserver), edits code (fileserver)
4. Claude runs tests (tester-server); on failure: fix and retry (max 3 attempts)
5. On pass: Claude calls git_add + git_commit (git-server), then plan_complete
6. Repeat from step 2 until plan_current returns no active task → output DONE
```

### Credential Flow

```
External user  →  CLAUDE_API_TOKEN   →  claude-server (verified by FastAPI)
claude-server  →  MCP_API_TOKEN      →  mcp-server
claude-server  →  GIT_API_TOKEN      →  git-server
claude-server  →  PLAN_API_TOKEN     →  plan-server
claude-server  →  TESTER_API_TOKEN   →  tester-server
claude-server  →  LOG_API_TOKEN      →  log-server
claude-server  →  DYNAMIC_AGENT_KEY  →  proxy (LiteLLM)
proxy          →  ANTHROPIC_API_KEY  →  api.anthropic.com (via caddy-sidecar:8081)
```

The agent **never** holds `ANTHROPIC_API_KEY`. Each service token is forbidden in all other services' environments, enforced by startup isolation checks.

---

## Technology Stack

| Category | Technology | Details |
|:---|:---|:---|
| **Agent runtime** | Claude Code CLI | Pinned `@2.1.74`, `--print` mode, `--dangerously-skip-permissions` |
| **LLM gateway** | LiteLLM | `ghcr.io/berriai/litellm:main-v1.82.3-stable.patch.2` |
| **API server** | Python / FastAPI | `claude-server`, `plan-server` |
| **File/Git/Test/Log servers** | Go | `mcp-server`, `git-server`, `tester-server`, `log-server` |
| **Reverse proxy / TLS** | Caddy 2 | Internal CA (TLS 1.3 minimum on all Go servers) |
| **MCP transport** | stdio wrappers → HTTPS REST | Python wrappers in `claude/` directory; mcp-watchdog intercepts JSON-RPC |
| **Plan format** | JSON | Stored in `plans/` directory in parent repo |
| **Container runtime** | Docker / Docker Compose | 8 containers, `int_net` (internal) + `ext_net` |
| **TLS** | Internal CA + public CA | Internal CA for service-to-service; public CA for Anthropic egress |
| **Test tooling (tester image)** | Python 3.12, pytest 8.3.4, Go 1.26.1 | Pre-installed in `Dockerfile.tester` |
| **Security scanning** | govulncheck, pip-audit, hadolint, trivy | `test-integration.sh` (requires network, runs on host) |

### Key Libraries & Frameworks

| Component | Dependencies |
|:---|:---|
| claude-server | FastAPI, uvicorn, pydantic, requests, mcp, mcp-watchdog |
| proxy | LiteLLM (Docker image), tiktoken |
| mcp-server | Go stdlib, `os.OpenRoot` |
| git-server | Go stdlib, `os/exec` (git) |
| plan-server | FastAPI, uvicorn, pydantic |
| tester-server | Go stdlib, `os/exec`, `context.WithTimeout` |
| log-server | Go stdlib |
| caddy-sidecar | Caddy 2 Alpine |

---

## Network Topology

```
ext_net (external)
  └─ caddy-sidecar:8443   ← host port binding (user-facing)
  └─ caddy-sidecar:8081   ← egress only → api.anthropic.com:443

int_net (internal, Docker bridge, internal: true — no external routing)
  ├─ caddy-sidecar
  ├─ claude-server:8000
  ├─ proxy:4000
  ├─ mcp-server:8443
  ├─ git-server:8443
  ├─ plan-server:8443
  ├─ tester-server:8443
  └─ log-server:8443
```

All service-to-service communication uses TLS with the internal CA. No service other than `caddy-sidecar` is on `ext_net`.

---

## Volume Mounts

### claude-server
| Host path | Container path | Mode | Purpose |
|:---|:---|:---|:---|
| `<active-repo>/docs` | `/docs` | ro | Project documentation for docs MCP |

### mcp-server
| Host path | Container path | Mode | Purpose |
|:---|:---|:---|:---|
| `./workspace` (→ active sub-repo) | `/workspace` | rw | Go fileserver reads/writes code |
| tmpfs | `/workspace/.git` | ro, size=0 | Shadows `.git` to prevent hook execution |

### git-server
| Host path | Container path | Mode | Purpose |
|:---|:---|:---|:---|
| `./workspace/.git` | `/gitdir` | rw | Git data for add/commit/reset |
| `./workspace` (→ active sub-repo) | `/workspace` | ro | Worktree for status/diff/log |

### plan-server
| Host path | Container path | Mode | Purpose |
|:---|:---|:---|:---|
| `../plans` | `/plans` | rw | JSON plan state files |

### tester-server
| Host path | Container path | Mode | Purpose |
|:---|:---|:---|:---|
| `./workspace` (→ active sub-repo) | `/workspace` | ro | Test runner reads source and executes `test.sh` |

### log-server
| Host path | Container path | Mode | Purpose |
|:---|:---|:---|:---|
| `./logs` | `/logs` | rw | JSONL session log files |

---

## Security Architecture

The system enforces structural security boundaries — isolation is achieved by architecture, not filtering.

### Token Isolation Matrix

| Token | claude-server | proxy | mcp-server | plan-server | tester-server | git-server | log-server | caddy |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| ANTHROPIC_API_KEY | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| DYNAMIC_AGENT_KEY | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| CLAUDE_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| MCP_API_TOKEN | ✓ required | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| PLAN_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| TESTER_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| GIT_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden |
| LOG_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden |

### Security Layers (22 principles)

1. **Credential isolation** — Agent uses `DYNAMIC_AGENT_KEY`; `ANTHROPIC_API_KEY` confined to `proxy` only.
2. **Network isolation** — `claude-server` on `int_net` only; `proxy` has no direct internet; all egress through `caddy-sidecar:8081` locked to `api.anthropic.com`.
3. **MCP security proxy** — `mcp-watchdog` intercepts all JSON-RPC, blocking 40+ attack classes.
4. **Filesystem jail** — `os.OpenRoot` at `/workspace` in Go; traversal blocked at the runtime level.
5. **Repo isolation** — Active sub-repo as `/workspace`; parent repo not visible to agent.
6. **Git hook prevention** — tmpfs shadow over `.git` in mcp-server, separated gitdir, `core.hooksPath=/dev/null`; per-session baseline floor prevents reset past session start.
7. **Git history protection** — Baseline commit floor at container startup; `git_reset_soft` cannot undo pre-session commits.
8. **Plan isolation** — `plan-server` has no access to `/workspace`, `/gitdir`, or secrets; plans are not modifiable through the file MCP tool.
9. **Test isolation** — `tester-server` has `/workspace` read-only; no access to `/gitdir`, `/plans`, or secrets.
10. **Per-service token scoping** — Eight distinct tokens; each forbidden in all other services' environments; enforced by startup checks.
11. **TLS everywhere** — Internal CA for service-to-service (TLS 1.3 minimum on all Go servers); public CA for Anthropic egress; no `tls_insecure_skip_verify`.
12. **Startup isolation checks** — Every container validates env + token presence/absence before serving (26 checks on `claude-server`).
13. **MCP config as build artifact** — `.mcp.json` baked into image; not runtime-configurable by agent.
14. **Non-root containers** — UID 1000, `cap_drop: ALL`, `mem_limit`, `cpus`, `pids_limit` on all containers.
15. **Log sanitization** — `server.py` subprocess stdout/stderr demoted to DEBUG; `_redact_secrets()` replaces all known token values with `[REDACTED]`; configurable via `LOG_LEVEL`.
16. **Tester subprocess timeout** — `context.WithTimeout` (300s default, configurable via `TEST_TIMEOUT`) + `cmd.WaitDelay = 10s`; timed-out tests return exit code 124.
17. **Structured file-access logging** — mcp-server logs `FILE_READ: <path> (<n> bytes, sha256=<hex>)` only; no file content in logs; regression test asserts content never appears.
18. **Slash command name hardening** — `os.path.basename()` strips directory components; `PATH_BLACKLIST` rejects `..`, null bytes, and shell metacharacters; traversal is structural.
19. **Plan field-length validation** — `plan_server.py` enforces max lengths on all text fields in create/update/block endpoints; oversized payloads rejected with HTTP 400.
20. **Model allowlist** — `server.py` validates `request.model` against `ALLOWED_MODELS` frozenset before subprocess invocation; unknown models rejected with HTTP 400.
21. **Request body size limits** — `QueryRequest` enforces `max_length=100_000` on `query`, `max_length=200` on `model` (Pydantic `Field`); Caddy ingress caps at 256 KB via `request_body { max_size 256KB }`.
22. **Log service isolation** — `log-server` has its own `LOG_API_TOKEN`; no cross-service token access; log writes from `claude-server` are fire-and-forget daemon threads (failures non-fatal).

---

## Directory Structure (Parent Repo)

```
secure-claude/
├── cluster/
│   ├── agent/              # Claude Code MCP wrappers + system prompts (submodule)
│   │   ├── claude/         # MCP stdio wrappers (files_mcp.py, git_mcp.py, …)
│   │   ├── prompts/
│   │   │   ├── system/     # ask.md, plan.md  (baked into image)
│   │   │   └── commands/   # Claude Code slash commands (/architecture-doc, etc.)
│   │   └── test.sh         # Unit tests (no network)
│   ├── planner/            # Planner submodule
│   ├── tester/             # Tester server submodule (Go)
│   ├── Dockerfile.claude   # claude-server image
│   ├── Dockerfile.caddy    # caddy-sidecar image
│   ├── Dockerfile.tester   # tester-server image
│   ├── docker-compose.yml  # 8-container cluster definition
│   ├── Caddyfile           # Reverse proxy + egress config
│   ├── workspace/          # Symlink → active sub-repo
│   └── certs/              # Internal CA + leaf certs (generated by run.sh)
├── docs/
│   ├── ARCHITECTURE.md         # This file (combined reference)
│   ├── CONTEXT.md              # Detailed architecture + security decisions
│   ├── PLAN.md                 # Development roadmap
│   ├── HARDENING.md            # Per-container hardening decisions
│   ├── THREAT_MODEL.md         # Threat model + residual risk register
│   └── TOKEN_USE.md            # Token consumption analysis + optimization plan
├── plans/                  # JSON plan files (persisted plan state)
├── logs/                   # JSONL session logs
├── run.sh                  # Cluster startup + cert generation
├── query.sh                # POST /ask client script
├── plan.sh                 # POST /plan client script
└── test.sh                 # Parent-repo test runner (unit + integration split)
```

---

## Decisions Log

| Decision | Chosen | Rejected | Reason |
|:---|:---|:---|:---|
| Agent framework | Claude Code CLI subprocess | LangChain | Simpler, no orchestration overhead |
| MCP transport | stdio wrappers | HTTP direct to servers | Servers are REST not MCP protocol |
| Git isolation | Submodule repo | Path filtering | Path filtering vulnerable to traversal |
| Dockerfile location | Parent repo | Inside submodule | Dockerfiles need certs/; keeps agent from modifying its container |
| MCP config delivery | `--mcp-config` + build-time `.mcp.json` | `claude mcp add` at runtime | `--print` mode doesn't auto-discover config |
| Claude Code version | Pinned `@2.1.74` | Latest | Flag behavior changes between versions |
| Planning tool | Separate container (plan-server) | File convention or in-process | Prevents agent writing plan files through fileserver MCP |
| Plan format | JSON | XML | Simpler parsing, no schema library needed |
| Plan storage | Parent repo `plans/` | Agent workspace | Plans are infrastructure, not agent-modifiable code |
| Planner repo | Separate submodule | Inside agent submodule | Independent development; swappable workspace for self-development |
| Test execution | Direct subprocess in tester-server | Docker-in-Docker | No socket access needed, simpler, no privilege escalation |
| Tester workspace access | Read-only mount | Read-write | Tests should never modify source |
| Security scans location | `test-integration.sh` only | Sub-repo `test.sh` | Vuln DB fetches need network; sub-repo tests run in network-isolated tester |
| Submodule git routing | `parse_gitmodules` + `git_env_for` in `git_mcp.py` | Separate tool per submodule | Single tool surface; auto-detection from file paths; per-submodule baseline floors |
| Proxy external network access | Removed (`int_net` only, egress via caddy-sidecar) | Direct internet from proxy | Prevents proxy from exfiltrating `ANTHROPIC_API_KEY`; all outbound funnelled through caddy-sidecar |
| Architecture doc format | Single `ARCHITECTURE.md` (combined) | Split OVERVIEW/DETAIL immediately | Split into `ARCHITECTURE_OVERVIEW.md` + `ARCHITECTURE_DETAIL.md` is planned (see TOKEN_USE.md §5.5); generate via `/architecture-doc` command |

Container hardening decisions and kernel constraints: [docs/HARDENING.md](docs/HARDENING.md)

Sub-repo specific implementation details:
- Agent: [cluster/agent/docs/CONTEXT.md](../cluster/agent/docs/CONTEXT.md)
- Planner: [cluster/planner/docs/CONTEXT.md](../cluster/planner/docs/CONTEXT.md)
- Tester: [cluster/tester/docs/CONTEXT.md](../cluster/tester/docs/CONTEXT.md)
