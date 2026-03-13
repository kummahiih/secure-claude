# Secure Claude Code Cluster

A hardened, containerized environment for running Claude Code as an AI agent with access to local tools via the Model Context Protocol (MCP). Credentials are never exposed to the agent - a LiteLLM sidecar proxy holds the real API keys while the agent uses ephemeral tokens.

## System Architecture

```
Host / Network
└─> Caddy:8443 (TLS 1.3 + Bearer auth)
     └─> claude-server:8000 (FastAPI + Claude Code)
          ├─> proxy:4000 (LiteLLM) ──> Anthropic API
          └─> mcp-server:8443 (Go REST, os.OpenRoot jail)
               └─> /workspace (bind mount)
```

### Service Roles

| Service | Image | Network(s) | Port | Description |
| :--- | :--- | :--- | :--- | :--- |
| caddy-sidecar | Dockerfile.caddy | ext_net, int_net | 8443 | TLS termination & external ingress |
| claude-server | Dockerfile.claude | int_net | - | FastAPI + Claude Code agent |
| proxy | Dockerfile.proxy | ext_net, int_net | - | LiteLLM gateway to Anthropic |
| mcp-server | Dockerfile.mcp | int_net | - | Go filesystem tool server |

---

## Security Guardrails

### 1. Credential Isolation
The agent container never holds real API keys. It authenticates with an ephemeral DYNAMIC_AGENT_KEY to the LiteLLM proxy, which holds the real ANTHROPIC_API_KEY in memory only.

### 2. MCP Security Proxy
All JSON-RPC traffic between Claude Code and the MCP fileserver passes through mcp-watchdog (https://github.com/bountyyfi/mcp-watchdog), which detects and blocks prompt injection, rug pulls, tool poisoning, SSRF, command injection, token leakage, and 40+ other attack classes before they reach the model.

### 3. Filesystem Jail
The Go MCP server uses os.OpenRoot to jail all file operations to /workspace. Directory traversal attacks (e.g. ../../etc/passwd) are blocked at the Go runtime level.

### 4. Network Isolation
The agent runs on int_net only - an internal Docker bridge with no internet access. Only the LiteLLM proxy and Caddy have ext_net access for outbound API calls and inbound queries respectively.

### 5. Dual-Layer Authentication
- Ingress: Caddy + FastAPI validate AGENT_API_TOKEN on every request
- Internal: Claude Code authenticates to the MCP server with a separate MCP_API_TOKEN

### 6. TLS Everywhere
All internal service-to-service communication uses HTTPS with a shared internal CA. No plaintext traffic on any network and server identity should be strong.

### 7. Read-Only Agent Config
Claude Code's MCP configuration is written once at container startup and locked to 440 - the agent cannot modify its own tool registrations.

### 8. Non-Root Containers
All containers run as non-root users (UID 1000). cap_drop: ALL is set on the proxy container.

---

## Project Structure

```
.
├── cluster/
│   ├── caddy/
│   │   ├── Caddyfile               # TLS and reverse proxy config
│   │   └── caddy_test.sh           # Caddy validation script
│   ├── claude/
│   │   ├── server.py               # FastAPI server, Claude Code subprocess
│   │   ├── files_mcp.py            # MCP stdio server wrapping Go REST API
│   │   ├── entrypoint.sh           # Registers MCP tools, locks config, starts server
│   │   ├── runenv.py               # Environment variable validation
│   │   ├── setuplogging.py         # Logging configuration
│   │   ├── requirements.txt        # Python dependencies
│   │   ├── claude_tests.py         # FastAPI unit tests
│   │   └── files_mcp_test.py       # MCP tool unit tests
│   ├── fileserver/
│   │   ├── main.go                 # Go MCP REST server with os.OpenRoot jail
│   │   ├── mcp_test.go             # Go unit tests
│   │   └── go.mod                  # Go module dependencies
│   ├── proxy/
│   │   ├── proxy_config.yaml       # LiteLLM model routing config
│   │   └── proxy_wrapper.py        # LiteLLM startup wrapper
│   ├── docker-compose.yml          # Service orchestration
│   ├── Dockerfile.caddy
│   ├── Dockerfile.claude
│   ├── Dockerfile.mcp
│   ├── Dockerfile.proxy
│   └── start-cluster.sh            # Starts all containers
├── init_build.sh                   # Creates venv and installs test dependencies
├── run.sh                          # Generates certs, rotates tokens, starts cluster
├── query.sh                        # CLI utility for sending queries to the agent
├── test.sh                         # Full test suite (unit + security + integration)
└── logs.sh                         # Tails all container logs
```

---

## Prerequisites

- Docker Engine with Compose V2
- Node.js 22+ (for claude login)
- openssl (for certificate generation)
- Python 3.12+ with venv (for local tests)

---

## Quick Start

1. Clone and initialize

```bash
git clone <your-repo-url> secure-claude
cd secure-claude
cp .secrets.env.example .secrets.env
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
| pytest | Unit tests | claude/ Python server and MCP tools |
| go test | Unit tests | fileserver/ Go MCP server |
| pip-audit | CVE scanning | claude/requirements.txt |
| govulncheck | CVE scanning | fileserver/ Go modules |
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

Some of the code was produced using Google Gemin, some of it was done using Claude
