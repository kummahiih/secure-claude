# secure-claude: Project Context

## What This Is

A hardened, containerized environment for running Claude Code as an autonomous AI agent
with access to local tools via MCP. The agent never holds real credentials — a LiteLLM
sidecar proxy holds the real API keys while the agent uses ephemeral tokens.

The agent supports a plan-then-execute workflow: structured plans are created via
`plan.sh`, then executed task-by-task via `query.sh`.

Repos:
- Parent: https://github.com/kummahiih/secure-claude
- Agent submodule: https://github.com/kummahiih/secure-claude-agent
- Planner submodule: https://github.com/kummahiih/secure-claude-planner

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
          │    └─> /workspace (bind mount → cluster/agent/)
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
| ./workspace (→ ./agent) | /workspace | ro | Worktree for git operations |
| ../.git/modules/cluster/agent | /gitdir | rw | Git data for add/commit |
| ../docs | /docs | ro | Project documentation |

### Volume mounts on mcp-server:

| Host path | Container path | Mode | Purpose |
| :--- | :--- | :--- | :--- |
| ./workspace (→ ./agent) | /workspace | rw | Go fileserver reads/writes agent code |
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
5. Repo isolation — agent submodule as /workspace; parent repo not visible
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

## Planning Tool

### JSON task format

Plans are JSON files in `plans/`. Each plan has a goal and 2-10 tasks:

```json
{
  "id": "plan-20260317-120000",
  "goal": "Add input validation to /read endpoint",
  "status": "in_progress",
  "tasks": [
    {
      "id": "t1",
      "name": "Add validation to handler",
      "files": ["fileserver/main.go"],
      "action": "Add three guard clauses before filesystem call...",
      "verify": "go build ./... compiles clean",
      "done": "Handler has all three guard clauses",
      "status": "current"
    }
  ]
}
```

Task statuses: pending → current → completed (or blocked).
One current task at a time. Completing advances the next pending task.

### Plan file naming

`plan-YYYY-MM-DD-<5-char-hmac>.json` — HMAC derived from plan ID and MCP_API_TOKEN.

### System prompt behavior

- `/plan` endpoint: Claude reads docs, creates plan via plan_create. No code execution.
- `/ask` endpoint: Claude calls plan_current first. If a task exists, works on it, then calls plan_complete. If no plan, proceeds normally.
- API contract protection: system prompt instructs Claude not to change existing interfaces unless explicitly required.

---

## Key Implementation Details

### claude-server subprocess call:
```python
subprocess.run(
    ["claude", "--print", "--dangerously-skip-permissions",
     "--output-format", "json",
     "--mcp-config", "/home/appuser/sandbox/.mcp.json",
     "--model", request.model,
     "--system-prompt", SYSTEM_PROMPT,
     "--", request.query],
    timeout=300,
    env={..., "ANTHROPIC_API_KEY": DYNAMIC_AGENT_KEY}
)
```

### Git hook prevention (3 layers):
1. mcp-server: /dev/null shadow on .git — fileserver can't see git data
2. claude-server: gitdir at /gitdir — fileserver MCP can't reach hooks
3. git_mcp.py: core.hooksPath=/dev/null + --no-verify on every call

### Isolation checks (verify_isolation.py):
- Runs at container startup only, never in MCP subprocess children
- Claude Code passes ANTHROPIC_API_KEY to children, which would false-positive

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
