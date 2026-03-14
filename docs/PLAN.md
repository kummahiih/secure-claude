# secure-claude: 2-Week Development Plan

**Goal:** Self-developing agentic loop — Claude Code running inside the cluster
can read, modify, test, and commit its own source code autonomously.

**Budget:** ~3 hours/day × 14 days = ~42 hours total
**Tools:** Claude Pro subscription, Claude Code CLI

---

## Phase 1: Git Submodule Split (Days 1–2, ~4–6 hours) ✅ COMPLETE

The foundation. Everything else depends on this.

### Tasks

- [x] Create new GitHub repo `secure-claude-agent`
- [x] Move `cluster/claude/` and `cluster/fileserver/` into `cluster/agent/`
- [x] Extract with `git filter-repo` to preserve history
- [x] In `secure-claude`, remove agent directory and add submodule at `cluster/agent/`
- [x] Update `Dockerfile.claude` COPY paths → `agent/claude/...`
- [x] Update `Dockerfile.mcp` COPY paths → `agent/fileserver/...`
- [x] Update `docker-compose.yml` volumes and build contexts
- [x] Update `test.sh` paths
- [x] Run `./test.sh` — all existing tests pass
- [x] Full query loop works end-to-end

### Decisions Made During Phase 1

- Dockerfiles stay in parent repo (cluster/) — they need certs/ at build time and
  should not be agent-modifiable
- Single submodule rather than multiple — claude/ and fileserver/ are tightly coupled,
  future MCP tools (git, test runner) will go in the same submodule
- caddy/ and proxy/ stay in parent repo — pure infrastructure, not agent code
- Docs moved to docs/ directory

### Remaining: Acceptance Criteria Verification

- [ ] Verify from inside claude-server that `/workspace` contains only `claude/` and `fileserver/`, no secrets
  - `docker exec` into claude-server, check /workspace has no docker-compose.yml, proxy_config.yaml, .secrets.env
- [ ] Verify submodule `.git` does not leak parent repo info

---

## Phase 2: Git MCP Tools (Day 3, ~6–8 hours)

### Tasks

- [ ] Create `cluster/agent/claude/git_mcp.py` — MCP stdio server for git operations
  - Follow same pattern as `files_mcp.py`: subprocess calls, structural directory lock
  - Tools: `git_status`, `git_diff`, `git_add`, `git_commit`, `git_log`
  - Working directory locked to mount point (not path filtering)
- [ ] Register in `entrypoint.sh` alongside fileserver tools (through mcp-watchdog)
- [ ] Write `git_mcp_test.py` with temporary git repo fixture
- [ ] Verify via test query that Claude sees both fileserver and git tool sets

### Design Decisions

- No `git_push` for now — requires network access and GitHub credentials, which is a
  separate isolation problem. Commits stay local; human pushes.
- The mounted submodule directory must have `.git` available inside the container,
  but the parent repo's `.git` must not be reachable.

### Acceptance Criteria

Claude can run `git_status`, `git_diff`, `git_add`, `git_commit`, `git_log` through
MCP tools. Unit tests pass with a temporary git repo fixture.

---

## Phase 3: Test Runner MCP Tool (Days 4–5, ~8–10 hours)

The most complex piece.

### Tasks

- [ ] Create `cluster/test-runner/` — lives outside agent submodule (Claude can't modify it)
- [ ] Build Python MCP stdio server that invokes `docker run` with pre-built test images
- [ ] Python test image: mounts `cluster/agent/claude/`, runs pytest, returns JSON output
- [ ] Go test image: mounts `cluster/agent/fileserver/`, runs `go test -json`, returns structured output
- [ ] Add `conftest.py` with autouse network-blocking fixture to agent repo
- [ ] Register test runner as MCP tool in `entrypoint.sh`
- [ ] Test: query Claude to "run the tests" and verify structured pass/fail output

### Design Decisions

- Use `docker run` to start sibling containers (not Docker-in-Docker)
- Each language gets its own test container with only its source folder mounted
- Claude-written tests must be mocked unit tests only — no credentials reachable
- Test runner needs Docker socket access — document the security implication

### Acceptance Criteria

Claude can invoke test runner via MCP, get structured pass/fail results for both
Python and Go tests. Tests run in isolated containers with no access to secrets.

---

## Phase 4: Close the Loop (Days 6–8, ~8–12 hours)

Wire everything together and prove the autonomous cycle works.

### Tasks

- [ ] End-to-end test: Claude reads code → modifies it → runs tests → interprets results → commits
- [ ] Tune the system prompt for the agentic workflow
  - Claude should know: run tests before committing, interpret failures, iterate
- [ ] Handle edge cases: test failures, merge conflicts, malformed output
- [ ] Add structured logging for the agentic loop (what was changed, test results, commit hash)
- [ ] Document the workflow in CONTEXT.md (architecture has now changed)

### Acceptance Criteria

A single query like "add input validation to the read endpoint and write a test for it"
results in Claude modifying code, running tests, fixing failures, and committing —
all without human intervention.

---

## Phase 5: Hardening and Polish (Days 9–10, remaining hours)

### Tasks

- [ ] Resource limits on test runner containers (timeout, memory)
- [ ] Output sanitization from test runner (strip any leaked env vars)
- [ ] Update README.md with agentic workflow documentation
- [ ] Tag a release

---

## Out of Scope (for this sprint)

- `git_push` / GitHub integration (requires credential isolation design)
- CI/CD pipeline for parent repo
- Multi-agent orchestration (review agent checking coding agent)
- Production hardening beyond basic resource limits

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
| :--- | :--- | :--- | :--- |
| ~~Docker build context paths break after submodule split~~ | ~~Blocks all work~~ | ~~Medium~~ | ✅ Resolved — paths updated, tests pass |
| Submodule `.git` leaks parent repo info | Security gap | Low | Verify with `docker exec` inspection (Phase 1 remaining) |
| Test runner Docker socket access creates escape vector | Security gap | Medium | Document, consider rootless Docker or Sysbox |
| Integration debugging takes longer than estimated | Schedule slip | High | Phases 1–3 are the priority; Phase 5 is buffer |
| Claude Code doesn't handle MCP tool errors gracefully | Poor agentic loop | Medium | Test error paths explicitly in Phase 4 |

---

## Session Workflow

For each task:
1. Start fresh Claude Code session
2. Paste or point to `docs/CONTEXT.md` and this plan
3. Focus on one phase at a time
4. Before ending session: ask Claude to write a handoff note
5. Start next session with the handoff note
6. Update this plan (check off tasks, add notes) as you go
