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

---

## Current Architecture

```
Host / Network
└─> Caddy:8443 (TLS 1.3 + reverse proxy)
     └─> claude-server:8000 (FastAPI + Claude Code subprocess)
          ├─> proxy:4000 (LiteLLM) ──> Anthropic API
          ├─> MCP stdio servers (inside claude-server):
          │    ├─> files_mcp.py → HTTPS REST → mcp-server:8443
          │    ├─> git_mcp.py   → git subprocess (GIT_DIR=/gitdir)
          │    ├─> docs_mcp.py  → reads /docs (read-only mount)
          │    └─> plan_mcp.py  → HTTPS REST → plan-server:8443
          ├─> mcp-server:8443 (Go REST, os.OpenRoot jail)
          │    └─> /workspace (bind mount → active sub-repo)
          └─> plan-server:8443 (Python REST, JSON plan files)
               └─> /plans (bind mount → plans/)
```

### Five containers, all on internal Docker network (int_net):

| Service | Description | Isolation checks |
| :--- | :--- | :--- |
| caddy-sidecar | TLS termination, external ingress, reverse proxy | caddy_entrypoint.sh |
| claude-server | FastAPI + Claude Code CLI subprocess + 4 MCP stdio servers | verify_isolation.py (26 checks) |
| proxy | LiteLLM gateway, holds real ANTHROPIC_API_KEY | proxy_wrapper.py (4 checks) |
| mcp-server | Go REST server, os.OpenRoot jail at /workspace | entrypoint.sh (env + .env scan) |
| plan-server | Python REST server, plan state in /plans | plan_server.py (10 checks) |

### MCP tool sets available to Claude Code:

| Server | Tools | Transport | Access |
| :--- | :--- | :--- | :--- |
| fileserver | read_workspace_file, list_files, create_file, write_file, delete_file | stdio → HTTPS REST | Read/write /workspace via Go fileserver |
| git | git_status, git_diff, git_add, git_commit, git_log, git_reset_soft | stdio → git subprocess | Read/write /gitdir, read /workspace |
| docs | list_docs, read_doc | stdio → local filesystem | Read-only /docs |
| planner | plan_current, plan_list, plan_complete, plan_block, plan_create, plan_update_task | stdio → HTTPS REST | Read/write plan state via plan-server |

### Two endpoints:

| Endpoint | Script | System prompt | Purpose |
| :--- | :--- | :--- | :--- |
| POST /ask | query.sh | SYSTEM_PROMPT | Execute code changes, follow active plan |
| POST /plan | plan.sh | PLAN_SYSTEM_PROMPT | Create plans only, no code execution |

### Request flow (/ask):
1. `query.sh` → POST https://localhost:8443/ask (Bearer CLAUDE_API_TOKEN)
2. Caddy → claude-server:8000/ask
3. FastAPI verifies Bearer token, then subprocess:
   `claude --print --dangerously-skip-permissions --output-format json --mcp-config .mcp.json --model <model> --system-prompt <prompt> -- <query>`
4. Claude Code calls plan_current → gets current task (if any)
5. Claude Code → mcp-watchdog → files_mcp.py → HTTPS REST → mcp-server:8443
6. Claude Code → mcp-watchdog → git_mcp.py → git subprocess
7. Claude Code → mcp-watchdog → plan_mcp.py → plan_complete → plan-server:8443
8. Claude Code → ANTHROPIC_BASE_URL=https://proxy:4000 → LiteLLM → Anthropic API

### Volume mounts on claude-server:

| Host path | Container path | Mode | Purpose |
| :--- | :--- | :--- | :--- |
| ./workspace (→ active sub-repo) | /workspace | ro | Worktree for git operations |
| ../.git/modules/cluster/\<sub-repo\> | /gitdir | rw | Git data for add/commit |
| active sub-repo/docs | /docs | ro | Project documentation |

### Volume mounts on mcp-server:

| Host path | Container path | Mode | Purpose |
| :--- | :--- | :--- | :--- |
| ./workspace (→ active sub-repo) | /workspace | rw | Go fileserver reads/writes code |
| /dev/null | /workspace/.git | ro | Shadows .git — structural hook prevention |

### Volume mounts on plan-server:

| Host path | Container path | Mode | Purpose |
| :--- | :--- | :--- | :--- |
| ../plans | /plans | rw | Plan state files (JSON) |

---

## Core Security Principles

Enforce boundaries structurally, never by filtering.

### Security layers:
1. Credential isolation — agent uses DYNAMIC_AGENT_KEY, never real ANTHROPIC_API_KEY
2. Network isolation — claude-server on int_net only, no direct internet
3. MCP security proxy — mcp-watchdog intercepts all JSON-RPC, blocks 40+ attack classes
4. Filesystem jail — os.OpenRoot at /workspace, traversal blocked at Go runtime level
5. Repo isolation — active sub-repo as /workspace; parent repo not visible
6. Git hook prevention — /dev/null shadow + separated gitdir + core.hooksPath=/dev/null
7. Git history protection — baseline commit floor at container startup
8. Plan isolation — plan-server has no access to /workspace, /gitdir, or secrets
9. Dual auth — CLAUDE_API_TOKEN for ingress, MCP_API_TOKEN for internal services
10. TLS everywhere — internal CA, all service-to-service over HTTPS
11. Startup isolation checks — every container validates before serving
12. MCP config as build artifact — .mcp.json baked into image
13. Non-root containers — UID 1000, cap_drop: ALL on proxy

### Token isolation matrix:

| Token | claude-server | proxy | mcp-server | plan-server | caddy |
| :--- | :--- | :--- | :--- | :--- | :--- |
| ANTHROPIC_API_KEY | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| DYNAMIC_AGENT_KEY | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| CLAUDE_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| MCP_API_TOKEN | ✓ required | ✗ forbidden | ✓ required | ✓ required | ✗ forbidden |

---

## Test Suite (test.sh)

1. Caddy config validation
2. Go unit tests (fileserver)
3. Python unit tests (claude server, MCP tools, isolation, git tools)
4. Python unit tests (planner server, planner MCP wrapper)
5. Security scans (govulncheck, pip-audit, hadolint, trivy, npm audit)
6. Docker build
7. Integration tests (MCP registration, plan-server health, auth, isolation)

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

Sub-repo specific implementation details:
- Agent: [docs/CONTEXT.md](../cluster/agent/docs/CONTEXT.md)
- Planner: [docs/CONTEXT.md](../cluster/planner/docs/CONTEXT.md)
