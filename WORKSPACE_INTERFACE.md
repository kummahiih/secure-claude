# Workspace Interface Specification

Any repository mounted as the active workspace in secure-claude must follow this structure.

## Required Structure

```
<repo-root>/
├── docs/
│   ├── CONTEXT.md          # Architecture, design decisions, implementation details
│   └── PLAN.md             # Development roadmap and task backlog
├── test.sh                 # Runs all unit tests and dependency scans for this repo
├── README.md               # Project overview, setup, usage
└── ...                     # Project source code
```

## Contract

| Item | Requirement |
| :--- | :--- |
| `README.md` | Project overview, local development setup, test instructions |
| `docs/CONTEXT.md` | Architecture the agent needs to understand before making changes |
| `docs/PLAN.md` | Current phase, tasks, acceptance criteria, risks |
| `test.sh` | Executable script that runs all repo-level tests (see below) |

## test.sh Contract

Each workspace repo must provide a `test.sh` at its root. The parent repo's
test suite calls it automatically for whatever workspace is currently active.

Requirements:
- Must be executable (`chmod +x test.sh`)
- Must run from the repo root (`cd` into the repo, then `./test.sh`)
- Must use `set -euo pipefail` and exit non-zero on any failure
- Must run unit tests for all languages in the repo
- Must run dependency security scans (pip-audit, govulncheck, etc.)
- Must not require network access beyond pulling pre-cached Docker images
- Must not require any secrets or API tokens (use mocks/fakes)
- Should complete within 120 seconds

Example for a Python + Go repo:

```bash
#!/bin/bash
set -euo pipefail

echo "[unit] Running Go tests..."
(cd fileserver && go test -v ./...)

echo "[unit] Running Python tests..."
(cd claude && python -m pytest -v --tb=short)

echo "[security] Scanning Go deps..."
(cd fileserver && go run golang.org/x/vuln/cmd/govulncheck@latest ./...)

echo "[security] Scanning Python deps..."
pip-audit -r claude/requirements.txt
```

Example for a Python-only repo:

```bash
#!/bin/bash
set -euo pipefail

echo "[unit] Running Python tests..."
(cd planner && python -m pytest -v --tb=short)

echo "[security] Scanning Python deps..."
pip-audit -r planner/requirements.txt
```

## How Mounting Works

In `docker-compose.yml`, the workspace bind mount points to the active sub-repo:

```yaml
# To work on the agent:
- ./agent:/workspace:ro       # claude-server
- ./agent:/workspace:rw       # mcp-server

# To work on the planner:
- ./planner:/workspace:ro     # claude-server
- ./planner:/workspace:rw     # mcp-server
```

The `docs/` folder inside the mounted repo is also mounted read-only into
claude-server at `/docs`, giving the agent access via the docs MCP tool set.

The parent repo's `docs/` folder is **not** mounted — all context the agent
needs must live inside the workspace repo's own `docs/`.
