# Architecture Overview

## Overview

**secure-claude** is a hardened, containerized environment for running Claude Code as an autonomous AI coding agent. The system enables a *plan-then-execute* agentic loop where Claude Code can read, modify, test, and commit source code without holding real API credentials or having direct internet access. Security is enforced structurally — through container isolation, network segmentation, per-service token scoping, and filesystem jails — rather than by filtering.

---

## System Components

Nine containers run on an internal Docker network (`int_net`):

| Service | Role | Technology | Port |
|:---|:---|:---|:---|
| **caddy-sidecar** | TLS termination, external ingress, egress proxy | Caddy 2 Alpine | `:8443` (ingress), `:8081` (egress → `api.anthropic.com` only) |
| **claude-server** | Main app server; spawns Claude Code CLI + 6 MCP stdio servers | Python/FastAPI, Claude Code CLI `@2.1.74` | `:8000` |
| **codex-server** | Parallel agent; spawns OpenAI Codex CLI + MCP stdio servers | Python/FastAPI, OpenAI Codex | `:8000` |
| **proxy** | LLM API gateway; holds real `ANTHROPIC_API_KEY` | LiteLLM (pinned Docker image) | `:4000` |
| **mcp-server** | Filesystem operations; `os.OpenRoot` jail at `/workspace` | Go REST | `:8443` |
| **git-server** | Git operations (status/diff/add/commit/log/reset) | Go REST | `:8443` |
| **plan-server** | Plan lifecycle management (create/read/update/block/complete) | Python/FastAPI | `:8443` |
| **tester-server** | Test execution; runs `/workspace/test.sh` as subprocess | Go REST | `:8443` |
| **log-server** | Structured session log storage and queries | Go REST | `:8443` |

Only `caddy-sidecar` is on both `ext_net` (external) and `int_net`. All other services are `int_net` only.

### Endpoints

| Endpoint | Script | System Prompt | Purpose |
|:---|:---|:---|:---|
| `POST /ask` | `query.sh` | `ask.md` (plan-driven) or `ask-adhoc.md` (ad-hoc) | Execute code changes |
| `POST /plan` | `plan.sh` | `plan.md` | Create plans only, no code execution |

---

## Data Flow

### Request Flow (POST /ask)

```
External user
  └─ HTTPS (Bearer CLAUDE_API_TOKEN) ─→ Caddy:8443
       └─ HTTP ─→ claude-server:8000 (FastAPI verifies token)
            └─ subprocess: claude --print --mcp-config .mcp.json ...
                 ├─ plan_current ─→ plan_mcp.py ─→ plan-server:8443
                 ├─ read/write files ─→ files_mcp.py ─→ mcp-server:8443
                 ├─ git operations ─→ git_mcp.py ─→ git-server:8443
                 ├─ run tests ─→ tester_mcp.py ─→ tester-server:8443
                 ├─ query logs ─→ log_mcp.py ─→ log-server:8443
                 └─ LLM call ─→ proxy:4000 ─→ caddy-sidecar:8081 ─→ api.anthropic.com
```

### Plan-Execute Loop

1. `POST /plan` → Claude creates JSON plan → plan-server persists it
2. `POST /ask` → Claude calls `plan_current` → gets next pending task
3. Claude reads files (fileserver), edits code (fileserver)
4. Claude runs tests (tester-server); on failure: fix and retry (max 3 attempts)
5. On pass: Claude calls `git_add` + `git_commit` (git-server), then `plan_complete`
6. Repeat from step 2 until no active task → output `DONE`

### Credential Flow

```
External user  →  CLAUDE_API_TOKEN   →  claude-server
claude-server  →  MCP_API_TOKEN      →  mcp-server
claude-server  →  GIT_API_TOKEN      →  git-server
claude-server  →  PLAN_API_TOKEN     →  plan-server
claude-server  →  TESTER_API_TOKEN   →  tester-server
claude-server  →  LOG_API_TOKEN      →  log-server
claude-server  →  DYNAMIC_AGENT_KEY  →  proxy (LiteLLM)
proxy          →  ANTHROPIC_API_KEY  →  api.anthropic.com (via caddy-sidecar:8081)
```

The agent **never** holds `ANTHROPIC_API_KEY`.

---

## Technology Stack

| Category | Technology |
|:---|:---|
| Agent runtime | Claude Code CLI (pinned `@2.1.74`, `--print` mode) |
| LLM gateway | LiteLLM (`ghcr.io/berriai/litellm:main-v1.82.3-stable.patch.2`) |
| API servers | Python / FastAPI (`claude-server`, `plan-server`) |
| File/Git/Test/Log servers | Go (`mcp-server`, `git-server`, `tester-server`, `log-server`) |
| Reverse proxy / TLS | Caddy 2 (internal CA, TLS 1.3 minimum) |
| MCP transport | stdio wrappers → HTTPS REST; `mcp-watchdog` intercepts all JSON-RPC |
| Plan format | JSON (stored in `plans/` directory) |
| Container runtime | Docker / Docker Compose (9 containers) |
| Test tooling (tester image) | Python 3.12, pytest 8.3.4, Go 1.26.1 |
| Security scanning | govulncheck, pip-audit, hadolint, trivy (`test-integration.sh`) |

---

## MCP Tool Architecture

Six MCP stdio servers run inside `claude-server`. Each wraps a backend REST service (or local filesystem) and is intercepted by `mcp-watchdog` which blocks 40+ attack classes on all JSON-RPC traffic.

| MCP Server | Backend | Transport | Tools |
|:---|:---|:---|:---|
| `files_mcp.py` | mcp-server:8443 | stdio → HTTPS REST | `read_workspace_file`, `list_files`, `create_file`, `write_file`, `delete_file`, `grep_files`, `replace_in_file`, `append_file`, `create_directory` |
| `git_mcp.py` | git-server:8443 | stdio → HTTPS REST | `git_status`, `git_diff`, `git_add`, `git_commit`, `git_log`, `git_reset_soft` |
| `docs_mcp.py` | `/docs` (local ro mount) | stdio → local fs | `list_docs`, `read_doc` |
| `plan_mcp.py` | plan-server:8443 | stdio → HTTPS REST | `plan_current`, `plan_list`, `plan_complete`, `plan_block`, `plan_create`, `plan_update_task` |
| `tester_mcp.py` | tester-server:8443 | stdio → HTTPS REST | `run_tests`, `get_test_results` |
| `log_mcp.py` | log-server:8443 | stdio → HTTPS REST | `list_sessions`, `get_session_summary`, `query_logs`, `get_token_breakdown` |

### MCP Config Delivery

`.mcp.json` is baked into the `claude-server` Docker image at build time. The agent cannot modify which tools it has access to at runtime. Claude Code is invoked with `--mcp-config .mcp.json`.

### Submodule Support

All git tools accept an optional `submodule_path` parameter. `git_add` auto-detects the owning submodule from file paths. Routing uses `parse_gitmodules` + `git_env_for` in `git_mcp.py` to resolve the correct `GIT_DIR` per submodule.

---

## Workspace Interface

### How the Workspace Is Mounted

In `docker-compose.yml`, the active sub-repo is bind-mounted as `/workspace`:

| Container | Mount Path | Mode | Purpose |
|:---|:---|:---|:---|
| mcp-server | `/workspace` | rw | File reads/writes via Go fileserver |
| git-server | `/workspace` | ro | Worktree for status/diff/log |
| git-server | `/gitdir` | rw | Git data for add/commit/reset |
| tester-server | `/workspace` | ro | Test execution |
| claude-server | `/docs` | ro | Project documentation (from `<repo>/docs/`) |
| plan-server | `/plans` | rw | JSON plan state files |
| log-server | `/logs` | rw | JSONL session log files |
| mcp-server | `/workspace/.git` (tmpfs) | ro, size=0 | Shadows `.git` to prevent hook execution |

Only **one sub-repo** is mounted at a time. The parent repo is not visible to the agent. Cross-project context bleed is architecturally impossible.

### Workspace Contract

Each mounted workspace must provide:
- `docs/CONTEXT.md` — architecture the agent needs before making changes
- `docs/PLAN.md` — development roadmap and task backlog
- `test.sh` — executable unit test script (no network required)

### Isolation Properties

- `/workspace` is read-only in `claude-server` and `tester-server`; writes go only through `mcp-server`'s `os.OpenRoot` jail
- `plan-server` has no access to `/workspace`, `/gitdir`, or secrets
- `tester-server` has no access to `/gitdir`, `/plans`, or secrets
- `log-server` has no access to `/workspace`, `/gitdir`, or `/plans`

---

## Directory Structure

```
secure-claude/
├── cluster/
│   ├── agent/              # MCP wrappers + system prompts (submodule)
│   │   ├── claude/         # FastAPI server + isolation checks
│   │   ├── mcp/            # MCP stdio wrappers
│   │   └── prompts/        # system/ (ask.md, plan.md) + commands/
│   ├── planner/            # Planner submodule
│   ├── tester/             # Tester server submodule (Go)
│   ├── Dockerfile.claude   # claude-server image
│   ├── Dockerfile.codex    # codex-server image
│   ├── Dockerfile.caddy    # caddy-sidecar image
│   ├── Dockerfile.tester   # tester-server image
│   ├── docker-compose.yml  # 9-container cluster definition
│   ├── Caddyfile           # Reverse proxy + egress config
│   ├── workspace/          # Symlink → active sub-repo
│   └── certs/              # Internal CA + leaf certs
├── docs/                   # Project documentation
├── plans/                  # JSON plan files
├── logs/                   # JSONL session logs
├── run.sh                  # Cluster startup + cert generation
├── query.sh                # POST /ask client
├── plan.sh                 # POST /plan client
└── test.sh                 # Parent-repo test runner
```
