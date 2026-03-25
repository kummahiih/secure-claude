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
(tmpfs shadow, separated gitdir, core.hooksPath), baseline commit floor,
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

### Phase 3 ✅ Test Runner MCP Tool

Added tester-server as 6th container — a Go REST server that runs
`/workspace/test.sh` as a direct subprocess. No Docker socket access required.

- tester-server: Go REST server (POST /run, GET /results, GET /health)
- tester_mcp.py: stdio wrapper inside claude-server (run_tests, get_test_results)
- secure-claude-tester: separate submodule at cluster/tester/
- Dockerfile.tester: 3-stage build (Go binary + TLS cert + runtime with Go/Python test tooling)
- Workspace mounted read-only — tests cannot modify source
- Concurrent run rejection (409 Conflict)
- Test architecture split: sub-repo test.sh = unit tests only (no network); test-integration.sh = security scans + integration
- 13 MCP wrapper tests + integration tests (health, auth, isolation)
- Isolation: tester-server has no access to /gitdir, /plans, or secrets

---

## Phase 4: Close the Loop

Wire everything together: Claude reads code → plans changes → modifies code →
runs tests → interprets results → commits. All without human intervention.

### Acceptance Criteria

A single `plan.sh` + repeated `query.sh` results in Claude completing all tasks,
running tests via the tester MCP tool, fixing failures, and committing — with
human reviewing only the plan.

### Remaining work
- [X] Update system prompt to instruct agent to run tests after completing code changes
- [X] Add test-gate: agent should call run_tests + get_test_results before plan_complete
- [X] Handle test failure loop: agent retries fixes up to N times before plan_block

Repo-specific tasks: [agent PLAN.md](../cluster/agent/docs/PLAN.md)

---

## Phase 5: Hardening and Polish

- [ ] Resource limits on tester-server (timeout, memory caps for test runs)
- [ ] Output sanitization from test runner (strip any leaked env vars)
- [ ] Tag a release
- [ ] Egress TLS: Caddyfile currently uses `tls_insecure_skip_verify` for the
  egress proxy to `host.docker.internal:443`. This is intentional — the host
  nginx uses its own self-signed CA that is unrelated to the cluster's internal
  CA (which is ephemeral and regenerated on each `run.sh`). Before a production
  deployment: provision the host proxy with a cert from the cluster CA (or a
  trusted public CA), remove `tls_insecure_skip_verify`, and add
  `tls_trusted_ca_certs` pointing to the appropriate bundle.

Repo-specific tasks: [agent PLAN.md](../cluster/agent/docs/PLAN.md),
[planner PLAN.md](../cluster/planner/docs/PLAN.md),
[tester PLAN.md](../cluster/tester/docs/PLAN.md)

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
| Claude Code version upgrade breaks --mcp-config or --print | Blocks everything | Medium | Pinned to @2.1.74; test before upgrading |
| Claude changes API contracts during task execution | Broken code | High | System prompt constraint + plan action specificity |
| Subprocess timeout too short for complex tasks | Incomplete work | Medium | 600s timeout; plan smaller tasks |
| Agent marks tasks complete without verifying | Correctness | Medium | Verify criteria in plan; test runner gate in Phase 4 |
| Test runner subprocess hangs indefinitely | Resource exhaustion | Low | Phase 5: add timeout to test execution |
| Vuln DB staleness in offline scans | Missed CVEs | Low | Security scans run in test-integration.sh with network access |
