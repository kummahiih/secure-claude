# Secure Claude Code Cluster

A hardened, containerized environment for running Claude Code as an AI agent with access to local tools via the Model Context Protocol (MCP). Credentials are never exposed to the agent — a LiteLLM sidecar proxy holds the real API keys while the agent uses ephemeral tokens.

The agent supports a plan-then-execute workflow: create a structured plan with `plan.sh`, then execute tasks one at a time with `query.sh`. Planning task structure inspired by [get-shit-done](https://github.com/gsd-build/get-shit-done) (MIT).

## System Architecture

```
Host / Network
└─> Caddy:8443 (TLS 1.3 + reverse proxy)
     └─> claude-server:8000 (FastAPI + Claude Code)
          ├─> proxy:4000 (LiteLLM) ──> Anthropic API
          ├─> MCP stdio servers (inside claude-server):
          │    ├─> files_mcp.py → HTTPS REST → mcp-server:8443
          │    ├─> git_mcp.py   → git subprocess (/gitdir)
          │    ├─> docs_mcp.py  → local read (/docs)
          │    └─> plan_mcp.py  → HTTPS REST → plan-server:8443
          ├─> mcp-server:8443 (Go REST, os.OpenRoot jail)
          │    └─> /workspace (bind mount → cluster/agent/)
          └─> plan-server:8443 (Python REST, JSON plan files)
               └─> /plans (bind mount → plans/)
```

### Service Roles

| Service | Image | Network(s) | Description |
| :--- | :--- | :--- | :--- |
| caddy-sidecar | Dockerfile.caddy | ext_net, int_net | TLS termination & reverse proxy |
| claude-server | Dockerfile.claude | int_net | FastAPI + Claude Code agent + 4 MCP stdio servers |
| proxy | Dockerfile.proxy | ext_net, int_net | LiteLLM gateway to Anthropic |
| mcp-server | Dockerfile.mcp | int_net | Go filesystem tool server |
| plan-server | Dockerfile.plan | int_net | Plan state management server |

### MCP Tool Sets

The agent has access to four tool sets via MCP, all wrapped by mcp-watchdog:

| Tool Set | Tools | Purpose |
| :--- | :--- | :--- |
| **fileserver** | read, list, create, write, delete | File operations in /workspace via Go REST server |
| **git** | status, diff, add, commit, log, reset_soft | Git operations with hook prevention and history protection |
| **docs** | list_docs, read_doc | Read-only access to project documentation |
| **planner** | plan_current, plan_list, plan_complete, plan_block, plan_create, plan_update_task | Task planning and progress tracking |

---

## Two Workflows

### Direct execution

```bash
./query.sh claude-sonnet-4-6 "create a file called hello.py with a hello world function"
```

### Plan-then-execute (recommended for multi-step changes)

```bash
# 1. Create a plan (Claude reads docs, produces structured tasks, no code)
./plan.sh claude-sonnet-4-6 "add input validation to the read endpoint in the Go fileserver"

# 2. Review the plan
cat plans/plan-*.json | python3 -m json.tool

# 3. Execute tasks one at a time
./query.sh claude-sonnet-4-6 "work on the current task"
# Repeat for each task — Claude advances automatically
```

---

## Security Guardrails

1. **Credential Isolation** — agent uses ephemeral DYNAMIC_AGENT_KEY, never real ANTHROPIC_API_KEY
2. **Runtime Isolation Checks** — every container fails hard at startup on any security violation
3. **MCP Security Proxy** — mcp-watchdog blocks 40+ attack classes on all JSON-RPC traffic
4. **Filesystem Jail** — Go os.OpenRoot at /workspace, traversal blocked at runtime level
5. **Git Hook Prevention** — 3 structural layers: /dev/null shadow, separated gitdir, core.hooksPath
6. **Git History Protection** — baseline commit floor prevents erasing pre-existing history
7. **Network Isolation** — agent on int_net only, no direct internet access
8. **Repo Isolation** — agent submodule as /workspace; parent repo never visible
9. **Dual-Layer Auth** — CLAUDE_API_TOKEN for ingress, MCP_API_TOKEN for internal services
10. **TLS Everywhere** — internal CA, all service-to-service over HTTPS
11. **MCP Config as Build Artifact** — .mcp.json baked into image, agent can't modify tool registrations
12. **Non-Root Containers** — UID 1000, cap_drop: ALL on proxy
13. **Plan Isolation** — plan-server has no access to /workspace, /gitdir, or secrets

See [docs/CONTEXT.md](docs/CONTEXT.md) for detailed architecture and security model.

---

## Project Structure

The project uses three repos with git submodule boundaries.

```
secure-claude/                          # Parent repo — orchestration, infrastructure
├── cluster/
│   ├── agent/                          ← submodule → secure-claude-agent
│   ├── planner/                        ← submodule → secure-claude-planner
│   ├── workspace                       ← symlink → agent/
│   ├── caddy/                          # Caddy reverse proxy config
│   ├── proxy/                          # LiteLLM proxy config
│   ├── docker-compose.yml
│   ├── Dockerfile.caddy
│   ├── Dockerfile.claude
│   ├── Dockerfile.mcp
│   ├── Dockerfile.plan
│   ├── Dockerfile.proxy
│   └── start-cluster.sh
├── docs/
│   ├── CONTEXT.md                      # Architecture and security model
│   └── PLAN.md                         # Development roadmap
├── plans/                              # Plan state files (JSON)
├── run.sh                              # Generate certs, rotate tokens, start cluster
├── plan.sh                             # Create a plan (no code execution)
├── query.sh                            # Send a query to the agent
├── test.sh                             # Full test suite
└── logs.sh                             # Tail container logs
```

---

## Prerequisites

- Docker Engine with Compose V2
- Node.js 22+ (for claude login)
- openssl (for certificate generation)
- Python 3.12+ with venv (for local tests)

---

## Quick Start

1. Clone with submodules

```bash
git clone --recurse-submodules https://github.com/kummahiih/secure-claude
cd secure-claude
cp .secrets.env.example .secrets.env
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init
```

2. Add your Anthropic API key to .secrets.env

```bash
ANTHROPIC_API_KEY=sk-ant-...
```

To use a Pro subscription OAuth token instead of a paid API key:

```bash
npm install -g @anthropic-ai/claude-code
claude login
claude setup-token
```

Copy the sk-ant-oat01-... token into .secrets.env as ANTHROPIC_API_KEY.

3. Initialize local test environment

```bash
./init_build.sh
```

4. Start the cluster

```bash
./run.sh
```

5. Create a plan and execute it

```bash
./plan.sh claude-sonnet-4-6 "add input validation to the read endpoint"
./query.sh claude-sonnet-4-6 "work on the current task"
```

---

## Operational Commands

```bash
./run.sh                          # Start cluster (generates certs + tokens)
./plan.sh <model> "<goal>"        # Create a plan (no code execution)
./query.sh <model> "<query>"      # Send a query / execute a task
./logs.sh                         # Tail all container logs
./test.sh                         # Run full test suite
```

---

## Security & Quality Auditing

```bash
./test.sh
```

| Tool | Focus | Target |
| :--- | :--- | :--- |
| pytest | Unit tests | agent/claude/, planner/planner/ |
| go test | Unit tests | agent/fileserver/ |
| pip-audit | CVE scanning | agent + planner requirements.txt |
| govulncheck | CVE scanning | agent/fileserver/ Go modules |
| npm audit | CVE scanning | Claude Code JS dependencies |
| hadolint | Dockerfile linting | All Dockerfile.* |
| trivy | Misconfiguration | docker-compose.yml + images |

---

## Development Status

See [docs/PLAN.md](docs/PLAN.md) for the development roadmap.

- **Phase 1** ✅ Git submodule split + isolation verification
- **Phase 2** ✅ Git MCP tools + docs access + hook prevention
- **Phase 2.5** ✅ Planning tool (plan-server + plan_mcp.py)
- **Phase 3** 🔲 Test runner MCP tool
- **Phase 4** 🔲 Close the agentic loop (self-developing cycle)
- **Phase 5** 🔲 Hardening and polish

---

## Credits

Architecture inspired by [secure-coder](https://github.com/kummahiih/secure-coder) and [secure-mcp](https://github.com/kummahiih/secure-mcp).

MCP security provided by [mcp-watchdog](https://github.com/bountyyfi/mcp-watchdog) by Bountyy Oy.

Planning task structure inspired by [get-shit-done](https://github.com/gsd-build/get-shit-done) by TÂCHES (MIT).

Some of the code was produced using Google Gemini, some of it was done using Claude.
