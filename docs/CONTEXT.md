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
└─> Caddy:8443 (TLS 1.3 + reverse proxy)
     └─> claude-server:8000 (FastAPI + Claude Code subprocess)
          ├─> proxy:4000 (LiteLLM) ──> Anthropic API
          └─> mcp-server:8443 (Go REST, os.OpenRoot jail)
               └─> /workspace (bind mount → cluster/agent/)
```

### Four containers, all on internal Docker network (int_net):

| Service | Description | Isolation checks |
| :--- | :--- | :--- |
| caddy-sidecar | TLS termination, external ingress, reverse proxy | caddy_entrypoint.sh |
| claude-server | FastAPI + Claude Code CLI subprocess | verify_isolation.py (26 checks) |
| proxy | LiteLLM gateway, holds real ANTHROPIC_API_KEY | proxy_wrapper.py (4 checks) |
| mcp-server | Go REST server, os.OpenRoot jail at /workspace | entrypoint.sh (env + .env scan) |

### Request flow:
1. `query.sh` → POST https://localhost:8443/ask (Bearer CLAUDE_API_TOKEN)
2. Caddy → claude-server:8000/ask
3. FastAPI verifies Bearer token, then subprocess:
   `claude --print --dangerously-skip-permissions --output-format json --mcp-config /home/appuser/sandbox/.mcp.json --model <model> --system-prompt <prompt> -- <query>`
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
- Runtime isolation checks that fail-hard at startup (not runtime filtering)

### Security layers in order:
1. Credential isolation — agent uses DYNAMIC_AGENT_KEY, never real ANTHROPIC_API_KEY
2. Network isolation — claude-server on int_net only, no direct internet
3. MCP security proxy — mcp-watchdog intercepts all JSON-RPC, blocks 40+ attack classes
4. Filesystem jail — os.OpenRoot at /workspace, traversal blocked at Go runtime level
5. Repo isolation — agent submodule mounted as /workspace; parent repo (Dockerfiles, certs, secrets) not visible
6. Dual auth — CLAUDE_API_TOKEN for ingress, MCP_API_TOKEN for internal service calls
7. TLS everywhere — internal CA, all service-to-service over HTTPS
8. Startup isolation checks — every container validates env vars, forbidden paths, .env file absence
9. MCP config as build artifact — .mcp.json baked into image, passed via --mcp-config flag
10. Non-root containers — UID 1000, cap_drop: ALL on proxy
11. Claude Code version pinned — @2.1.74, no surprise breakage on rebuild

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
│   │   ├── caddy_entrypoint.sh # Isolation checks + exec caddy
│   │   ├── Caddyfile
│   │   └── caddy_test.sh
│   ├── proxy/
│   │   ├── proxy_config.yaml
│   │   └── proxy_wrapper.py    # Isolation checks + LiteLLM startup
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
│   ├── files_mcp.py            # MCP stdio server (wraps Go REST)
│   ├── entrypoint.sh           # Isolation check + exec server.py
│   ├── runenv.py               # Env var validation + SYSTEM_PROMPT
│   ├── verify_isolation.py     # Runtime isolation checks (all 4 roles)
│   ├── test_isolation.py       # Unit tests for isolation checks
│   ├── setuplogging.py
│   ├── requirements.txt
│   ├── claude_tests.py         # FastAPI unit tests
│   └── files_mcp_test.py       # MCP tool unit tests
└── fileserver/
    ├── main.go                 # Go REST server
    ├── entrypoint.sh           # Isolation check + exec mcp-server
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
- Claude Code pinned: @anthropic-ai/claude-code@2.1.74
- Multi-stage build: signer stage generates per-service TLS cert from internal CA
- /app locked to 550 after build — agent can't read server source
- /home/appuser/sandbox — empty cwd for Claude Code subprocess, chmod 500
- /home/appuser/sandbox/.mcp.json — MCP config baked into image at build time

### entrypoint.sh startup sequence:
1. Run `verify_isolation.py claude-server` — exits non-zero on any violation
2. `exec python /app/server.py`

MCP config is no longer registered at runtime. The .mcp.json file is written during
`docker build` and passed to Claude Code via the `--mcp-config` flag.

### server.py subprocess call:
```python
subprocess.run(
    ["claude", "--print", "--dangerously-skip-permissions",
     "--output-format", "json",
     "--mcp-config", "/home/appuser/sandbox/.mcp.json",
     "--model", request.model,
     "--system-prompt", SYSTEM_PROMPT,
     "--", request.query],
    capture_output=True,
    text=True,
    timeout=120,
    cwd="/home/appuser/sandbox",
    env={
        **os.environ,
        "CLAUDE_CONFIG_DIR": "/home/appuser",
        "HOME": "/home/appuser",
        "ANTHROPIC_API_KEY": DYNAMIC_AGENT_KEY,
    }
)
```

Key details:
- DYNAMIC_AGENT_KEY is renamed to ANTHROPIC_API_KEY only in the subprocess scope
- `--mcp-config` explicitly loads MCP servers (Claude Code --print mode doesn't auto-discover config)
- `--` separates flags from the query (--mcp-config is variadic)
- SYSTEM_PROMPT is defined in runenv.py as a shared constant

### files_mcp.py — MCP stdio server
- Wraps Go REST endpoints via requests
- Tools: read_workspace_file, list_files, create_file, write_file, delete_file
- Errors raised as exceptions (FileNotFoundError, PermissionError, RuntimeError)
- call_tool returns CallToolResult with isError=True/False — proper MCP protocol error typing
- Never returns error strings as normal text responses
- Does NOT run verify_isolation.py — Claude Code passes ANTHROPIC_API_KEY to child processes, which would false-positive

### MCP server (Go, main.go)
- Plain REST API: /read /write /create /remove /list
- NOT MCP protocol — it is a REST API that files_mcp.py wraps
- os.OpenRoot jail at /workspace
- Bearer token auth on every endpoint
- TLS with internal CA cert
- entrypoint.sh checks: no ANTHROPIC_API_KEY, no CLAUDE_API_TOKEN, no DYNAMIC_AGENT_KEY, requires MCP_API_TOKEN

### Authentication tokens:
- ANTHROPIC_API_KEY — real key, only in .secrets.env, only seen by proxy container
- DYNAMIC_AGENT_KEY — ephemeral, generated by run.sh, passed to claude-server and proxy
  - claude-server renames it to ANTHROPIC_API_KEY in subprocess scope only
  - proxy uses it as the virtual key for LiteLLM validation
- CLAUDE_API_TOKEN — ephemeral, generated by run.sh, validates ingress requests at FastAPI level
- MCP_API_TOKEN — ephemeral, generated by run.sh, authenticates claude-server to mcp-server

### Token isolation matrix:

| Token | claude-server | proxy | mcp-server | caddy |
| :--- | :--- | :--- | :--- | :--- |
| ANTHROPIC_API_KEY | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden |
| DYNAMIC_AGENT_KEY | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden |
| CLAUDE_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| MCP_API_TOKEN | ✓ required | ✗ forbidden | ✓ required | ✗ forbidden |

---

## Isolation Checks (verify_isolation.py)

Runtime checks that run at container startup. Fail hard (sys.exit(1)) on any violation.

### What each role checks:
- **Forbidden env vars** — tokens that should never be in this container
- **Required env vars** — tokens this container needs to function
- **Forbidden paths** — secrets, parent repo artifacts, cross-container code
- **Required paths** — expected files that confirm correct image build
- **.env file scan** — walks directories looking for any .env files
- **Workspace whitelist** (mcp-server only) — /workspace must contain only agent code
- **.git parent leak** (mcp-server only) — submodule .git must not point outside /workspace
- **MCP config validation** (claude-server only) — .mcp.json must exist with correct structure

### Important: never call from MCP subprocess children
verify_isolation.py must only run at entrypoint/daemon level. Claude Code passes
ANTHROPIC_API_KEY to its child processes (MCP servers), which would false-positive
the forbidden env var check.

---

## Test Suite (test.sh)

Runs in order:
1. Caddy config validation (caddy_test.sh)
2. Go unit tests (go test)
3. Python unit tests (pytest claude_tests.py files_mcp_test.py test_isolation.py)
4. Pre-build security scans (govulncheck, pip-audit, hadolint, trivy)
5. Docker build (--quiet)
6. Post-build security scans (npm audit — lockfile generated from built image, audited on host)
7. Integration: start cluster, check .mcp.json, check MCP fileserver logs for errors
8. Integration: auth failure check (expect 401 with wrong token)
9. Teardown

### logs.sh

Tails all container logs plus Claude Code's internal MCP fileserver logs from
`/home/appuser/.cache/claude-cli-nodejs/*/mcp-logs-fileserver/`. These logs are
where MCP server startup failures appear (not in docker-compose logs).

---

## What Works

- Full query loop: query.sh → Caddy → FastAPI → Claude Code → mcp-watchdog → files_mcp.py → Go REST → /workspace
- Claude Code reads/writes/lists/deletes files in /workspace exclusively via MCP tools
- MCP config passed explicitly via --mcp-config flag (no auto-discovery dependency)
- mcp-watchdog intercepts all JSON-RPC traffic as security proxy
- Credential isolation confirmed: agent never sees real ANTHROPIC_API_KEY
- DYNAMIC_AGENT_KEY renamed to ANTHROPIC_API_KEY only in subprocess scope
- Repo isolation confirmed: agent submodule contains only application code, no secrets or infrastructure
- TLS working on all internal connections
- Token auth working on ingress and MCP endpoints
- Runtime isolation checks on all 4 containers (startup fail-hard)
- Unit tests passing for FastAPI server, MCP tools, and isolation checks
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
| Credential flow | OAuth token (sk-ant-oat01-) | API key | Pro subscription, no per-token billing |
| MCP config delivery | --mcp-config flag + build-time .mcp.json | claude mcp add at runtime | --print mode doesn't auto-discover config; claude mcp add writes to unpredictable locations across versions |
| Config locking | .mcp.json read-only in locked sandbox (500) | chmod 440 on .claude.json | .claude.json needs write access for Claude Code session state; separate .mcp.json avoids conflict |
| Claude Code version | Pinned @2.1.74 | Latest | Config resolution, MCP loading, and flag behavior change between versions |
| Credential rename | DYNAMIC_AGENT_KEY in env, renamed in subprocess | ANTHROPIC_API_KEY in env | Allows isolation check to detect real key leaks; rename scoped to subprocess only |
| System prompt location | Shared constant in runenv.py | Hardcoded in server.py | Single source of truth; tests reference same constant |
| Isolation check scope | Entrypoint only, never in MCP children | All processes | Claude Code passes ANTHROPIC_API_KEY to child MCP servers, causing false positives |
