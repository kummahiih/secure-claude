# Plan: Separate Git MCP Service into Dedicated Container

## Goal

Extract git operations from claude-server's in-process stdio subprocess (`git_mcp.py`) into a dedicated `git-server` container with its own credentials, TLS certificates, and HTTPS REST API — following the same pattern as `mcp-server`, `plan-server`, and `tester-server`. Remove `/workspace` and `/gitdir` mounts from claude-server to make it as read-only as possible.

---

## Current State

```
claude-server (claude Code subprocess)
  ├─ git_mcp.py  → git subprocess (GIT_DIR=/gitdir, GIT_WORK_TREE=/workspace)
  │   Mounts:
  │     ./workspace:/workspace:ro
  │     ./workspace/.git:/gitdir (rw)
  │     ./workspace/docs:/docs:ro
```

`git_mcp.py` runs as an MCP stdio server inside claude-server. It shells out to `git` directly using `subprocess.run()` with `GIT_DIR` and `GIT_WORK_TREE` env vars. Hook prevention is done via `core.hooksPath=/dev/null` and `--no-verify` flags. Baseline commit is captured in `entrypoint.sh` and passed via `GIT_BASELINE_COMMIT` env var.

---

## Target State

```
claude-server
  ├─ git_mcp.py  → HTTPS REST → git-server:8443
  │   Mounts:
  │     ./workspace/docs:/docs:ro        (kept — for docs_mcp.py)
  │   Removed:
  │     ./workspace:/workspace:ro        (no longer needed)
  │     ./workspace/.git:/gitdir         (no longer needed)

git-server:8443 (new container)
  ├─ Go or Python REST server
  │   Mounts:
  │     ./workspace/.git:/gitdir         (rw — for add/commit/reset)
  │     ./workspace:/workspace:ro        (read-only — for status/diff/add)
  │   tmpfs:
  │     /workspace/.git:ro,size=0        (shadow .git inside workspace — hook prevention)
  │   Env:
  │     GIT_API_TOKEN
  │   Certs:
  │     git-server.crt, git-server.key, ca.crt
```

---

## Design Decisions

### Why git-server needs /workspace:ro

Git operations (`status`, `diff`, `add`) require access to the working tree to compare against the index. Without the worktree, these commands fail. The mount is **read-only** — all file writes continue to go through `mcp-server`. Only `/gitdir` is read-write (for index updates, commits, refs).

### Hook prevention (unchanged pattern)

1. `core.hooksPath=/dev/null` on every git command
2. `--no-verify` on commits
3. tmpfs shadow: `/workspace/.git:ro,size=0` — prevents git from finding hooks via the workspace `.git` path (same as mcp-server does today)

### Baseline commit capture

Moves from claude-server `entrypoint.sh` to git-server `entrypoint.sh`. The git-server captures `GIT_BASELINE_COMMIT` (and per-submodule baselines) at startup and enforces the reset floor internally. Claude-server no longer needs to know about baselines.

### REST API vs Go vs Python

The existing pattern splits between Go (mcp-server, tester-server) and Python (plan-server). Either works. The plan is implementation-language-agnostic — the REST interface is what matters.

### Token isolation

New token `GIT_API_TOKEN` follows the existing per-service pattern:

| Token | claude-server | git-server | mcp-server | Others |
|:---|:---|:---|:---|:---|
| GIT_API_TOKEN | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden |

---

## Tasks

### Task 1: Create git-server REST API

**Files:** `Dockerfile.git`, `git-server/` (new directory — either Go or Python)

**Action:**
- Create a new REST server that exposes the 6 git tool operations as HTTPS endpoints:
  - `GET /status?submodule_path=...` → git status --short
  - `GET /diff?staged=bool&submodule_path=...` → git diff [--cached]
  - `POST /add` (JSON body: `{paths: [...]}`) → git add
  - `POST /commit` (JSON body: `{message: "...", submodule_path: "..."}`) → git commit
  - `GET /log?max_count=N&submodule_path=...` → git log --oneline
  - `POST /reset` (JSON body: `{count: N, submodule_path: "..."}`) → git reset --soft
- Port all git logic from current `git_mcp.py`: `_run_git`, `_run_git_env`, `git_env_for`, `parse_gitmodules`, baseline enforcement
- Bearer token auth (`GIT_API_TOKEN`) on all endpoints
- TLS with server cert signed by internal CA
- Hook prevention: `core.hooksPath=/dev/null` + `--no-verify` on every command

**Verify:** Server starts, responds to all 6 endpoints with correct git output, rejects requests without valid token.

### Task 2: Create Dockerfile.git

**Files:** `Dockerfile.git`

**Action:**
- Multi-stage build following existing pattern (signer stage for certs, final stage for runtime)
- Signer stage: generate `git-server.key`, `git-server.crt` signed by internal CA with `subjectAltName=DNS:git-server,DNS:localhost,IP:127.0.0.1`
- Install `git` in the final image
- Copy CA cert for trust
- Non-root user (UID 1000), same pattern as other containers
- Copy `entrypoint.sh` that:
  1. Captures `GIT_BASELINE_COMMIT` from HEAD
  2. Captures per-submodule baselines
  3. Runs isolation checks
  4. Starts the server

**Verify:** `docker build -f Dockerfile.git .` succeeds; image runs and serves HTTPS.

### Task 3: Add git-server to docker-compose.yml

**Files:** `docker-compose.yml`

**Action:**
- Add `git-server` service:
  ```yaml
  git-server:
    build:
      context: .
      dockerfile: Dockerfile.git
    container_name: git-server
    user: "1000:1000"
    environment:
      - GIT_API_TOKEN=${GIT_API_TOKEN}
      - SSL_CERT_FILE=/app/certs/ca.crt
      - GIT_DIR=/gitdir
      - GIT_WORK_TREE=/workspace
    volumes:
      - ./workspace/.git:/gitdir            # Git data (rw)
      - ./workspace:/workspace:ro           # Worktree (read-only)
    tmpfs:
      - /workspace/.git:ro,size=0           # Shadow .git — hook prevention
    networks:
      - int_net
    mem_limit: 512m
    cpus: 1.0
    pids_limit: 100
    cap_drop:
      - ALL
    restart: unless-stopped
  ```

**Verify:** `docker compose config` validates; `docker compose up git-server` starts cleanly.

### Task 4: Convert git_mcp.py to HTTPS REST client

**Files:** `agent/claude/git_mcp.py`

**Action:**
- Replace all `subprocess.run(["git", ...])` calls with `requests.get/post()` to `git-server:8443`
- Follow the exact pattern of `files_mcp.py` and `tester_mcp.py`:
  - Import `GIT_SERVER_URL` and `GIT_API_TOKEN` from `runenv.py`
  - Use `HEADERS = {"Authorization": f"Bearer {GIT_API_TOKEN}"}`
  - Use `VERIFY = "/app/certs/ca.crt"`
- Remove all git subprocess logic, `parse_gitmodules`, `git_env_for`, baseline commit handling (all moved to git-server)
- Remove `import subprocess` — no longer needed
- Keep the MCP tool definitions (names, schemas) unchanged — the agent-facing interface is identical

**Verify:** Unit tests pass with mocked HTTP responses; integration test confirms end-to-end git operations work.

### Task 5: Update git_mcp_test.py for REST client

**Files:** `agent/claude/git_mcp_test.py`

**Action:**
- Replace all tests that mock git subprocess calls with tests that mock HTTP requests to git-server
- Test: correct URL construction, token header present, error handling for 401/404/500 responses
- Keep test coverage for: status, diff, add, commit, log, reset_soft
- Remove tests for: `parse_gitmodules`, `git_env_for`, `_run_git` (those are now git-server's responsibility)

**Verify:** `pytest git_mcp_test.py` passes.

### Task 6: Remove workspace/gitdir mounts from claude-server

**Files:** `docker-compose.yml`

**Action:**
- Remove from claude-server volumes:
  ```yaml
  # REMOVE these two:
  - ./workspace:/workspace:ro
  - ./workspace/.git:/gitdir
  # KEEP this:
  - ./workspace/docs:/docs:ro
  ```
- Remove from claude-server environment:
  ```yaml
  # REMOVE these two:
  - GIT_DIR=/gitdir
  - GIT_WORK_TREE=/workspace
  ```
- Add to claude-server environment:
  ```yaml
  # ADD:
  - GIT_API_TOKEN=${GIT_API_TOKEN}
  - GIT_SERVER_URL=https://git-server:8443
  ```
- Add `git-server` to claude-server `depends_on`
- Remove `git` package from `Dockerfile.claude` (no longer needed — git runs in git-server)

**Verify:** claude-server starts without `/workspace` or `/gitdir`; git MCP tools work via REST.

### Task 7: Update runenv.py

**Files:** `agent/claude/runenv.py`

**Action:**
- Add:
  ```python
  GIT_SERVER_URL = os.environ.get("GIT_SERVER_URL", "https://git-server:8443")
  GIT_API_TOKEN = os.getenv("GIT_API_TOKEN")
  ```

**Verify:** Import works; values resolve from env.

### Task 8: Update entrypoint.sh in claude-server

**Files:** `agent/claude/entrypoint.sh`

**Action:**
- Remove the baseline commit capture block (the `if [ -n "$GIT_DIR" ]...` section) — baseline capture now happens in git-server's entrypoint
- claude-server entrypoint becomes simpler: just isolation checks + start server

**Verify:** claude-server starts cleanly without GIT_DIR/GIT_WORK_TREE.

### Task 9: Update verify_isolation.py

**Files:** `agent/claude/verify_isolation.py`

**Action:**
- Add `"git-server"` role with:
  - `FORBIDDEN_ENV_VARS`: `ANTHROPIC_API_KEY`, `MCP_API_TOKEN`, `PLAN_API_TOKEN`, `TESTER_API_TOKEN`, `CLAUDE_API_TOKEN`
  - `REQUIRED_ENV_VARS`: `GIT_API_TOKEN`
  - `FORBIDDEN_PATHS`: standard secrets/config files
  - `REQUIRED_PATHS`: `/app`, `/gitdir`
- Update `"claude-server"` role:
  - Add `GIT_API_TOKEN` to `REQUIRED_ENV_VARS`
  - Remove `/workspace`-related `FORBIDDEN_PATHS` entries that no longer apply (workspace not mounted)
  - Remove git-related required paths if any
- Add `GIT_API_TOKEN` to `FORBIDDEN_ENV_VARS` for: `mcp-server`, `plan-server`, `tester-server`, `proxy`, `caddy`
- Add workspace entry whitelist for git-server (similar to mcp-server's `WORKSPACE_ALLOWED_ENTRIES`)

**Verify:** `verify_all("git-server")` passes in the new container; existing roles still pass.

### Task 10: Update .mcp.json in Dockerfile.claude

**Files:** `Dockerfile.claude`

**Action:**
- The git MCP server entry stays (it's still a stdio process in claude-server), but it now runs the REST-client version of `git_mcp.py` — no change needed to `.mcp.json` itself
- Confirm `git_mcp.py` is still copied into the image

**Verify:** `.mcp.json` still lists the git server; Claude Code discovers it.

### Task 11: Generate GIT_API_TOKEN in run.sh

**Files:** `run.sh` (or equivalent startup script)

**Action:**
- Add `GIT_API_TOKEN` generation alongside existing tokens (`MCP_API_TOKEN`, `PLAN_API_TOKEN`, `TESTER_API_TOKEN`)
- Add to `.env` or `.cluster_tokens.env` file generation
- Ensure it's passed to both `claude-server` and `git-server` in compose

**Verify:** Token is generated and both services receive it.

### Task 12: Update documentation

**Files:** `docs/CONTEXT.md`, `docs/ARCHITECTURE.md`, `docs/HARDENING.md`

**Action:**
- Update architecture diagram: git_mcp.py now routes through HTTPS REST to git-server:8443
- Update service inventory: 7 containers (was 6)
- Update volume mount tables: claude-server loses /workspace and /gitdir; git-server gets them
- Update token isolation matrix: add GIT_API_TOKEN row
- Update HARDENING.md: add git-server hardening section
- Update request flow: step 6 changes from "git subprocess" to "HTTPS REST → git-server:8443"

**Verify:** Documentation accurately reflects new architecture.

### Task 13: Update integration tests

**Files:** `test-integration.sh`

**Action:**
- Add git-server to Docker build list
- Add git-server health check
- Add git-server auth test (reject missing/wrong token)
- Add git-server isolation test (verify forbidden env vars absent)
- Update claude-server isolation tests (verify /workspace and /gitdir not mounted)

**Verify:** `test-integration.sh` passes with the new architecture.

---

## Security Impact

### Improvements

1. **claude-server attack surface reduced** — no `/workspace`, no `/gitdir`, no `git` binary. A compromised Claude Code process cannot directly read source files or tamper with git history.
2. **Credential separation** — `GIT_API_TOKEN` scoped only to git operations; cannot be used against mcp-server or plan-server.
3. **Git operations auditable** — all git commands route through a single REST endpoint with token auth; easier to log and rate-limit.

### Neutral

- Hook prevention is unchanged — same three layers (hooksPath, --no-verify, tmpfs shadow).
- Baseline commit floor enforcement is unchanged — just moved to git-server.

### Risks

- **New network hop** — git operations gain ~1ms latency per call (negligible for the use case).
- **git-server sees /workspace:ro** — necessary for git to function; same trust boundary as tester-server which also has /workspace:ro.
- **One more container** — marginal resource overhead; offset by claude-server becoming lighter (no git binary, no workspace mount).

---

## Migration Notes

- The agent-facing MCP tool interface (tool names, schemas, behavior) is **unchanged**. No prompt or system prompt updates needed.
- The `.mcp.json` entry for `git` stays the same — it still launches `git_mcp.py` as a stdio server; the difference is that `git_mcp.py` now makes HTTPS calls instead of subprocess calls.
- Existing plans and workflows are unaffected.
