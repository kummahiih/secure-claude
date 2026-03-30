# Secure Claude Code Cluster

> A hardened, containerized environment for running Claude Code as an AI agent with access to local tools via the Model Context Protocol (MCP). 

Giving an AI raw access to your host machine is risky. **Secure Claude** solves this by wrapping Anthropic's Claude Code CLI in a heavily audited, zero-trust infrastructure. Credentials are never exposed to the agent — a LiteLLM sidecar proxy holds the real API keys while the agent uses ephemeral tokens.

The system forces a deliberate **plan-then-execute** workflow. You create a structured plan with `plan.sh`, and the agent executes tasks one at a time with `query.sh`. This planning structure is inspired by [get-shit-done](https://github.com/gsd-build/get-shit-done).

---

## Why use this? (Security Guarantees)

The cluster-level guarantees are designed for maximum defense-in-depth:

* **Credential Isolation:** The agent operates using an ephemeral `DYNAMIC_AGENT_KEY`, never touching your real `ANTHROPIC_API_KEY`.
* **Network Isolation:** Both `claude-server` and the proxy live exclusively on an internal network (`int_net`). The proxy intentionally has no direct external network access. 
* **Filesystem Jail:** Workspace access is governed by Go's `os.OpenRoot` at `/workspace`, blocking path traversal attacks at the runtime level.
* **Per-Service Auth:** Strict token scoping is enforced. `CLAUDE_API_TOKEN` is required for ingress, while individual backend servers require specific tokens (`MCP_API_TOKEN`, `PLAN_API_TOKEN`, `TESTER_API_TOKEN`, `GIT_API_TOKEN`).
* **Zero-Privilege Compute:** All containers run as non-root (UID 1000) with `cap_drop: ALL`. They are strictly bound by memory, CPU, and PID limits.
* **Test Isolation:** The `tester-server` runs tests as subprocesses with the workspace mounted as read-only.
* **TLS Everywhere:** Uses an internal CA to ensure all service-to-service communication occurs over HTTPS.
* **MCP Security Proxy (`mcp-watchdog`):** All tool use is actively monitored. The proxy actively scans and blocks over 40 distinct attack classes on all JSON-RPC traffic between the agent and its tools.

---

## Quick Start

**1. Clone the repository**
Be sure to include submodules to pull in the agent, planner, and tester services.
```bash
git clone --recurse-submodules [https://github.com/kummahiih/secure-claude](https://github.com/kummahiih/secure-claude)
cd secure-claude
cp .secrets.env.example .secrets.env
```
*(If you already cloned without submodules, run: `git submodule update --init`)*

**2. Configure your API Keys**
Add your Anthropic key to `.secrets.env`:
```bash
ANTHROPIC_API_KEY=sk-ant-...
```
*(To use a Pro subscription OAuth token, run `npm install -g @anthropic-ai/claude-code`, then `claude login` and `claude setup-token`, and copy the token into your `.secrets.env`)*

**3. Initialize and Test**
Set up the environment and verify unit tests (no Docker or secrets required for tests).
```bash
./init_build.sh
./test.sh
```

**4. Run the Cluster and Execute**
Start the infrastructure, create a plan, and unleash the agent.
```bash
./run.sh
./plan.sh claude-sonnet-4-6 "add input validation to the read endpoint"
./query.sh claude-sonnet-4-6 "work on the current tasks"
```

---

## System Architecture

The environment relies on seven containers orchestrated by Docker Compose. The `/workspace` mount is swappable, allowing you to point it at any repository that follows the [workspace interface spec](docs/WORKSPACE_INTERFACE.md).

```text
Host / Network
└─> Caddy:8443 (TLS 1.3 + reverse proxy)
     └─> claude-server:8000 (FastAPI + Claude Code)
          ├─> proxy:4000 (LiteLLM) ──> Anthropic API (no direct external access; int_net only)
          ├─> MCP stdio servers (inside claude-server)
          ├─> mcp-server:8443 (Go REST, filesystem jail)
          │    └─> /workspace (bind mount → active sub-repo)
          ├─> plan-server:8443 (Python REST, plan state)
          │    └─> /plans (bind mount → plans/)
          ├─> tester-server:8443 (Go REST, test runner)
          │    └─> /workspace:ro (bind mount → active sub-repo)
          └─> git-server:8443 (REST, git operations)
               ├─> /workspace:ro (bind mount → active sub-repo)
               └─> /gitdir (bind mount → active sub-repo .git, rw)
```

### Sub-Repositories
The architecture is modular, split across dedicated sub-repositories containing their own architecture (`docs/CONTEXT.md`) and roadmap (`docs/PLAN.md`) files:
* **[secure-claude-agent](cluster/agent/):** MCP tool servers (files, git, docs, planner, tester wrappers) + Claude Code integration.
* **[secure-claude-planner](cluster/planner/):** Plan-server REST API for task state management.
* **[secure-claude-tester](cluster/tester/):** Tester-server REST API for running workspace tests.

---

## 🛠️ Operational Commands

| Command | Description |
| :--- | :--- |
| `./run.sh` | Start cluster (generates certs + tokens) |
| `./plan.sh <model> "<goal>"` | Create a plan without executing code |
| `./query.sh <model> "<query>"` | Send a query or execute a task |
| `./dev-loop.sh <model> <max-iter>` | Automated plan-execute loop (runs until complete/blocked) |
| `./logs.sh` | Tail all container logs |
| `./test.sh` | Run unit tests (no Docker/network needed) |
| `./test-integration.sh` | Run CVE audits + Docker integration tests |

---

## Switching Workspaces

The workspace is a simple symlink located at `cluster/workspace`. Because Docker Compose mounts via `./workspace`, you can change the target dynamically without editing your `docker-compose.yml`.

```bash
cd cluster
ln -sfn planner workspace      # Example: switch from agent to planner
```
*Note: Restart the cluster after switching workspaces. Ensure your target repository follows the [workspace interface](docs/WORKSPACE_INTERFACE.md).*

**Self-Development Mode:**
To have the agent work on the `secure-claude` repo itself, clone a separate working copy and point the symlink at it:
```bash
git clone --recurse-submodules [https://github.com/kummahiih/secure-claude](https://github.com/kummahiih/secure-claude) /path/to/secure-claude-work
cd /path/to/secure-claude/cluster
ln -sfn /path/to/secure-claude-work workspace
```

---

## Security & Quality Auditing

We take security seriously. You can audit the entire stack locally.

```bash
./test.sh                 # Unit tests — runnable from a fresh clone
./test-integration.sh     # Full security + integration suite
```

**Audit Tools Included:**
* **pytest** & **go test**: Unit testing across agent, planner, fileserver, and tester modules.
* **pip-audit**, **govulncheck**, **npm audit**: Comprehensive CVE scanning for Python, Go, and JS dependencies.
* **hadolint**: Dockerfile linting for all images.
* **trivy**: Misconfiguration scanning for `docker-compose.yml` and images.

---

## Credits

* Architecture inspired by [secure-coder](https://github.com/kummahiih/secure-coder) and [secure-mcp](https://github.com/kummahiih/secure-mcp).
* MCP security provided by [mcp-watchdog](https://github.com/bountyyfi/mcp-watchdog) by Bountyy Oy.
* Planning task structure inspired by [get-shit-done](https://github.com/gsd-build/get-shit-done) by TÂCHES (MIT).
* Some of the code was produced using Google Gemini, some of it was done using Claude.