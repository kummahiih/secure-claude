# secure-claude: Project Context

## What This Is

A hardened, containerized environment for running Claude Code as an autonomous AI agent
with access to local tools via MCP. The agent never holds real credentials — a LiteLLM
sidecar proxy holds the real API keys while the agent uses ephemeral tokens.

Built by iteratively adapting two predecessor projects:
- secure-coder (https://github.com/kummahiih/secure-coder) — credential isolation via LiteLLM sidecar
- secure-mcp (https://github.com/kummahiih/secure-mcp) — MCP server with Go os.OpenRoot filesystem jail

Repos:
- Parent: https://github.com/kummahiih/secure-claude
- Agent submodule: https://github.com/kummahiih/secure-claude-agent

---

## Current Architecture

```
Host / Network
└─> Caddy:8443 (TLS 1.3 + Bearer auth)
     └─> claude-server:8000 (FastAPI + Claude Code subprocess)
          ├─> proxy:4000 (LiteLLM) ──> Anthropic API
          └─> mcp-server:8443 (Go REST, os.OpenRoot jail)
               └─> /workspace (bind mount → cluster/agent/)
```

### Four containers, all on internal Docker network (int_net):

| Service | Description |
| :--- | :--- |
| caddy-sidecar | TLS termination, external ingress, Bearer auth |
| claude-server | FastAPI + Claude Code CLI subprocess |
| proxy | LiteLLM gateway, holds real ANTHROPIC_API_KEY |
| mcp-server | Go REST server, os.OpenRoot jail at /workspace |

### Request flow:
1. `query.sh` → POST https://localhost:8443/ask (Bearer AGENT_API_TOKEN)
2. Caddy → claude-server:8000/ask
3. FastAPI → subprocess: `claude --print --dangerously-skip-permissions --output-format json --model <model> --system-prompt <prompt> <query>`
4. Claude Code → mcp-watchdog (stdio) → files_mcp.py (stdio MCP server) → HTTPS REST → mcp-server:8443
5. Claude Code → ANTHROPIC_BASE_URL=https://proxy:4000 → LiteLLM → Anthropic API

---

## Core Security Principles

The overarching principle throughout: **enforce boundaries structurally, never by filtering**.

Filtering (path checks, string matching, allowlists) is vulnerable to path traversal,
unicode tricks, symlink attacks, and encoding differences. Structural boundaries are not.

Examples of structural enforcement in this project:
- Go os.OpenRoot for filesystem jail (not path string checking)
- Separate Docker networks (not firewall rules)
- Mount boundaries for secrets isolation (not env var filtering)
- Git submodule repo for agent code isolation (not path filtering in git tools)
- mcp-watchdog as transparent proxy (not inline checks in tool code)

### Security layers in order:
1. Credential isolation — agent uses DYNAMIC_AGENT_KEY, never real ANTHROPIC_API_KEY
2. Network isolation — claude-server on int_net only, no direct internet
3. MCP security proxy — mcp-watchdog intercepts all JSON-RPC, blocks 40+ attack classes
4. Filesystem jail — os.OpenRoot at /workspace, traversal blocked at Go runtime level
5. Repo isolation — agent submodule mounted as /workspace; parent repo (Dockerfiles, certs, secrets) not visible
6. Dual auth — AGENT_API_TOKEN for ingress, MCP_API_TOKEN for internal service calls
7. TLS everywhere — internal CA, all service-to-service over HTTPS
8. Read-only agent config — .claude.json locked to 440 after startup
9. Non-root containers — UID 1000, cap_drop: ALL on proxy

---

## Repo Structure: Two-Repo Split

The project is split into two repos with a git submodule boundary.
This is a structural security boundary — the agent can only see and modify its own code.

### Parent repo: secure-claude

Orchestration, infrastructure, secrets. Never mounted into containers as /workspace.

```
secure-claude/
├── cluster/
│   ├── agent/                  ← git submodule → secure-claude-agent
│   │   ├── claude/
│   │   └── fileserver/
│   ├── caddy/
│   │   ├── Caddyfile
│   │   └── caddy_test.sh
│   ├── proxy/
│   │   ├── proxy_config.yaml
│   │   └── proxy_wrapper.py
│   ├── docker-compose.yml
│   ├── Dockerfile.caddy
│   ├── Dockerfile.claude
│   ├── Dockerfile.mcp
│   ├── Dockerfile.proxy
│   └── start-cluster.sh
├── docs/
│   ├── CONTEXT.md              ← this file
│   └── PLAN.md
├── init_build.sh
├── logs.sh
├── query.sh
├── run.sh
├── test.sh
├── .secrets.env                ← gitignored, real ANTHROPIC_API_KEY
├── .cluster_tokens.env         ← gitignored, generated ephemeral tokens
├── certs/                      ← gitignored, generated TLS certs
├── LICENSE
└── README.md
```

### Agent submodule: secure-claude-agent

Application code only. Mounted as /workspace. This is all the agent can see.

```
secure-claude-agent/
├── claude/
│   ├── server.py               # FastAPI + subprocess
│   ├── files_mcp.py            # MCP stdio server
│   ├── entrypoint.sh           # startup, MCP registration
│   ├── runenv.py               # env var validation
│   ├── setuplogging.py
│   ├── requirements.txt
│   ├── claude_tests.py         # FastAPI unit tests
│   └── files_mcp_test.py       # MCP tool unit tests
└── fileserver/
    ├── main.go                 # Go REST server
    ├── mcp_test.go
    └── go.mod
```

### Why this split:
- Parent repo holds Dockerfiles, certs, compose, secrets, host scripts — infrastructure the agent must not modify
- Agent repo holds application code — the only thing the agent needs to read, write, test, and commit
- Dockerfiles stay in parent repo because they need access to certs/ at build time (multi-stage signer)
- claude/ and fileserver/ are tightly coupled (files_mcp.py wraps Go REST endpoints) so they share one submodule
- Future MCP tools (git, test runner) will also go in the agent submodule for the same coupling reason

---

## Key Implementation Details

### claude-server container (Dockerfile.claude)
- Base: python:3.12-slim
- Node.js 22 installed via NodeSource for Claude Code CLI
- Multi-stage build: signer stage generates per-service TLS cert from internal CA
- /app locked to 550 after build — agent can't read server source
- /home/appuser/sandbox — empty cwd for Claude Code subprocess
- /home/appuser/.claude.json — MCP registration, locked to 440

### entrypoint.sh startup sequence:
1. `claude mcp add fileserver --scope user -- mcp-watchdog --verbose -- python /app/files_mcp.py`
2. Verify .claude.json was written
3. Lock .claude.json to 440
4. exec python /app/server.py

### server.py subprocess call:
```python
subprocess.run(
    ["claude", "--print", "--dangerously-skip-permissions",
     "--output-format", "json", "--model", request.model,
     "--system-prompt", "You have access to a workspace through MCP fileserver tools. Always use MCP tools to read, write, list and delete files. Never access the local filesystem directly.",
     request.query],
    capture_output=True,
    text=True,
    timeout=120,
    cwd="/home/appuser/sandbox",
    env={
        **os.environ,
        "CLAUDE_CONFIG_DIR": "/home/appuser",
        "HOME": "/home/appuser",
    }
)
```

### files_mcp.py — MCP stdio server
- Wraps Go REST endpoints via requests
- Tools: read_workspace_file, list_files, create_file, write_file, delete_file
- Errors raised as exceptions (FileNotFoundError, PermissionError, RuntimeError)
- call_tool returns CallToolResult with isError=True/False — proper MCP protocol error typing
- Never returns error strings as normal text responses

### MCP server (Go, main.go)
- Plain REST API: /read /write /create /remove /list
- NOT MCP protocol — it is a REST API that files_mcp.py wraps
- os.OpenRoot jail at /workspace
- Bearer token auth on every endpoint
- TLS with internal CA cert

### Authentication tokens:
- ANTHROPIC_API_KEY — real key, only in .secrets.env, only seen by proxy container
- DYNAMIC_AGENT_KEY — ephemeral, generated by run.sh, used by claude-server as its "API key" to proxy
- AGENT_API_TOKEN — ephemeral, generated by run.sh, validates ingress requests
- MCP_API_TOKEN — ephemeral, generated by run.sh, authenticates claude-server to mcp-server

---

## Test Suite (test.sh)

Runs in order:
1. Caddy config validation (caddy_test.sh)
2. Go unit tests (go test)
3. Python unit tests (pytest claude_tests.py files_mcp_test.py)
4. pip-audit (Python CVE scan)
5. govulncheck (Go CVE scan)
6. hadolint (Dockerfile linting)
7. trivy (docker-compose misconfiguration scan)
8. docker compose build
9. Integration: start cluster, check MCP registration, check MCP health
10. Integration: auth failure check (expect 401 with wrong token)
11. Integration: success check (expect 200 with correct token)
12. docker compose down

---

## What Works

- Full query loop: query.sh → Caddy → FastAPI → Claude Code → mcp-watchdog → files_mcp.py → Go REST → /workspace
- Claude Code reads/writes/lists/deletes files in /workspace exclusively via MCP tools
- mcp-watchdog intercepts all JSON-RPC traffic as security proxy
- Credential isolation confirmed: agent never sees real ANTHROPIC_API_KEY
- Repo isolation confirmed: agent submodule contains only application code, no secrets or infrastructure
- TLS working on all internal connections
- Token auth working on ingress and MCP endpoints
- Unit tests passing for FastAPI server and MCP tools
- Pro subscription OAuth token works as ANTHROPIC_API_KEY (sk-ant-oat01-...)

---

## Decisions Log

| Decision | Chosen | Rejected | Reason |
| :--- | :--- | :--- | :--- |
| Agent framework | Claude Code CLI subprocess | LangChain | Simpler, no orchestration overhead |
| MCP transport | stdio (files_mcp.py) | HTTP direct to Go server | Go server is REST not MCP protocol |
| MCP error typing | CallToolResult isError=True | Return error strings | Ambiguous to mix errors and content in same type |
| Git isolation | Submodule repo | Path filtering | Path filtering vulnerable to traversal attacks |
| Submodule count | Single submodule (agent) | Multiple (agent, mcp, tools) | claude/ and fileserver/ are tightly coupled; future tools share same coupling |
| Dockerfile location | Parent repo (cluster/) | Inside submodule | Dockerfiles need certs/ at build time; also keeps agent from modifying its own container |
| Test isolation | Per-language containers | Shared test runner | Mount boundary enforces scope structurally |
| Config locking | chmod 440 on .claude.json | Directory chmod 550 | Directory lock prevents Claude Code writing session state |
| Credential flow | OAuth token (sk-ant-oat01-) | API key | Pro subscription, no per-token billing |
