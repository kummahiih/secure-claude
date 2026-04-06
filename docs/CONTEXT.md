# secure-claude: Project Context

## What This Is

A hardened, containerized environment for running Claude Code as an autonomous AI agent
with access to local tools via MCP. The agent never holds real credentials — a LiteLLM
sidecar proxy holds the real API keys while the agent uses ephemeral tokens.

The agent supports a plan-then-execute workflow: structured plans are created via
`plan.sh`, then executed task-by-task via `query.sh`.

Repos:
- Parent: secure-claude (this repo)
- Agent submodule: [secure-claude-agent](../cluster/agent/)
- Planner submodule: [secure-claude-planner](../cluster/planner/)
- Tester submodule: [secure-claude-tester](../cluster/tester/)

---

## Current Architecture

```
Host / Network
└─> Caddy:8443 (TLS 1.3 + reverse proxy)
     ├─> claude-server:8000 (FastAPI + Claude Code subprocess)
     │    ├─> proxy:4000 (LiteLLM) ──> caddy-sidecar:8081 ──> Anthropic API
     │    └─> MCP stdio servers (inside claude-server):
     │         ├─> files_mcp.py  → HTTPS REST → mcp-server:8443
     │         ├─> git_mcp.py    → HTTPS REST → git-server:8443
     │         ├─> docs_mcp.py   → reads /docs (read-only mount)
     │         ├─> plan_mcp.py   → HTTPS REST → plan-server:8443
     │         ├─> tester_mcp.py → HTTPS REST → tester-server:8443
     │         └─> log_mcp.py    → HTTPS REST → log-server:8443
     ├─> codex-server:8000 (FastAPI + OpenAI Codex subprocess)
     │    ├─> proxy:4000 (LiteLLM) ──> caddy-sidecar:8081 ──> OpenAI API
     │    └─> MCP stdio servers (inside codex-server)
     ├─> mcp-server:8443 (Go REST, os.OpenRoot jail)
     │    └─> /workspace (bind mount → active sub-repo)
     ├─> git-server:8443 (Go REST, git operations)
     │    ├─> /gitdir (bind mount → workspace/.git)
     │    └─> /workspace:ro (bind mount → active sub-repo)
     ├─> plan-server:8443 (Python REST, JSON plan files)
     │    └─> /plans (bind mount → plans/)
     ├─> tester-server:8443 (Go REST, test runner)
     │    └─> /workspace:ro (bind mount → active sub-repo)
     └─> log-server:8443 (Go REST, structured session logs)
          └─> /logs (bind mount → logs/)
```

### Nine containers, all on internal Docker network (int_net):

| Service | Description | Isolation checks |
| :--- | :--- | :--- |
| caddy-sidecar | TLS termination, external ingress (:8443) + dedicated egress-only proxy (:8081 → api.anthropic.com:443) | caddy_entrypoint.sh |
| claude-server | FastAPI + Claude Code CLI subprocess + 6 MCP stdio servers | verify_isolation.py (26 checks) |
| proxy | LiteLLM gateway, holds real ANTHROPIC_API_KEY; int_net only, **no direct external network access** (security decision) — all egress routes through caddy-sidecar:8081 | proxy_wrapper.py (4 checks) |
| mcp-server | Go REST server, os.OpenRoot jail at /workspace | entrypoint.sh (env + .env scan) |
| plan-server | Python REST server, plan state in /plans | plan_server.py (10 checks) |
| git-server | Go REST server, git operations (status/diff/add/commit/log/reset) | entrypoint.sh (env + token scan) |
| tester-server | Go REST server, runs /workspace/test.sh as subprocess | entrypoint.sh (env scan + /workspace check) |
| codex-server | FastAPI + OpenAI Codex CLI subprocess + MCP stdio servers | verify_isolation.py |
| log-server | Go REST server, structured session log storage and queries | entrypoint.sh (env scan + /logs check) |

### MCP tool sets available to Claude Code:

| Server | Tools | Transport | Access |
| :--- | :--- | :--- | :--- |
| fileserver | read_workspace_file, list_files, create_file, write_file, delete_file, grep_files, replace_in_file, append_file, create_directory | stdio → HTTPS REST | Read/write /workspace via Go fileserver |
| git | git_status, git_diff, git_add, git_commit, git_log, git_reset_soft | stdio → HTTPS REST | Read/write via git-server:8443; all tools accept optional `submodule_path` to target a submodule; `git_add` auto-detects submodule from file paths |
| docs | list_docs, read_doc | stdio → local filesystem | Read-only /docs |
| planner | plan_current, plan_list, plan_complete, plan_block, plan_create, plan_update_task | stdio → HTTPS REST | Read/write plan state via plan-server |
| tester | run_tests, get_test_results | stdio → HTTPS REST | Run tests and retrieve results via tester-server |
| logs | list_sessions, get_session_summary, query_logs, get_token_breakdown | stdio → HTTPS REST | Read session logs via log-server; write via server.py fire-and-forget ingest |

### Two endpoints:

| Endpoint | Script | System prompt | Purpose |
| :--- | :--- | :--- | :--- |
| POST /ask | query.sh | ask.md (plan-driven) or ask-adhoc.md (ad-hoc) | Execute code changes; server pre-checks plan-server and uses the plan-driven loop when a task is active, or a single ad-hoc invocation when no plan exists |
| POST /plan | plan.sh | PLAN_SYSTEM_PROMPT (cluster/agent/prompts/system/plan.md) | Create plans only, no code execution |

`cluster/agent/prompts/system/` supplies all system prompts (`ask.md`, `ask-adhoc.md`, `plan.md`); `cluster/agent/prompts/commands/` supplies Claude Code slash commands. Both are baked into the claude-server image at build time (`COPY agent/prompts/system/ /app/prompts/` and `COPY agent/prompts/commands/ /home/appuser/.claude/commands/`) — no runtime bind-mount is required. `runenv.py` reads these prompts from `/app/prompts/` on startup.

### Request flow (/ask):
1. `query.sh` → POST https://localhost:8443/ask (Bearer CLAUDE_API_TOKEN)
2. Caddy → claude-server:8000/ask
3. FastAPI verifies Bearer token, then subprocess:
   `claude --print --dangerously-skip-permissions --output-format json --mcp-config .mcp.json --model <model> --system-prompt <prompt> -- <query>`
4. Claude Code calls plan_current → gets current task (if any)
5. Claude Code → mcp-watchdog → files_mcp.py → HTTPS REST → mcp-server:8443
6. Claude Code → mcp-watchdog → git_mcp.py → HTTPS REST → git-server:8443
7. Claude Code → mcp-watchdog → plan_mcp.py → plan_complete → plan-server:8443
8. Claude Code → mcp-watchdog → tester_mcp.py → HTTPS REST → tester-server:8443
9. Claude Code → mcp-watchdog → log_mcp.py → HTTPS REST → log-server:8443
10. Claude Code → ANTHROPIC_BASE_URL=https://proxy:4000 → LiteLLM → caddy-sidecar:8081 → Anthropic API

### Volume mounts on claude-server:

| Host path | Container path | Mode | Purpose |
| :--- | :--- | :--- | :--- |
| active sub-repo/docs | /docs | ro | Project documentation |

### Volume mounts on git-server:

| Host path | Container path | Mode | Purpose |
| :--- | :--- | :--- | :--- |
| ./workspace/.git | /gitdir | rw | Git data for add/commit/reset |
| ./workspace (→ active sub-repo) | /workspace | ro | Worktree for status/diff/add |

### Volume mounts on mcp-server:

| Host path | Container path | Mode | Purpose |
| :--- | :--- | :--- | :--- |
| ./workspace (→ active sub-repo) | /workspace | rw | Go fileserver reads/writes code |
| tmpfs | /workspace/.git | ro,size=0 | Shadows .git via tmpfs — structural hook prevention |

### Volume mounts on plan-server:

| Host path | Container path | Mode | Purpose |
| :--- | :--- | :--- | :--- |
| ../plans | /plans | rw | Plan state files (JSON) |

### Volume mounts on tester-server:

| Host path | Container path | Mode | Purpose |
| :--- | :--- | :--- | :--- |
| ./workspace (→ active sub-repo) | /workspace | ro | Test runner reads source and executes test.sh |

### Volume mounts on log-server:

| Host path | Container path | Mode | Purpose |
| :--- | :--- | :--- | :--- |
| ./logs | /logs | rw | JSONL session log files written by log-server on ingest |

---

## Core Security Principles

Enforce boundaries structurally, never by filtering.

### Security layers:
1. Credential isolation — agent uses DYNAMIC_AGENT_KEY, never real ANTHROPIC_API_KEY
2. Network isolation — claude-server on int_net only, no direct internet
3. MCP security proxy — mcp-watchdog intercepts all JSON-RPC, blocks 40+ attack classes
4. Filesystem jail — os.OpenRoot at /workspace, traversal blocked at Go runtime level
5. Repo isolation — active sub-repo as /workspace; parent repo not visible
6. Git hook prevention — tmpfs shadow + separated gitdir + core.hooksPath=/dev/null
7. Git history protection — baseline commit floor at container startup
8. Plan isolation — plan-server has no access to /workspace, /gitdir, or secrets
9. Test isolation — tester-server has /workspace read-only, no access to /gitdir, /plans, or secrets
10. Per-service auth — CLAUDE_API_TOKEN for ingress; MCP_API_TOKEN for mcp-server, PLAN_API_TOKEN for plan-server, TESTER_API_TOKEN for tester-server; each token scoped to its own backend (see RR-4, resolved 2026-03-28)
11. TLS everywhere — internal CA, all service-to-service over HTTPS; egress to Anthropic uses proper public TLS (no `tls_insecure_skip_verify`) via dedicated Caddy `:8081` listener hardcoded to `api.anthropic.com:443`
12. Startup isolation checks — every container validates before serving
13. MCP config as build artifact — .mcp.json baked into image
14. Non-root containers — UID 1000, cap_drop: ALL on all seven containers; mem_limit + cpus + pids_limit on all containers
15. Log sanitization — `server.py` subprocess stdout/stderr demoted to DEBUG level; `_redact_secrets()` replaces all known token values with `[REDACTED]` before any log output; configurable via `LOG_LEVEL` env var
16. Tester subprocess timeout — `tester/main.go` uses `context.WithTimeout` (300s default, configurable via `TEST_TIMEOUT`) with `cmd.WaitDelay = 10s`; timed-out tests return exit code 124
17. Structured file-access logging — mcp-server logs `FILE_READ: <path> (<n> bytes, sha256=<hex>)` only; no file content written to logs; regression test asserts content never appears in log output
18. Slash command name hardening — `_expand_slash_command()` applies `os.path.basename()` to strip all directory components before building the file path, then rejects names matching `PATH_BLACKLIST` (`..`, `\0`, shell metacharacters); traversal is structural, not filtered (RR-7, resolved 2026-03-29)
19. Plan field-length validation — `plan_server.py` enforces maximum lengths on all text fields (`goal`, `name`, `action`, `verify`, `done`, file paths, `reason`, `context`) in the create, update, and block endpoints; oversized payloads are rejected with HTTP 400 identifying the offending field (RR-14, resolved 2026-03-30)
20. Model allowlist — `server.py` validates `request.model` against `ALLOWED_MODELS` frozenset (`claude-sonnet-4-6`, `claude-opus-4-6`, `claude-haiku-4-5-20251001`) before subprocess invocation; unknown models are rejected with HTTP 400 (RR-15, resolved 2026-03-30)
21. Request body size limits — `QueryRequest` enforces `max_length=100_000` on `query` and `max_length=200` on `model` via Pydantic `Field`, rejecting oversized payloads with HTTP 422 before endpoint logic runs; Caddy ingress additionally caps incoming request bodies at 256 KB via `request_body { max_size 256KB }` on `:8443` (RR-16, resolved 2026-03-30)
22. Log service isolation — `log-server` has its own `LOG_API_TOKEN`, no access to `/workspace`, `/gitdir`, `/plans`, or any other service's secrets; `entrypoint.sh` rejects startup if any cross-service token is present; log writes from `claude-server` are fire-and-forget daemon threads (failures are non-fatal and logged at WARNING); no file content appears in logs (only paths and SHA256 where applicable)

### Token isolation matrix:

| Token | claude-server | codex-server | proxy | mcp-server | plan-server | tester-server | git-server | log-server | caddy |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| ANTHROPIC_API_KEY | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| DYNAMIC_AGENT_KEY | ✓ required | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| CLAUDE_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| CODEX_API_TOKEN | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| MCP_API_TOKEN | ✓ required | ✓ required | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| PLAN_API_TOKEN | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| TESTER_API_TOKEN | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| GIT_API_TOKEN | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden |
| LOG_API_TOKEN | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden |

---

## Test Suite (test.sh)

1. Caddy config validation
2. Dockerfile linting (hadolint)
3. Docker Compose config scan (trivy)
4. Docker build
5. Security scans (govulncheck for fileserver + tester, pip-audit, npm audit)
6. Sub-repo unit tests (agent, planner, tester)
7. Integration tests (MCP registration, health checks, auth, isolation for all services)

### Test architecture split:
- **Sub-repo test.sh** — unit tests only, no network required, runnable inside tester-server
- **test-integration.sh** — security scans (need network for vuln DBs) + integration tests (need Docker)

---

## Decisions Log

| Decision | Chosen | Rejected | Reason |
| :--- | :--- | :--- | :--- |
| Agent framework | Claude Code CLI subprocess | LangChain | Simpler, no orchestration overhead |
| MCP transport | stdio wrappers | HTTP direct to servers | Servers are REST not MCP protocol |
| Git isolation | Submodule repo | Path filtering | Path filtering vulnerable to traversal |
| Dockerfile location | Parent repo | Inside submodule | Dockerfiles need certs/; keeps agent from modifying its container |
| MCP config delivery | --mcp-config + build-time .mcp.json | claude mcp add at runtime | --print mode doesn't auto-discover config |
| Claude Code version | Pinned @2.1.74 | Latest | Flag behavior changes between versions |
| Planning tool | Separate container (plan-server) | File convention or in-process | Prevents agent writing plan files through fileserver MCP |
| Plan format | JSON | XML (GSD-style) | Simpler parsing, no schema library needed |
| Plan storage | Parent repo plans/ | Agent workspace | Plans are infrastructure, not agent-modifiable code |
| Planner repo | Separate submodule | Inside agent submodule | Independent development; swappable workspace for self-development |
| Test execution | Direct subprocess in tester-server | Docker-in-Docker | No socket access needed, simpler, no privilege escalation |
| Tester workspace access | Read-only mount | Read-write | Tests should never modify source |
| Security scans location | test-integration.sh only | Sub-repo test.sh | Vuln DB fetches need network; sub-repo tests run in network-isolated tester |
| Tester repo | Separate submodule (cluster/tester/) | Directory in parent | Consistent with agent/planner pattern; independently developable |
| Tester MCP wrapper location | agent/claude/tester_mcp.py | tester submodule | Co-located with other MCP wrappers; picked up by existing Dockerfile glob |
| Submodule git routing | parse_gitmodules + git_env_for in git_mcp.py | Separate tool per submodule | Single tool surface; auto-detection from file paths; per-submodule baseline floors |
| Proxy external network access | Removed (int_net only, egress via caddy-sidecar) | Direct internet from proxy container | Security decision: prevents proxy from exfiltrating ANTHROPIC_API_KEY or reaching external hosts directly; all outbound traffic is funnelled through caddy-sidecar for visibility and control |

Container hardening decisions and kernel constraints: [docs/HARDENING.md](docs/HARDENING.md)

Sub-repo specific implementation details:
- Agent: [docs/CONTEXT.md](../cluster/agent/docs/CONTEXT.md)
- Planner: [docs/CONTEXT.md](../cluster/planner/docs/CONTEXT.md)
- Tester: [docs/CONTEXT.md](../cluster/tester/docs/CONTEXT.md)

