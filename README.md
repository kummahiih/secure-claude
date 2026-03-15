# Secure Claude Code Cluster

A hardened, containerized environment for running Claude Code as an AI agent with access to local tools via the Model Context Protocol (MCP). Credentials are never exposed to the agent - a LiteLLM sidecar proxy holds the real API keys while the agent uses ephemeral tokens.

## System Architecture

```
Host / Network
└─> Caddy:8443 (TLS 1.3 + reverse proxy)
     └─> claude-server:8000 (FastAPI + Claude Code)
          ├─> proxy:4000 (LiteLLM) ──> Anthropic API
          └─> mcp-server:8443 (Go REST, os.OpenRoot jail)
               └─> /workspace (bind mount → cluster/agent/)
```

### Service Roles

| Service | Image | Network(s) | Port | Description |
| :--- | :--- | :--- | :--- | :--- |
| caddy-sidecar | Dockerfile.caddy | ext_net, int_net | 8443 | TLS termination & reverse proxy |
| claude-server | Dockerfile.claude | int_net | - | FastAPI + Claude Code agent |
| proxy | Dockerfile.proxy | ext_net, int_net | - | LiteLLM gateway to Anthropic |
| mcp-server | Dockerfile.mcp | int_net | - | Go filesystem tool server |

---

## Security Guardrails

### 1. Credential Isolation
The agent container never holds real API keys. It receives an ephemeral DYNAMIC_AGENT_KEY which is renamed to ANTHROPIC_API_KEY only within the Claude Code subprocess scope. The LiteLLM proxy holds the real ANTHROPIC_API_KEY in memory only.

### 2. Runtime Isolation Checks
Every container runs startup isolation checks that fail hard (exit 1) before serving any traffic. These verify that forbidden env vars are absent, required env vars are present, no .env files leaked into the image, and no parent repo artifacts are visible. See the token isolation matrix in docs/CONTEXT.md.

### 3. MCP Security Proxy
All JSON-RPC traffic between Claude Code and the MCP fileserver passes through mcp-watchdog (https://github.com/bountyyfi/mcp-watchdog), which detects and blocks prompt injection, rug pulls, tool poisoning, SSRF, command injection, token leakage, and 40+ other attack classes before they reach the model.

### 4. Filesystem Jail
The Go MCP server uses os.OpenRoot to jail all file operations to /workspace. Directory traversal attacks (e.g. ../../etc/passwd) are blocked at the Go runtime level.

### 5. Network Isolation
The agent runs on int_net only - an internal Docker bridge with no internet access. Only the LiteLLM proxy and Caddy have ext_net access for outbound API calls and inbound queries respectively.

### 6. Repo Isolation
Agent source code lives in a separate git submodule (secure-claude-agent) mounted as /workspace. The parent repo containing Dockerfiles, certificates, secrets, and infrastructure config is never visible to the agent. This is a structural boundary, not path filtering.

### 7. Dual-Layer Authentication
- Ingress: FastAPI validates CLAUDE_API_TOKEN on every request
- Internal: Claude Code authenticates to the MCP server with a separate MCP_API_TOKEN

### 8. TLS Everywhere
All internal service-to-service communication uses HTTPS with a shared internal CA. No plaintext traffic on any network and server identity should be strong.

### 9. MCP Config as Build Artifact
The MCP server configuration (.mcp.json) is baked into the image at build time and passed to Claude Code via the --mcp-config flag. The agent cannot modify its own tool registrations. Claude Code version is pinned to prevent config resolution changes across versions.

### 10. Non-Root Containers
All containers run as non-root users (UID 1000). cap_drop: ALL is set on the proxy container.

---

## Project Structure

The project is split across two repos with a git submodule boundary.

### Parent repo: secure-claude

Orchestration, infrastructure, secrets. Never mounted into containers as /workspace.

```
.
├── cluster/
│   ├── agent/                      ← git submodule → secure-claude-agent
│   │   ├── claude/
│   │   │   ├── server.py           # FastAPI server, Claude Code subprocess
│   │   │   ├── files_mcp.py        # MCP stdio server wrapping Go REST API
│   │   │   ├── entrypoint.sh       # Isolation check + starts server
│   │   │   ├── runenv.py           # Env var validation + SYSTEM_PROMPT
│   │   │   ├── verify_isolation.py # Runtime isolation checks (all 4 roles)
│   │   │   ├── test_isolation.py   # Unit tests for isolation checks
│   │   │   ├── setuplogging.py     # Logging configuration
│   │   │   ├── requirements.txt    # Python dependencies
│   │   │   ├── claude_tests.py     # FastAPI unit tests
│   │   │   └── files_mcp_test.py   # MCP tool unit tests
│   │   └── fileserver/
│   │       ├── main.go             # Go MCP REST server with os.OpenRoot jail
│   │       ├── entrypoint.sh       # Isolation check + starts Go server
│   │       ├── mcp_test.go         # Go unit tests
│   │       └── go.mod              # Go module dependencies
│   ├── caddy/
│   │   ├── caddy_entrypoint.sh     # Isolation check + starts Caddy
│   │   ├── Caddyfile               # TLS and reverse proxy config
│   │   └── caddy_test.sh           # Caddy validation script
│   ├── proxy/
│   │   ├── proxy_config.yaml       # LiteLLM model routing config
│   │   └── proxy_wrapper.py        # Isolation check + LiteLLM startup
│   ├── docker-compose.yml          # Service orchestration
│   ├── Dockerfile.caddy
│   ├── Dockerfile.claude
│   ├── Dockerfile.mcp
│   ├── Dockerfile.proxy
│   └── start-cluster.sh            # Starts all containers
├── docs/
│   ├── CONTEXT.md                  # Detailed architecture and design decisions
│   └── PLAN.md                     # Development roadmap
├── init_build.sh                   # Creates venv and installs test dependencies
├── run.sh                          # Generates certs, rotates tokens, starts cluster
├── query.sh                        # CLI utility for sending queries to the agent
├── test.sh                         # Full test suite (unit + security + integration)
└── logs.sh                         # Tails all container logs
```

### Agent submodule: secure-claude-agent

Application code only. Mounted as /workspace. This is all the agent can see.

```
secure-claude-agent/
├── claude/                         # Python: FastAPI server + MCP tools + isolation checks
└── fileserver/                     # Go: REST file server with os.OpenRoot jail
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

This generates internal TLS certificates, rotates all tokens, and starts all four containers.

5. Send a query

```bash
./query.sh claude-sonnet-4-6 "list the files in my workspace"
./query.sh claude-sonnet-4-6 "create a file called hello.py with a hello world function"
./query.sh claude-sonnet-4-6 "read hello.py"
```

---

## Operational Commands

```bash
./run.sh                          # Start cluster (generates certs + tokens on first run)
./query.sh <model> "<query>"      # Send a query to the agent
./logs.sh                         # Tail all container logs
./test.sh                         # Run full test suite
```

---

## Security & Quality Auditing

The full test suite runs automatically with ./test.sh and covers:

| Tool | Focus | Target |
| :--- | :--- | :--- |
| pytest | Unit tests | agent/claude/ Python server, MCP tools, isolation checks |
| go test | Unit tests | agent/fileserver/ Go MCP server |
| pip-audit | CVE scanning | agent/claude/requirements.txt |
| govulncheck | CVE scanning | agent/fileserver/ Go modules |
| npm audit | CVE scanning | Claude Code JS dependencies (post-build) |
| hadolint | Dockerfile linting | All Dockerfile.* |
| trivy | Misconfiguration | docker-compose.yml + images |

```bash
./test.sh
```

---

## Adding Workspace Files

Mount your project directory into the workspace before starting:

```bash
mkdir -p cluster/workspace
sudo mount --bind /your/project cluster/workspace
./run.sh
```

Or edit docker-compose.yml to point the mcp-server workspace volume at your project:

```yaml
volumes:
  - /your/project:/workspace
```

---

## Credits

Architecture inspired by secure-coder (https://github.com/kummahiih/secure-coder) and secure-mcp (https://github.com/kummahiih/secure-mcp).

MCP security provided by mcp-watchdog (https://github.com/bountyyfi/mcp-watchdog) by Bountyy Oy.

Some of the code was produced using Google Gemini, some of it was done using Claude.
