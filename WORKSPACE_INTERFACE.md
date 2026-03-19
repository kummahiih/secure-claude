# Workspace Interface Specification

Any repository mounted as the active workspace in secure-claude must follow this structure.

## Required Structure

```
<repo-root>/
├── docs/
│   ├── CONTEXT.md          # Architecture, design decisions, implementation details
│   └── PLAN.md             # Development roadmap and task backlog
├── test.sh                 # Runs all unit tests for this repo (no network required)
├── README.md               # Project overview, setup, usage
└── ...                     # Project source code
```

## Contract

| Item | Requirement |
| :--- | :--- |
| `README.md` | Project overview, local development setup, test instructions |
| `docs/CONTEXT.md` | Architecture the agent needs to understand before making changes |
| `docs/PLAN.md` | Current phase, tasks, acceptance criteria, risks |
| `test.sh` | Executable script that runs all repo-level unit tests (see below) |

## test.sh Contract

Each workspace repo must provide a `test.sh` at its root. The tester-server
container executes it via `POST /run` and captures the output. The parent repo's
test suite also calls it for whatever workspace is currently active.

Requirements:
- Must be executable (`chmod +x test.sh`)
- Must run from the repo root (`cd` into the repo, then `./test.sh`)
- Must use `set -euo pipefail` and exit non-zero on any failure
- Must run unit tests for all languages in the repo
- Must not require network access (runs inside network-isolated tester-server)
- Must not require any secrets or API tokens (use mocks/fakes with defaults)
- Must not run security/vulnerability scans (those run in the parent test.sh which has network)
- Should complete within 120 seconds

Example for a Python + Go repo:

```bash
#!/bin/bash
set -euo pipefail

# Dummy tokens for unit tests — no real services are contacted
export MCP_API_TOKEN="${MCP_API_TOKEN:-dummy-mcp-token}"
export CLAUDE_API_TOKEN="${CLAUDE_API_TOKEN:-dummy-claude-token}"
export DYNAMIC_AGENT_KEY="${DYNAMIC_AGENT_KEY:-dummy-agent-key}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://proxy:4000}"

echo "[unit] Running Go tests..."
(cd fileserver && go test -v ./...)

echo "[unit] Running Python tests..."
(cd claude && python -m pytest -v --tb=short)
```

Example for a Go-only repo:

```bash
#!/bin/bash
set -euo pipefail

echo "[unit] Running Go tests..."
go test -v ./...
```

### Security scans

Vulnerability scanning (govulncheck, pip-audit, npm audit) requires network
access to fetch fresh vulnerability databases. These scans are centralized in
the parent repo's `test.sh` which runs on the host with network access. Sub-repo
`test.sh` files must not include security scans.

## How Mounting Works

In `docker-compose.yml`, the workspace bind mount points to the active sub-repo:

```yaml
# To work on the agent:
- ./agent:/workspace:ro       # claude-server
- ./agent:/workspace:rw       # mcp-server
- ./agent:/workspace:ro       # tester-server

# To work on the planner:
- ./planner:/workspace:ro     # claude-server
- ./planner:/workspace:rw     # mcp-server
- ./planner:/workspace:ro     # tester-server
```

The `docs/` folder inside the mounted repo is also mounted read-only into
claude-server at `/docs`, giving the agent access via the docs MCP tool set.

The parent repo's `docs/` folder is **not** mounted — all context the agent
needs must live inside the workspace repo's own `docs/`.

## How Testing Works

The tester-server container mounts `/workspace:ro` and executes `test.sh` as a
subprocess when triggered via `POST /run`. The agent accesses this through the
tester MCP tools (`run_tests`, `get_test_results`).

The tester container includes Go, Python, pytest, and common test dependencies
pre-installed. Tests run as the `appuser` (UID 1000) with no network access
beyond the internal Docker network.
