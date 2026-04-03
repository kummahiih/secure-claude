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

## Submodule Support

### How the git MCP tools handle submodules

All git tools (`git_status`, `git_diff`, `git_commit`, `git_log`, `git_reset_soft`) accept an optional `submodule_path` parameter — a path relative to the workspace root (e.g. `cluster/agent`). When provided, the tool operates on that submodule's git repo instead of the root.

`git_add` does not take `submodule_path` directly. Instead it auto-detects the owning submodule from the file paths you pass. All paths must belong to the same repository; staging across multiple repos in one call returns an error.

Routing is implemented via two helpers in `git_mcp.py`:

- **`parse_gitmodules(workspace)`** — reads `/workspace/.gitmodules` and returns a list of `{name, path}` dicts.
- **`git_env_for(file_path, submodule_path)`** — returns the correct `GIT_DIR` / `GIT_WORK_TREE` env for the target repo. Priority: explicit `submodule_path` > auto-detect from `file_path` > root repo.

For submodules, `GIT_DIR` is resolved to `/gitdir/modules/<submodule_path>` (the standard location Git uses when `git submodule update` is called against a separated gitdir).

Per-submodule baseline commits are captured at startup so `git_reset_soft` enforces the same session-only floor for submodule repos that it does for the root.

### Identity contract

If the workspace repository contains Git submodules, the root repository's author identity must be propagated to all initialized submodules prior to mounting the workspace. Because the parent repository's `/workspace/.git` is mounted read-only for security, the agent cannot dynamically configure its own Git identity if a submodule is missing it.

To ensure the agent can successfully use the `git_commit` tool within subrepositories without falling into an execution loop, you must run the following initialization script (or integrate its logic into your startup sequence) before starting the `claude-server` container:

```bash
#!/bin/bash
set -euo pipefail

echo "[setup] Propagating Git identity to submodules..."

# 1. Grab the identity from the root repository
ROOT_NAME=$(git config user.name)
ROOT_EMAIL=$(git config user.email)

# 2. Safety check: ensure the root identity actually exists
if [ -z "$ROOT_NAME" ] || [ -z "$ROOT_EMAIL" ]; then
    echo "Error: Root repository user.name or user.email is missing. Please configure them."
    exit 1
fi

# 3. Apply the identity to all submodules
git submodule foreach --quiet "
    git config user.name \"\$ROOT_NAME\"
    git config user.email \"\$ROOT_EMAIL\"
    echo \"Configured identity for \$name\"
"
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
`test.sh` also calls it for whatever workspace is currently active.

Requirements:
- Must be executable (`chmod +x test.sh`)
- Must run from the repo root (`cd` into the repo, then `./test.sh`)
- Must use `set -euo pipefail` and exit non-zero on any failure
- Must run unit tests for all languages in the repo
- Must not require network access (runs inside network-isolated tester-server)
- Must not require any secrets or API tokens (use mocks/fakes with defaults)
- Must not run security/vulnerability scans (those run in `test-integration.sh`)
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
the parent repo's `test-integration.sh` which runs on the host with network and
Docker socket access. Sub-repo `test.sh` files must not include security scans.

### Parent repo test split

The parent repo has two test scripts:

| Script | Requires | Contents |
| :--- | :--- | :--- |
| `test.sh` | Go, Python/pytest | Sub-repo unit tests only — runnable from a fresh clone |
| `test-integration.sh` | Docker, network, openssl | CVE audits, Docker builds, cluster integration tests |

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

**`test.sh` runs inside the tester-server container, not on the host.** It has
no Docker socket, no network access beyond the internal Docker network, and no
access to secrets. The script runs as `appuser` (UID 1000).

### Pre-installed tools in Dockerfile.tester

| Category | Tools / Versions |
| :--- | :--- |
| Base image | `python:3.12-slim` (Debian-based) |
| Go | 1.26.1 — `go`, `gofmt` available on `PATH` |
| Python | 3.12 — `python`, `pip` |
| pytest | 8.3.4 (+ pytest-asyncio 1.3.0) |
| Python libraries | fastapi, uvicorn, pydantic, requests, certifi, mcp, mcp-watchdog |
| System packages | bash, ca-certificates, curl, tar, gcc, git, libc6-dev |

**Not installed:** Node.js/npm, Ruby, Rust, Java, .NET, make, Docker,
govulncheck, pip-audit, hadolint. Security-scan tools are intentionally absent
(they require network access; they run in `test-integration.sh` instead).

### Extending Dockerfile.tester for your project

If `test.sh` requires a tool that is not in the list above (for example Node.js
or an extra pip package), you must add an install step to
`cluster/Dockerfile.tester` in the **Stage 3 (Runtime)** section and rebuild
the image.

**Example — adding Node.js 22 and an npm package:**

```dockerfile
# Stage 3: Runtime with test tooling
FROM python:3.12-slim
...
# Add Node.js for JavaScript tests
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*
RUN npm install -g jest@29
```

**Example — adding an extra Python package:**

```dockerfile
# Append to tester/requirements.txt instead of inline RUN pip install:
httpx==0.28.0
```

Then rebuild and restart the tester-server container:

```bash
docker compose build tester-server
docker compose up -d tester-server
```

> **Warning:** Changes to `Dockerfile.tester` require rebuilding the
> tester-server image before the new tool is available to `test.sh`. Forgetting
> to rebuild is the most common cause of "command not found" failures in the
> tester container.

## Mounting the Parent Repo as Workspace

To have the agent work on secure-claude itself (self-development), clone the
repo and mount it as the workspace:

```bash
# Clone into a working copy separate from the live cluster source
git clone --recurse-submodules https://github.com/kummahiih/secure-claude /path/to/secure-claude-work

# Point the workspace symlink at the working copy
cd /path/to/secure-claude/cluster
ln -sfn /path/to/secure-claude-work workspace
```

Then update `docker-compose.yml` bind mounts to point at the working copy,
or use the symlink. The working copy must follow this interface spec — it
already does since it has `test.sh`, `docs/CONTEXT.md`, and `docs/PLAN.md`.