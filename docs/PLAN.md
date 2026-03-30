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

Items sourced from [THREAT_MODEL.md](THREAT_MODEL.md) residual risks.

### P1 — Critical

- [X] **RR-1** ~~Remove `tls_insecure_skip_verify` from `caddy/Caddyfile`~~ — Done
  (2026-03-27). Replaced with domain-locked egress: dedicated Caddy `:8081`
  listener hardcoded to `api.anthropic.com:443`; proxy moved to `int_net` only
  (no direct internet); `tls_insecure_skip_verify` removed entirely. See
  `HARDENING.md` egress filtering section.
- [X] **RR-2** ~~Add `context.WithTimeout` (or `cmd.WaitDelay`) around
  `cmd.CombinedOutput()` in `tester/main.go` to prevent indefinite hangs.~~
  Done (2026-03-27). 300s default timeout via `context.WithTimeout` +
  `cmd.WaitDelay = 10s`; configurable via `TEST_TIMEOUT` env var; exit code 124
  on timeout.

### P2 — High

- [X] **RR-3** ~~Add `mem_limit`, `cpus`, and `pids_limit` to all containers in
  `docker-compose.yml`; add `ulimit` to the test subprocess in `tester/main.go`.~~
  Done (2026-03-28). All six containers have `mem_limit`, `cpus`, and `pids_limit`.
  Per-container sizing rationale in `HARDENING.md`. Tester subprocess `ulimit`
  remains open (tracked separately).
- [X] **RR-4** ~~Introduce `TESTER_API_TOKEN` and `PLAN_API_TOKEN` separate from
  `MCP_API_TOKEN` to limit blast radius of a single token compromise.~~
  Done (2026-03-28). Each service now has its own token: MCP_API_TOKEN for
  mcp-server, PLAN_API_TOKEN for plan-server, TESTER_API_TOKEN for tester-server.
  claude-server holds all three. run.sh generates all three tokens; docker-compose.yml
  routes each token only to its intended container; verify_isolation.py enforces
  per-service token boundaries.
- [X] **RR-5** ~~Remove or reduce the `FILE_SUCCESS` full-content log line in
  `fileserver/main.go` (replace with length/hash summary).~~
  Done (2026-03-28). Replaced with `FILE_READ: <path> (<n> bytes, sha256=<hex>)`;
  regression test `TestReadContentNotLogged` added to `mcp_test.go`.
- [X] **RR-11** ~~Redact known secret patterns from `server.py` log output; move
  full Claude Code stdout/stderr to `DEBUG` level.~~
  Done (2026-03-28). `_redact_secrets()` redacts all known tokens; stdout/stderr
  moved to DEBUG; `LOG_LEVEL` env var added to `setuplogging.py` (default INFO).
  Unit tests for `_redact_secrets` added to `test_server.py`.

### P3 — Medium

- [X] **RR-6** ~~URL-encode path parameters in `files_mcp.py` using the `params=`
  kwarg to `requests.get/post` instead of string interpolation.~~ Done (2026-03-28).
- [X] **RR-7** ~~Strip directory components from slash-command names in `server.py`:
  add `name = os.path.basename(name)` (or reject names containing `/` or `..`).~~
  Done (2026-03-29). `os.path.basename(name)` applied before `os.path.join`; `PATH_BLACKLIST`
  rejects names with `..`, null bytes, and shell metacharacters. 11 unit tests added
  to `test_server.py` (`TestExpandSlashCommand`).
- [ ] **RR-8** Add rate limiting or concurrency cap on `/ask` and `/plan`
  endpoints (Caddy rate-limit directive or FastAPI semaphore).
- [X] **RR-9** ~~Add `cap_drop: [ALL]` to `claude-server`, `mcp-server`,
  `plan-server`, and `tester-server` in `docker-compose.yml`.~~
  Done (2026-03-28). All six containers now have `cap_drop: ALL`.

### P4 — Low / Polish

- [ ] **RR-10** Add cert expiry monitoring; document rotation procedure; consider
  90-day leaf cert lifetimes with automated renewal.
- [X] **RR-12** ~~Upgrade Go servers (`mcp-server/main.go`, `tester/main.go`) from
  `tls.VersionTLS12` to `tls.VersionTLS13`.~~
  Done (2026-03-29). Both servers now use `tls.VersionTLS13`; `TestTLSMinVersion13`
  unit tests verify TLS 1.2 connections are rejected.
- [ ] **RR-13** Document test output as an explicit trust boundary; consider
  capping `output` length returned by `tester-server`.
- [X] **RR-14** ~~Add maximum field-length validation to plan creation in
  `plan_server.py`; consider a human-review gate before a plan becomes `current`.~~
  Done (2026-03-30). Max-length constants and `_validate_field_lengths()` added to
  `plan_server.py`; enforced in `/plan` (create), `/task` (update), and `/block`
  endpoints. 11 unit tests in `TestFieldLengthValidation` cover all fields and
  boundary conditions. Human-review gate deferred as a separate open item.
- [ ] **RR-15** Validate `request.model` against an allowlist in `server.py`
  before passing it to the `--model` subprocess flag.
- [ ] Tag a release

### Additional hardening completed (not in original threat model)

- [X] **Egress filtering architecture** — proxy moved to `int_net` only; all
  outbound traffic routed through `caddy-sidecar:8081` which is hardcoded to
  `api.anthropic.com:443`. Blocks credential exfiltration to arbitrary domains.
- [X] **Container read-only filesystems** — `caddy-sidecar` and `proxy` have
  `read_only: true` with sized `tmpfs` mounts (`noexec,nosuid`).
- [X] **Caddy file capability stripping** — `setcap -r /usr/bin/caddy` in
  `Dockerfile.caddy` enables `cap_drop: ALL` without startup failures.
- [X] **CA certificate extensions** — added `basicConstraints`, `keyUsage`,
  `subjectKeyIdentifier` to internal CA for OpenSSL 3.x compatibility.
- [X] **Dependency security** — `requests` upgraded to 2.33.0 (vuln fix);
  `Dockerfile.claude` base image pinned to digest; `pip-audit` added for
  tester requirements in integration tests.
- [X] **Hardening documentation** — new `docs/HARDENING.md` with per-container
  security decisions, TeamPCP supply-chain attack analysis, and egress
  filtering architecture.

Repo-specific tasks: [agent PLAN.md](../cluster/agent/docs/PLAN.md),
[planner PLAN.md](../cluster/planner/docs/PLAN.md),
[tester PLAN.md](../cluster/tester/docs/PLAN.md)

---

## Out of Scope (this sprint)

- `git_push` / GitHub integration (requires credential isolation design)
- CI/CD pipeline for parent repo
- Multi-agent orchestration (review agent checking coding agent)


---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
| :--- | :--- | :--- | :--- |
| Claude Code version upgrade breaks --mcp-config or --print | Blocks everything | Medium | Pinned to @2.1.74; test before upgrading |
| Claude changes API contracts during task execution | Broken code | High | System prompt constraint + plan action specificity |
| Subprocess timeout too short for complex tasks | Incomplete work | Medium | 600s timeout; plan smaller tasks |
| Agent marks tasks complete without verifying | Correctness | Medium | Verify criteria in plan; test runner gate in Phase 4 |
| ~~Test runner subprocess hangs indefinitely~~ | ~~Resource exhaustion~~ | ~~Low~~ | ✅ Fixed: 300s `context.WithTimeout` + `cmd.WaitDelay` in `tester/main.go` (RR-2) |
| Vuln DB staleness in offline scans | Missed CVEs | Low | Security scans run in test-integration.sh with network access |
