# secure-claude: Development Plan

**Goal:** Self-developing agentic loop — Claude Code running inside the cluster
can read, modify, test, and commit its own source code autonomously.

**Tools:** Claude Pro subscription, Claude Code CLI

---

## Completed Phases

### Phase 1 ✅ Git Submodule Split + Isolation Verification

Created two-repo split (secure-claude + secure-claude-agent), runtime isolation
checks for all 4 containers (26 checks on claude-server), credential isolation
via DYNAMIC_AGENT_KEY rename, MCP config as build artifact.

### Phase 2 ✅ Git MCP Tools + Docs Access

Added git_mcp.py (6 tools), docs_mcp.py (2 tools), 3-layer git hook prevention
(/dev/null shadow, separated gitdir, core.hooksPath), baseline commit floor,
25 git tool tests.

### Phase 2.5 ✅ Planning Tool

Added plan-then-execute workflow. Task structure inspired by
[get-shit-done](https://github.com/gsd-build/get-shit-done) (MIT).

- plan-server: 5th container (Python FastAPI), REST API for plan CRUD
- plan_mcp.py: stdio wrapper inside claude-server (6 tools)
- secure-claude-planner: separate submodule for independent development
- plan.sh / /plan endpoint: planning mode (no code execution)
- System prompt: plan-aware (/ask checks plan_current), API contract protection
- JSON task format: goal, tasks with files/action/verify/done, auto-advancing
- Plans stored in parent repo plans/ directory, committed to git
- 42 server tests + 28 MCP wrapper tests + integration tests
- Isolation: plan-server has no access to /workspace, /gitdir, or secrets

---

## Phase 3: Test Runner MCP Tool

### Tasks

- [ ] Create `cluster/test-runner/` — lives outside agent submodule (Claude can't modify it)
- [ ] Build Python MCP stdio server that invokes `docker run` with pre-built test images
- [ ] Python test image: mounts `cluster/agent/claude/`, runs pytest, returns JSON output
- [ ] Go test image: mounts `cluster/agent/fileserver/`, runs `go test -json`, returns structured output
- [ ] Add `conftest.py` with autouse network-blocking fixture to agent repo
- [ ] Register test runner as MCP tool in .mcp.json
- [ ] Test: query Claude to "run the tests" and verify structured pass/fail output

### Design

- `docker run` for sibling containers (not Docker-in-Docker)
- Each language gets its own test container with only its source folder mounted
- Claude-written tests must be mocked unit tests only — no credentials reachable
- Test runner needs Docker socket access — document the security implication

---

## Phase 4: Close the Loop

Wire everything together: Claude reads code → plans changes → modifies code →
runs tests → interprets results → commits. All without human intervention.

### Tasks

- [ ] End-to-end test: plan → execute all tasks → tests pass → committed
- [ ] Handle edge cases: test failures trigger re-plan, blocked tasks
- [ ] Add structured logging for the agentic loop
- [ ] Automate task advancement (loop query.sh until plan complete)

### Acceptance Criteria

A single `plan.sh` + repeated `query.sh` results in Claude completing all tasks,
running tests, fixing failures, and committing — with human reviewing only the plan.

---

## Phase 5: Hardening and Polish

- [ ] Resource limits on test runner containers (timeout, memory)
- [ ] Output sanitization from test runner (strip any leaked env vars)
- [ ] `append_file` and `replace_in_file` tools (context-lighter file editing)
- [ ] Tag a release

---

## Out of Scope (this sprint)

- `git_push` / GitHub integration (requires credential isolation design)
- CI/CD pipeline for parent repo
- Multi-agent orchestration (review agent checking coding agent)
- Separate PLAN_API_TOKEN (currently shares MCP_API_TOKEN)

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
| :--- | :--- | :--- | :--- |
| Test runner Docker socket access creates escape vector | Security gap | Medium | Document, consider rootless Docker or Sysbox |
| Claude Code version upgrade breaks --mcp-config or --print | Blocks everything | Medium | Pinned to @2.1.74; test before upgrading |
| Claude changes API contracts during task execution | Broken code | High | System prompt constraint + plan action specificity |
| Subprocess timeout too short for complex tasks | Incomplete work | Medium | 300s timeout; plan smaller tasks |
| Agent marks tasks complete without verifying | Correctness | Medium | Verify criteria in plan; future: test runner gate |
