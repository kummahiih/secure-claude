# Secure Claude Code Cluster

A hardened, containerized environment for running Claude Code as an AI agent with access to local tools via the Model Context Protocol (MCP). Credentials are never exposed to the agent — a LiteLLM sidecar proxy holds the real API keys while the agent uses ephemeral tokens.

The agent supports a plan-then-execute workflow: create a structured plan with `plan.sh`, then execute tasks one at a time with `query.sh`. Planning task structure inspired by [get-shit-done](https://github.com/gsd-build/get-shit-done) (MIT).

## System Architecture

```
Host / Network
└─> Caddy:8443 (TLS 1.3 + reverse proxy)
     └─> claude-server:8000 (FastAPI + Claude Code)
          ├─> proxy:4000 (LiteLLM) ──> Anthropic API
          ├─> MCP stdio servers (inside claude-server)
          ├─> mcp-server:8443 (Go REST, filesystem jail)
          │    └─> /workspace (bind mount → active sub-repo)
          ├─> plan-server:8443 (Python REST, plan state)
          │    └─> /plans (bind mount → plans/)
          └─> tester-server:8443 (Go REST, test runner)
               └─> /workspace:ro (bind mount → active sub-repo)
```

Six containers orchestrated by Docker Compose. The `/workspace` mount is swappable — point it at any repo that follows the [workspace interface](docs/WORKSPACE_INTERFACE.md).

## Sub-Repositories

| Repository | Description | Docs |
| :--- | :--- | :--- |
| [secure-claude-agent](cluster/agent/) | MCP tool servers (files, git, docs, planner, tester wrappers) + Claude Code integration | [README](cluster/agent/README.md) |
| [secure-claude-planner](cluster/planner/) | Plan-server REST API for task state management | [README](cluster/planner/README.md) |
| [secure-claude-tester](cluster/tester/) | Tester-server REST API for running workspace tests | [README](cluster/tester/README.md) |

Each sub-repo contains its own `docs/CONTEXT.md` (architecture) and `docs/PLAN.md` (roadmap). See the [workspace interface spec](docs/WORKSPACE_INTERFACE.md) for the standardized structure.

## Project Structure

```
secure-claude/                          # This repo — orchestration, infrastructure
├── cluster/
│   ├── agent/                          ← submodule → secure-claude-agent
│   ├── planner/                        ← submodule → secure-claude-planner
│   ├── tester/                         ← submodule → secure-claude-tester
│   ├── workspace                       ← symlink → active sub-repo
│   ├── caddy/                          # Caddy reverse proxy config
│   ├── proxy/                          # LiteLLM proxy config
│   ├── docker-compose.yml
│   ├── Dockerfile.*                    # All container images
│   └── start-cluster.sh
├── docs/
│   ├── CONTEXT.md                      # Cluster architecture and security model
│   ├── WORKSPACE_INTERFACE.md          # Contract for mountable repos
│   └── PLAN.md                         # Overall development roadmap
├── plans/
│   └── *.json                          # Plan state files
├── run.sh                              # Generate certs, rotate tokens, start cluster
├── plan.sh                             # Create a plan (no code execution)
├── query.sh                            # Send a query to the agent
├── test.sh                             # Unit tests (offline, no Docker needed)
├── test-integration.sh                 # CVE audits, Docker builds, integration tests
└── logs.sh                             # Tail container logs
```

## Security Summary

Full security architecture in [docs/CONTEXT.md](docs/CONTEXT.md). Sub-repos document their own implementation details. The cluster-level guarantees are:

1. **Credential Isolation** — agent uses ephemeral DYNAMIC_AGENT_KEY, never real ANTHROPIC_API_KEY
2. **Network Isolation** — claude-server on int_net only, no direct internet access
3. **Filesystem Jail** — Go os.OpenRoot at /workspace, traversal blocked at runtime level
4. **Repo Isolation** — active sub-repo as /workspace; parent repo never visible
5. **Dual-Layer Auth** — CLAUDE_API_TOKEN for ingress, MCP_API_TOKEN for internal services
6. **TLS Everywhere** — internal CA, all service-to-service over HTTPS
7. **Non-Root Containers** — UID 1000, cap_drop: ALL on proxy
8. **MCP Security Proxy** — mcp-watchdog blocks 40+ attack classes on all JSON-RPC traffic
9. **Test Isolation** — tester-server runs tests as subprocesses with workspace mounted read-only


## Switching the Active Workspace

The workspace is a symlink at `cluster/workspace`. Docker Compose mounts it
via `./workspace`, so changing the symlink target is all that's needed — no
`docker-compose.yml` edits required.

To develop a different sub-repo:

```bash
cd cluster
ln -sfn planner workspace      # switch from agent to planner
```

Restart the cluster after switching. The target repo must follow the [workspace interface](docs/WORKSPACE_INTERFACE.md).


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

Copy the `sk-ant-oat01-...` token into `.secrets.env` as `ANTHROPIC_API_KEY`.

3. Initialize local test environment

```bash
./init_build.sh
```

4. Run unit tests (no Docker or secrets required)

```bash
./test.sh
```

5. Start the cluster

```bash
./run.sh
```

6. Create a plan and execute it

```bash
./plan.sh claude-sonnet-4-6 "add input validation to the read endpoint"
./query.sh claude-sonnet-4-6 "work on the current task"
```

7. Run tests via the agent

```bash
./query.sh claude-sonnet-4-6 "Use run_tests to start a test run, wait 30 seconds, then use get_test_results to check the outcome."
```

### Self-development: mounting secure-claude as its own workspace

To have the agent work on the parent repo itself, clone a separate working
copy and point the symlink at it:

```bash
# Create a working copy (separate from the live cluster source)
git clone --recurse-submodules https://github.com/kummahiih/secure-claude /path/to/secure-claude-work

# Point the workspace symlink at the working copy
cd /path/to/secure-claude/cluster
ln -sfn /path/to/secure-claude-work workspace
```

The working copy satisfies the workspace interface out of the box — it has
`test.sh`, `docs/CONTEXT.md`, `docs/PLAN.md`, and `README.md`. The tester-server
will execute the working copy's `test.sh` (unit tests only, no Docker or
secrets needed).

## Operational Commands

```bash
./run.sh                          # Start cluster (generates certs + tokens)
./plan.sh <model> "<goal>"        # Create a plan (no code execution)
./query.sh <model> "<query>"      # Send a query / execute a task
./logs.sh                         # Tail all container logs
./test.sh                         # Run unit tests (no Docker/network needed)
./test-integration.sh             # CVE audits + Docker integration tests
```

## Prerequisites

- Docker Engine with Compose V2
- Node.js 22+ (for claude login)
- openssl (for certificate generation)
- Python 3.12+ with venv (for local tests)

## Security & Quality Auditing

```bash
./test.sh                         # Unit tests — runnable from a fresh clone
./test-integration.sh             # Full security + integration suite
```

| Tool | Focus | Target |
| :--- | :--- | :--- |
| pytest | Unit tests | agent, planner |
| go test | Unit tests | agent/fileserver/, tester/ |
| pip-audit | CVE scanning | agent + planner requirements.txt |
| govulncheck | CVE scanning | agent/fileserver/ + tester/ Go modules |
| npm audit | CVE scanning | Claude Code JS dependencies |
| hadolint | Dockerfile linting | All Dockerfile.* |
| trivy | Misconfiguration | docker-compose.yml + images |

## Credits

Architecture inspired by [secure-coder](https://github.com/kummahiih/secure-coder) and [secure-mcp](https://github.com/kummahiih/secure-mcp).

MCP security provided by [mcp-watchdog](https://github.com/bountyyfi/mcp-watchdog) by Bountyy Oy.

Planning task structure inspired by [get-shit-done](https://github.com/gsd-build/get-shit-done) by TÂCHES (MIT).

Some of the code was produced using Google Gemini, some of it was done using Claude.