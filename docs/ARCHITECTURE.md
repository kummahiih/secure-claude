# secure-claude: Security-Annotated Architecture

*Generated 2026-03-25. Authoritative reference for system design and security rationale.*

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Service Inventory](#2-service-inventory)
3. [Network Topology](#3-network-topology)
4. [Data Flow Diagrams](#4-data-flow-diagrams)
5. [Authentication & Authorization Chain](#5-authentication--authorization-chain)
6. [Filesystem Security Model](#6-filesystem-security-model)
7. [MCP Security Architecture](#7-mcp-security-architecture)
8. [Design Trade-offs](#8-design-trade-offs)
9. [Operational Security](#9-operational-security)
10. [Comparison to Alternatives](#10-comparison-to-alternatives)

---

## 1. System Overview

secure-claude is a hardened, containerized environment for running Anthropic's Claude Code CLI
as a fully autonomous AI agent. The agent can read, modify, test, and commit source code inside
a mounted workspace repository — including iterating on its own codebase — while operating under
a layered set of structural security constraints that confine what it can reach, see, or affect.

The system is built for teams who want the productivity of an autonomous coding agent without
accepting the risk of running an AI process that has access to production credentials, the host
filesystem, the parent repository, or unconstrained network egress. It supports a plan-then-execute
workflow: a human approves a structured plan, then the agent executes tasks, runs tests,
interprets failures, fixes code, and commits — all autonomously.

The core security thesis is: **enforce boundaries structurally, never by filtering**. Rather than
building prompt guardrails or output classifiers, every sensitive boundary is enforced by the OS,
the Docker network layer, Go's `os.OpenRoot` filesystem jail, TLS mutual authentication, token
isolation, and immutable read-only mounts. A compromised agent process still cannot escape its
container, reach the real Anthropic API key, write to the parent repository, execute git hooks,
or bypass filesystem containment — because the structures that would allow those things simply do
not exist inside the container.

---

## 2. Service Inventory

The cluster runs six containers, all on the internal Docker network except where noted.

---

### 2.1 caddy-sidecar

**Role:** TLS termination for external ingress; reverse-proxies `/ask` and `/plan` requests to
`claude-server`, and proxies egress LLM traffic to the host.

**Base image and build** (`Dockerfile.caddy`):
- Stage 1 (`alpine:3.23.3 AS signer`): Generates a unique 3072-bit RSA keypair for
  `caddy-sidecar` signed by the cluster CA. CA key never persists in the image — it is
  bind-mounted at build time via `--mount=type=bind` and removed when the build stage exits.
  SAN: `DNS:localhost,DNS:caddy-sidecar,IP:127.0.0.1`.
- Stage 2 (`caddy:2-alpine`): Copies the signed cert/key from Stage 1. Creates `caddyuser`
  (non-root). Copies `caddy_entrypoint.sh`.

**Runtime user:** `caddyuser` (non-root, created in image). No explicit UID pinning in this image.

**Exposed ports:**
- `8443` → host (external ingress) [TLS: internal CA]
- `8080` → internal only (egress proxy to host nginx)

**Environment variables consumed:**
- `HOST_DOMAIN` — forwarded as `Host:` header on egress proxy requests
- `XDG_DATA_HOME`, `XDG_CONFIG_HOME` — redirected to `/tmp` to avoid permission issues

**Volume mounts:**
- `./caddy/Caddyfile` → `/etc/caddy/Caddyfile:ro` — Caddy configuration (read-only)
- Certs are baked into the image (not mounted)

**Startup checks** (`caddy_entrypoint.sh`):
1. Checks that `ANTHROPIC_API_KEY` is absent [FORBIDDEN]
2. Checks that `DYNAMIC_AGENT_KEY` is absent [FORBIDDEN]
3. Checks that `MCP_API_TOKEN` is absent [FORBIDDEN]
4. Checks that `CLAUDE_API_TOKEN` is absent [FORBIDDEN]
5. Checks that `AGENT_API_TOKEN` is absent [FORBIDDEN]
6. Scans `/etc/caddy` for any `*.env` files [FORBIDDEN]

**Security annotations:**
- `admin off` in Caddyfile disables the Caddy admin API, preventing runtime config changes
- Caddy holds no credentials; it cannot authenticate to any backend service
- `tls_insecure_skip_verify` on egress proxy (port 8080 → host:443) is a known gap documented
  in PLAN.md under Phase 5 hardening — the host nginx uses a self-signed cert from a different
  CA. Fix: provision host with cluster CA cert and replace with `tls_trusted_ca_certs`.
- `tls_trusted_ca_certs /etc/caddy/certs/ca.crt` on ingress-side reverse proxy — Caddy
  validates the upstream claude-server cert against the cluster CA [TLS: internal CA]

---

### 2.2 claude-server

**Role:** FastAPI server hosting the `/ask` and `/plan` endpoints; spawns Claude Code CLI as a
subprocess for each request; runs all five MCP stdio servers as Claude Code child processes.

**Base image and build** (`Dockerfile.claude`):
- Stage 1 (`alpine:3.23.3 AS signer`): Generates 3072-bit RSA cert for `claude-server`.
  SAN: `DNS:localhost,DNS:claude-server,IP:127.0.0.1`.
- Stage 2 (`python:3.12-slim`): Installs Python deps, `curl`, `git`, Node.js 22.x,
  `@anthropic-ai/claude-code@2.1.74` (pinned). Creates `appuser` (UID 1000).
- Writes `.mcp.json` at build time (baked into image, root-owned, mode 440).
- Copies signed certs from Stage 1. Trusts cluster CA in system store and `certifi` bundle.
- Copies `agent/claude/*.py`, `planner/planner/plan_mcp.py`.
- System prompts copied to `/app/prompts/` (root-owned, mode 444, dir mode 555).
- Slash commands copied to `/home/appuser/.claude/commands/` (root-owned, mode 444, dir mode 555).
- `/app` locked to mode 550 (read+execute, no write for appuser).

**Runtime user:** `appuser` (UID 1000 / GID 1000). No capabilities granted.

**Exposed ports:**
- `8000` (HTTPS, internal only) — receives traffic from caddy-sidecar [TLS: internal CA]

**Environment variables consumed:**
```
DYNAMIC_AGENT_KEY      — ephemeral key; passed as ANTHROPIC_API_KEY to Claude Code subprocess
ANTHROPIC_BASE_URL     — https://proxy:4000 (LiteLLM)
MCP_API_TOKEN          — authenticates calls to mcp-server, plan-server, tester-server
CLAUDE_API_TOKEN       — validates Bearer token on /ask and /plan endpoints
MCP_SERVER_URL         — https://mcp-server:8443
PLAN_SERVER_URL        — https://plan-server:8443
TESTER_SERVER_URL      — https://tester-server:8443
GIT_DIR                — /gitdir (git data directory)
GIT_WORK_TREE          — /workspace (working tree for git ops)
DOCS_DIR               — /docs (read-only docs mount)
NODE_EXTRA_CA_CERTS    — /app/certs/ca.crt (Node.js / Claude Code CA trust)
```

**Volume mounts:**

| Host path              | Container path | Mode | Purpose                                    |
|------------------------|----------------|------|--------------------------------------------|
| `./workspace`          | `/workspace`   | `ro` | Source files (reads only; writes via MCP)  |
| `./workspace/.git`     | `/gitdir`      | `rw` | Git data directory (follows workspace symlink) |
| `./workspace/docs`     | `/docs`        | `ro` | Project docs for docs_mcp.py               |

**Startup checks** (`entrypoint.sh` + `verify_isolation.py claude-server`):

`verify_isolation.py` runs 26 checks before uvicorn starts:

*Forbidden env vars (1 check):*
1. `ANTHROPIC_API_KEY` must be absent — real key belongs only in proxy

*Required env vars (4 checks):*
2. `DYNAMIC_AGENT_KEY` present
3. `MCP_API_TOKEN` present
4. `CLAUDE_API_TOKEN` present
5. `ANTHROPIC_BASE_URL` present

*Forbidden paths (14 checks):*
6–19. None of: `/app/.secrets.env`, `/app/.cluster_tokens.env`, `/app/docker-compose.yml`,
       `/app/proxy_config.yaml`, `/app/Caddyfile`, `/workspace/.secrets.env`,
       `/workspace/.cluster_tokens.env`, `/workspace/docker-compose.yml`,
       `/workspace/proxy_config.yaml`, `/workspace/Caddyfile`,
       `/workspace/Dockerfile.claude`, `/workspace/Dockerfile.mcp`,
       `/workspace/Dockerfile.proxy`, `/workspace/Dockerfile.caddy`, `/workspace/certs`

*Required paths (6 checks):*
20. `/app/server.py` exists
21. `/app/files_mcp.py` exists
22. `/app/verify_isolation.py` exists
23. `/app/prompts` exists
24. `/home/appuser/.claude/commands` exists
25. `/home/appuser/sandbox/.mcp.json` exists

*Additional checks (2):*
26. `.env` file scan in `/app` and `/home/appuser`
27. MCP config validation: `mcpServers` key present, `fileserver` entry present
28. Prompt immutability: all prompt dirs and files root-owned (UID 0), not writable

After isolation checks, `entrypoint.sh` captures `git rev-parse HEAD` as `GIT_BASELINE_COMMIT`
and exports it. This env var is inherited by all Claude Code subprocesses and their MCP
server children — locking the `git_reset_soft` floor for the lifetime of the container.

**Security annotations:**
- `ANTHROPIC_API_KEY` never present at container level; only injected into Claude Code subprocess
  scope (`env={..., "ANTHROPIC_API_KEY": DYNAMIC_AGENT_KEY}` in `server.py`)
- Bearer token validated with `secrets.compare_digest` (constant-time) [AUTH: CLAUDE_API_TOKEN]
- Claude Code invoked with `--dangerously-skip-permissions` (no interactive prompts) and
  `--print` (non-interactive, single-shot); cwd is `/home/appuser/sandbox` (no workspace write access from cwd)
- Slash commands in `/home/appuser/.claude/commands/` are root-owned and immutable; agent
  cannot inject new commands or modify existing ones at runtime
- System prompts in `/app/prompts/` are root-owned, mode 444; immutability verified at startup

---

### 2.3 proxy (litellm-proxy)

**Role:** LiteLLM gateway holding the real `ANTHROPIC_API_KEY`; validates `DYNAMIC_AGENT_KEY`
as its master key; translates requests to the Anthropic API.

**Base image and build** (`Dockerfile.proxy`):
- Stage 1 (`alpine:3.23.3 AS signer`): Generates 3072-bit RSA cert for `proxy`.
  SAN: `DNS:proxy,DNS:localhost,IP:127.0.0.1`.
- Stage 2 (`ghcr.io/berriai/litellm:main-v1.82.3-stable.patch.2`): Installs cluster CA into
  system and `certifi` trust stores. Copies certs from Stage 1. Runs as UID 1000.

**Runtime user:** UID 1000 (LiteLLM default). `cap_drop: ALL` in docker-compose.yml.

**Exposed ports:**
- `4000` (HTTPS, internal only) — receives traffic from claude-server [TLS: internal CA]

**Environment variables consumed:**
```
ANTHROPIC_API_KEY    — real Anthropic key; used to authenticate upstream API calls
DYNAMIC_AGENT_KEY    — set as LITELLM_MASTER_KEY; validates agent requests
HOST_DOMAIN          — passed through for egress routing
```

**Volume mounts:**
- `./proxy/proxy_config.yaml` → `/tmp/config.yaml:ro` — LiteLLM model routing config
- `./proxy/proxy_wrapper.py` → `/app/proxy_wrapper.py:ro` — isolation check wrapper

**Startup checks** (`proxy_wrapper.py`):
1. `ANTHROPIC_API_KEY` present (required)
2. `DYNAMIC_AGENT_KEY` present (required)
3. `MCP_API_TOKEN` absent (forbidden)
4. `CLAUDE_API_TOKEN` absent (forbidden)

**Security annotations:**
- Only container that holds `ANTHROPIC_API_KEY` [CREDENTIAL ISOLATION]
- Agent's `DYNAMIC_AGENT_KEY` is the LiteLLM `master_key` — so the agent authenticates to
  proxy using its own ephemeral key, never the real key [AUTH: DYNAMIC_AGENT_KEY]
- `cap_drop: ALL` removes all Linux capabilities [LEAST PRIVILEGE]
- `dns: [8.8.8.8, 1.1.1.1]` + `ext_net` membership allows DNS resolution for Anthropic API
- `NO_PROXY=localhost,127.0.0.1,mcp-server,claude-server` prevents internal traffic from
  being accidentally routed through any system proxy

---

### 2.4 mcp-server

**Role:** Go REST server that manages read/write access to the workspace filesystem, protected
by an `os.OpenRoot` jail at `/workspace`.

**Base image and build** (`Dockerfile.mcp`):
- Stage 1 (`golang:1.26.1-alpine AS builder`): Compiles `fileserver/main.go` to a static binary.
- Stage 2 (`alpine:3.23.3 AS signer`): Generates 2048-bit RSA cert for `mcp-server`.
  SAN: `DNS:mcp-server,DNS:localhost,IP:127.0.0.1`.
- Stage 3 (`alpine:3.23.3`): Minimal Alpine runtime. Copies binary and certs.
  Creates `appuser` (UID 1000). Mode 600 on private key.

**Runtime user:** `appuser` (UID 1000). Specified as `user: "1000:1000"` in docker-compose.

**Exposed ports:**
- `8443` (HTTPS, internal only) — receives traffic from `files_mcp.py` [TLS: internal CA]

**Environment variables consumed:**
```
MCP_API_TOKEN    — validates Bearer token on all REST endpoints
```

**Volume mounts:**

| Host path       | Container path      | Mode | Purpose                                           |
|-----------------|---------------------|------|---------------------------------------------------|
| `./workspace`   | `/workspace`        | `rw` | Go fileserver reads and writes code               |
| tmpfs           | `/workspace/.git`   | `ro,size=0` | Shadows .git — structural hook prevention   |

**Startup checks** (`agent/fileserver/entrypoint.sh`):
1. `ANTHROPIC_API_KEY` absent (forbidden)
2. `CLAUDE_API_TOKEN` absent (forbidden)
3. `DYNAMIC_AGENT_KEY` absent (forbidden)
4. `MCP_API_TOKEN` present (required)
5. No `*.env` files in `/workspace`

**Security annotations:**
- `os.OpenRoot("/workspace")` called at startup (`main.go:483`); all file operations use the
  returned `*os.Root` handle — path traversal blocked at Go runtime level [JAIL: os.OpenRoot]
- Every handler validates `Authorization: Bearer <MCP_API_TOKEN>` with `crypto/subtle.ConstantTimeCompare` [AUTH: MCP_API_TOKEN]
- Additional input validation in `handleRead`: rejects empty paths, null bytes (`\x00`),
  paths > 4096 bytes before passing to `rootDir.Open`
- tmpfs shadow over `/workspace/.git` (size=0, read-only) prevents the Go process from
  reading or executing git hooks even if they existed in the gitdir [HOOK PREVENTION]
- No `ANTHROPIC_API_KEY`, `CLAUDE_API_TOKEN`, or `DYNAMIC_AGENT_KEY` — blast radius of
  mcp-server compromise limited to workspace filesystem

---

### 2.5 plan-server

**Role:** Python/FastAPI REST server managing structured plan state (JSON files in `/plans`);
the agent's only path to reading or advancing plan tasks.

**Base image and build** (`Dockerfile.plan`):
- Stage 1 (`alpine:3.23.3 AS signer`): Generates 2048-bit RSA cert for `plan-server`.
  SAN: `DNS:plan-server,DNS:localhost,IP:127.0.0.1`.
- Stage 2 (`python:3.12-slim`): Installs Python deps. Creates `appuser` (UID 1000).
  Copies `planner/planner/plan_server.py`. Trusts cluster CA. Mode 400 on private key.
  `/app` locked to mode 550.

**Runtime user:** `appuser` (UID 1000).

**Exposed ports:**
- `8443` (HTTPS, internal only) [TLS: internal CA]

**Environment variables consumed:**
```
MCP_API_TOKEN    — validates Bearer token on all endpoints
PLANS_DIR        — defaults to /plans
```

**Volume mounts:**
- `../plans` → `/plans:rw` — plan JSON files (parent repo directory, not workspace)

**Startup checks** (`plan_server.py verify_isolation()`):
1. `ANTHROPIC_API_KEY` absent (forbidden)
2. `CLAUDE_API_TOKEN` absent (forbidden)
3. `DYNAMIC_AGENT_KEY` absent (forbidden)
4. `MCP_API_TOKEN` present (required)
5. `/plans` directory exists
6–9. Forbidden paths absent: `/workspace`, `/gitdir`, `/docs`, `/app/server.py`, `/app/files_mcp.py`
10. `.env` file scan in `/app` and `/plans`

**Security annotations:**
- No access to `/workspace`, `/gitdir`, or any agent code — blast radius of compromise is
  strictly plan state files [ISOLATION: no workspace access]
- Plan files live in the *parent* repo (`../plans`), not the agent workspace — agent cannot
  modify plan files through the `fileserver` MCP tool [PLAN ISOLATION]
- Bearer token validated with `secrets.compare_digest` (constant-time) [AUTH: MCP_API_TOKEN]
- `plan_create` enforces 1–10 task limit; `update_task` restricts to whitelisted fields
  (`name`, `files`, `action`, `verify`, `done`) — status transitions only via `complete`/`block`
- Plan filenames use an HMAC tag: `plan-YYYY-MM-DD-<sha256[:5]>.json` — prevents trivial
  enumeration/forgery

---

### 2.6 tester-server

**Role:** Go REST server that runs `/workspace/test.sh` as an async subprocess and returns
the result; the agent's only path to running tests.

**Base image and build** (`Dockerfile.tester`):
- Stage 1 (`golang:1.26.1-alpine AS builder`): Compiles `tester/main.go`.
- Stage 2 (`alpine:3.23.3 AS signer`): Generates 2048-bit RSA cert for `tester-server`.
  SAN: `DNS:tester-server,DNS:localhost,IP:127.0.0.1`.
- Stage 3 (`python:3.12-slim`): Installs bash, git, Go 1.26.1, pytest, and agent Python
  deps (fastapi, uvicorn, pydantic, requests, mcp, mcp-watchdog) so that `test.sh` can
  run both Go and Python test suites. Creates `appuser` (UID 1000).
  `PYTEST_ADDOPTS="-p no:cacheprovider"` prevents pytest writing cache into read-only `/workspace`.

**Runtime user:** `appuser` (UID 1000).

**Exposed ports:**
- `8443` (HTTPS, internal only) [TLS: internal CA]

**Environment variables consumed:**
```
MCP_API_TOKEN    — validates Bearer token on /run and /results
TEST_SCRIPT      — defaults to /workspace/test.sh (override for testing)
```

**Volume mounts:**

| Host path      | Container path | Mode | Purpose                                              |
|----------------|----------------|------|------------------------------------------------------|
| `./workspace`  | `/workspace`   | `ro` | Test runner reads source, executes test.sh           |

**Startup checks** (`tester/entrypoint.sh`):
1. `ANTHROPIC_API_KEY` absent (forbidden)
2. `CLAUDE_API_TOKEN` absent (forbidden)
3. `DYNAMIC_AGENT_KEY` absent (forbidden)
4. `MCP_API_TOKEN` present (required)
5. `/workspace` directory mounted

**Security annotations:**
- `/workspace:ro` — tests can never modify source code [READ-ONLY]
- No access to `/gitdir`, `/plans`, or any credentials [ISOLATION]
- Concurrent run rejection (HTTP 409) prevents resource exhaustion from parallel test invocations
- `go func()` goroutine runs `test.sh` with `cmd.Dir = "/workspace"` and `HOME=/home/appuser`;
  no sensitive env vars are forwarded to the subprocess [ENV SANITIZATION]
- Bearer token validated with `crypto/subtle.ConstantTimeCompare` [AUTH: MCP_API_TOKEN]

---

## 3. Network Topology

### Docker Networks

```
┌─────────────────────────────────────────────────────────────────────────┐
│  HOST                                                                   │
│                                                                         │
│  ┌── ext_net (bridge, internet-routable) ───────────────────────────┐  │
│  │                                                                   │  │
│  │  caddy-sidecar (:8443 → host)                                    │  │
│  │  litellm-proxy  (DNS: 8.8.8.8, 1.1.1.1)                         │  │
│  │                                                                   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌── int_net (internal: true, NO host routing) ──────────────────────┐  │
│  │                                                                   │  │
│  │  caddy-sidecar   claude-server   litellm-proxy                   │  │
│  │  mcp-server      plan-server     tester-server                   │  │
│  │                                                                   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

`int_net` is declared `internal: true` — Docker blocks routing to/from the host network
on this bridge. No container on `int_net` alone can reach the internet.

`claude-server`, `mcp-server`, `plan-server`, and `tester-server` are on **int_net only**.
They have zero internet access — enforced by the network driver, not firewall rules.

`caddy-sidecar` and `litellm-proxy` are on **both networks**:
- `caddy-sidecar` bridges external HTTPS ingress → internal claude-server, and also
  proxies LLM egress (port 8080 → `host.docker.internal:443`)
- `litellm-proxy` needs internet (DNS configured explicitly: 8.8.8.8/1.1.1.1) to reach
  `api.anthropic.com`

### Reachability Matrix

| From ↓ \ To →    | caddy | claude-server | proxy | mcp-server | plan-server | tester-server | internet |
|------------------|-------|---------------|-------|------------|-------------|---------------|----------|
| **External**     | ✓ 8443| ✗             | ✗     | ✗          | ✗           | ✗             | —        |
| **caddy**        | —     | ✓ 8000        | ✗     | ✗          | ✗           | ✗             | ✓ (egress proxy) |
| **claude-server**| ✗     | —             | ✓ 4000| ✓ 8443     | ✓ 8443      | ✓ 8443        | ✗        |
| **proxy**        | ✗     | ✗             | —     | ✗          | ✗           | ✗             | ✓        |
| **mcp-server**   | ✗     | ✗             | ✗     | —          | ✗           | ✗             | ✗        |
| **plan-server**  | ✗     | ✗             | ✗     | ✗          | —           | ✗             | ✗        |
| **tester-server**| ✗     | ✗             | ✗     | ✗          | ✗           | —             | ✗        |

### TLS Hop Summary

Every service-to-service connection uses TLS with the cluster's internal CA:

| Hop                              | Protocol   | Auth mechanism            | Encryption         |
|----------------------------------|------------|---------------------------|--------------------|
| External → caddy-sidecar:8443    | HTTPS/TLS  | Bearer CLAUDE_API_TOKEN   | TLS 1.2+ (cluster CA) |
| caddy → claude-server:8000       | HTTPS/TLS  | Cert validation (CA)      | TLS (cluster CA)   |
| claude-server → proxy:4000       | HTTPS/TLS  | Bearer DYNAMIC_AGENT_KEY  | TLS (cluster CA)   |
| claude-server → mcp-server:8443  | HTTPS/TLS  | Bearer MCP_API_TOKEN      | TLS (cluster CA)   |
| claude-server → plan-server:8443 | HTTPS/TLS  | Bearer MCP_API_TOKEN      | TLS (cluster CA)   |
| claude-server → tester-server:8443| HTTPS/TLS | Bearer MCP_API_TOKEN      | TLS (cluster CA)   |
| proxy → api.anthropic.com        | HTTPS/TLS  | Bearer ANTHROPIC_API_KEY  | TLS (public CA)    |
| caddy egress → host:443          | HTTPS/TLS  | (none — `tls_insecure_skip_verify`) | TLS (⚠ unvalidated) |

### Full Packet Path: External Query

```
query.sh (host)
  │  Bearer CLAUDE_API_TOKEN
  ▼
caddy-sidecar:8443   [TLS terminate: cluster CA cert]
  │  TLS re-establish  [AUTH: ca.crt validates claude-server cert]
  ▼
claude-server:8000   [FastAPI, verify_token()]
  │  subprocess: claude --print --mcp-config .mcp.json ...
  │    env: ANTHROPIC_API_KEY=DYNAMIC_AGENT_KEY
  ▼
Claude Code CLI (subprocess)
  │  ANTHROPIC_BASE_URL=https://proxy:4000
  │  Bearer DYNAMIC_AGENT_KEY
  ▼
litellm-proxy:4000   [TLS, validates DYNAMIC_AGENT_KEY as master_key]
  │  Bearer ANTHROPIC_API_KEY
  ▼
api.anthropic.com   [Public TLS]
```

---

## 4. Data Flow Diagrams

### Flow A: User Query Execution (/ask)

```
┌─────────────────────────────────────────────────────────────────────────┐
│ query.sh                                                                │
│   POST https://localhost:8443/ask                                       │
│   Header: Authorization: Bearer <CLAUDE_API_TOKEN>                     │
│   Body: {"query": "...", "model": "claude-sonnet-4-6"}                 │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │ [TLS: cluster CA] [AUTH: CLAUDE_API_TOKEN]
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ caddy-sidecar:8443                                                      │
│   - TLS termination (caddy.crt / caddy.key)                            │
│   - No auth check (passes through to claude-server)                    │
│   - Re-establishes TLS to claude-server:8000 (validates ca.crt)        │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │ [TLS: cluster CA]
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ claude-server:8000  /ask                                                │
│   - verify_token(): secrets.compare_digest(creds, CLAUDE_API_TOKEN)    │
│   - _expand_slash_command(): load /home/appuser/.claude/commands/*.md  │
│   - subprocess.run(["claude", "--print", "--mcp-config", ...], ...)    │
│     env: ANTHROPIC_API_KEY=DYNAMIC_AGENT_KEY (injected here only)      │
│     cwd: /home/appuser/sandbox                                          │
│     timeout: 600s                                                       │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │ subprocess
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Claude Code CLI (subprocess, UID 1000)                                  │
│   - Loads /home/appuser/sandbox/.mcp.json                              │
│   - Starts MCP stdio servers (via mcp-watchdog):                       │
│     • mcp-watchdog -- python3 /app/files_mcp.py  (stdin/stdout)        │
│     • mcp-watchdog -- python3 /app/git_mcp.py    (stdin/stdout)        │
│     • mcp-watchdog -- python3 /app/docs_mcp.py   (stdin/stdout)        │
│     • mcp-watchdog -- python3 /app/plan_mcp.py   (stdin/stdout)        │
│     • mcp-watchdog -- python3 /app/tester_mcp.py (stdin/stdout)        │
│   - Sends LLM requests to ANTHROPIC_BASE_URL=https://proxy:4000        │
│     Bearer: DYNAMIC_AGENT_KEY                                           │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │ Bearer DYNAMIC_AGENT_KEY [TLS: cluster CA]
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ litellm-proxy:4000                                                      │
│   - Validates DYNAMIC_AGENT_KEY as LITELLM_MASTER_KEY                  │
│   - Routes to Anthropic API with real ANTHROPIC_API_KEY                │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │ Bearer ANTHROPIC_API_KEY [TLS: public CA]
                               ▼
                     api.anthropic.com
```

---

### Flow B: Plan Creation (/plan)

```
plan.sh → POST /plan (Bearer CLAUDE_API_TOKEN)
  → caddy-sidecar (TLS, pass-through)
  → claude-server /plan
      verify_token()
      subprocess: claude --system-prompt PLAN_SYSTEM_PROMPT ...
      (same MCP servers, same LLM path as /ask)
      Claude Code calls plan_create via plan_mcp.py:
        plan_mcp.py → POST https://plan-server:8443/plan (Bearer MCP_API_TOKEN)
          plan_server.py: validates token, enforces 1–10 tasks, writes
            /plans/plan-YYYY-MM-DD-<hmac>.json
      Returns plan summary to claude-server
  → JSON response to plan.sh
```

*Note: The `/plan` endpoint uses `PLAN_SYSTEM_PROMPT` (from `ask.md` partner `plan.md`),
which instructs the agent to produce only a plan structure — no code execution.*

---

### Flow C: MCP File Operation

```
Claude Code (tool call: write_file)
  │  JSON-RPC over stdin
  ▼
mcp-watchdog (intercepts all JSON-RPC)          [MCP SECURITY PROXY]
  │  Inspects tool name, arguments, blocks 40+ attack classes
  │  --verbose logging of all intercepted calls
  ▼
files_mcp.py (MCP stdio server)
  │  _dispatch("write_file", {"path": "...", "content": "..."})
  │  requests.post(MCP_SERVER_URL + "/write", ...)
  │  headers: Authorization: Bearer MCP_API_TOKEN   [AUTH: MCP_API_TOKEN]
  │  verify: /app/certs/ca.crt                       [TLS: internal CA]
  ▼
mcp-server:8443 /write
  │  verifyToken(): crypto/subtle.ConstantTimeCompare
  │  json.Decode(req) → {path, content}
  │  rootDir.OpenFile(path, O_WRONLY|O_CREATE|O_TRUNC, 0644)
  │                                                   [JAIL: os.OpenRoot]
  ▼
/workspace/<path>  (bind-mounted sub-repo, rw)
```

*Path traversal attempts (e.g., `../../etc/passwd`) are rejected by `os.OpenRoot` at the
Go runtime level — the `rootDir.OpenFile` call returns an error regardless of the path string.*

---

### Flow D: Test Execution

```
Claude Code (tool call: run_tests)
  │  JSON-RPC stdin
  ▼
mcp-watchdog
  ▼
tester_mcp.py
  │  requests.post(TESTER_SERVER_URL + "/run", headers=HEADERS, verify=VERIFY)
  │  [AUTH: MCP_API_TOKEN] [TLS: internal CA]
  ▼
tester-server:8443 /run
  │  verifyToken() [AUTH: MCP_API_TOKEN]
  │  Rejects if result.Status == "running" (409 Conflict)
  │  Sets result.Status = "running"
  │  go func(): exec.Command("bash", "/workspace/test.sh")
  │             cmd.Dir = "/workspace"  (read-only mount)
  │             CombinedOutput() captures stdout+stderr
  │  Returns {"status":"started"} immediately
  ▼
/workspace/test.sh (subprocess, UID 1000)
  Runs: go test ./... + python -m pytest
  No network access (int_net, internal: true)
  No write access (/workspace:ro mount)

  Poll: Claude Code calls get_test_results
    tester_mcp.py → GET /results [AUTH: MCP_API_TOKEN]
    Returns: {"status":"pass|fail","exit_code":N,"output":"..."}
```

---

### Flow E: Git Commit

```
Claude Code (tool call: git_add + git_commit)
  │  JSON-RPC stdin
  ▼
mcp-watchdog
  ▼
git_mcp.py
  │  git_add(paths):
  │    git_env_for(file_path) → detects root vs submodule via .gitmodules
  │    returns (env, GIT_DIR, GIT_WORK_TREE)
  │    _run_git_env(env, "add", "--", *paths)
  │
  │  git_commit(message):
  │    _run_git_env(env, "commit", "-m", msg, "--no-verify")
  │    Every git call: git -c core.hooksPath=/dev/null ...  [HOOK: /dev/null]
  ▼
git subprocess
  │  GIT_DIR=/gitdir              [STRUCTURALLY LOCKED: env var]
  │  GIT_WORK_TREE=/workspace     [STRUCTURALLY LOCKED: env var]
  │  core.hooksPath=/dev/null     [HOOK PREVENTION: layer 1]
  │  --no-verify flag             [HOOK PREVENTION: layer 2]
  │  tmpfs at /workspace/.git     [HOOK PREVENTION: layer 3, in mcp-server]
  ▼
/gitdir  (bind mount: ./workspace/.git, rw)
```

*Three independent hook-prevention layers: (1) `core.hooksPath=/dev/null` on every git call,
(2) `--no-verify` on git commit, (3) tmpfs shadow over `/workspace/.git` in mcp-server
(different container — irrelevant to git_mcp.py, but prevents any rogue git invocation
within mcp-server from executing hooks).*

*Submodule routing: `parse_gitmodules()` reads `/workspace/.gitmodules`; `git_env_for()`
maps file paths to their owning repo, resolving submodule gitdirs at
`/gitdir/modules/<submodule_path>`. Per-submodule baseline commits captured at startup.*

---

## 5. Authentication & Authorization Chain

### Token Generation (`run.sh`)

All tokens are generated fresh on every `run.sh` invocation (every cluster start):

```bash
DYNAMIC_AGENT_KEY="sk-$(openssl rand -hex 16)"   # 128-bit entropy, sk- prefix
MCP_API_TOKEN=$(openssl rand -hex 32)              # 256-bit entropy
CLAUDE_API_TOKEN=$(openssl rand -hex 32)           # 256-bit entropy
```

Tokens are written to `.env` (Docker Compose format) and `.cluster_tokens.env` (export format
for `query.sh`). Neither file is committed to git (`.gitignore`). The CA keypair in
`cluster/certs/ca.key` persists across restarts (regenerated only if absent); leaf certs for
each service are regenerated on every Docker build.

### Token Isolation Matrix

| Token             | claude-server | proxy   | mcp-server | plan-server | tester-server | caddy   |
|-------------------|---------------|---------|------------|-------------|---------------|---------|
| ANTHROPIC_API_KEY | ✗ FORBIDDEN   | ✓ REQUIRED | ✗ FORBIDDEN | ✗ FORBIDDEN | ✗ FORBIDDEN | ✗ FORBIDDEN |
| DYNAMIC_AGENT_KEY | ✓ REQUIRED    | ✓ REQUIRED | ✗ FORBIDDEN | ✗ FORBIDDEN | ✗ FORBIDDEN | ✗ FORBIDDEN |
| CLAUDE_API_TOKEN  | ✓ REQUIRED    | ✗ FORBIDDEN | ✗ FORBIDDEN | ✗ FORBIDDEN | ✗ FORBIDDEN | ✗ FORBIDDEN |
| MCP_API_TOKEN     | ✓ REQUIRED    | ✗ FORBIDDEN | ✓ REQUIRED | ✓ REQUIRED  | ✓ REQUIRED    | ✗ FORBIDDEN |

Each container's startup checks enforce these constraints: presence of a forbidden token causes
`sys.exit(1)` before the server binds any port.

### Validation Points

```
External caller → [CLAUDE_API_TOKEN] → claude-server (secrets.compare_digest)
Claude Code     → [DYNAMIC_AGENT_KEY] → proxy (LiteLLM master_key)
files_mcp.py    → [MCP_API_TOKEN] → mcp-server (crypto/subtle.ConstantTimeCompare)
plan_mcp.py     → [MCP_API_TOKEN] → plan-server (secrets.compare_digest)
tester_mcp.py   → [MCP_API_TOKEN] → tester-server (crypto/subtle.ConstantTimeCompare)
```

All validations use constant-time comparison to prevent timing oracle attacks.

### Token Lifecycle

Tokens are **ephemeral** — they exist only for the lifetime of the cluster. On `run.sh`:
1. Old `.env` and `.cluster_tokens.env` are deleted
2. New tokens are generated with `openssl rand`
3. Containers are rebuilt and restarted with new tokens baked into environment

There is no token rotation mid-session. If a token is compromised during a session, the
remediation is to stop the cluster and run `run.sh` again.

### Blast Radius Analysis

| Compromised token     | What attacker gains                                    | What they cannot reach |
|-----------------------|-------------------------------------------------------|------------------------|
| CLAUDE_API_TOKEN      | Can submit queries to /ask or /plan                   | No access to workspace, git, plans, or real API key |
| DYNAMIC_AGENT_KEY     | Can make LLM API calls (costs money)                  | No access to workspace, git, or plans |
| MCP_API_TOKEN         | Read/write workspace files, read/write plans, run tests | No access to real API key, no host escape |
| ANTHROPIC_API_KEY     | Direct Anthropic API access (outside cluster)         | No access to workspace or cluster internals |

---

## 6. Filesystem Security Model

### Workspace Symlink and Repo Switching

The `cluster/workspace` path is a **symlink** that points to the currently active sub-repo:

```
cluster/workspace → cluster/agent/    (to work on agent code)
cluster/workspace → cluster/planner/  (to work on planner code)
cluster/workspace → cluster/tester/   (to work on tester code)
cluster/workspace → /path/to/external-working-copy/  (self-development)
```

Docker bind mounts resolve symlinks at mount time, so switching the workspace symlink and
restarting the cluster changes which repo the agent operates on without any docker-compose.yml
edits.

Three independent bind mounts follow the symlink:
- `./workspace` → `/workspace:ro` (claude-server: source read)
- `./workspace` → `/workspace:rw` (mcp-server: source write)
- `./workspace/.git` → `/gitdir:rw` (claude-server: git operations)
- `./workspace/docs` → `/docs:ro` (claude-server: docs access)
- `./workspace` → `/workspace:ro` (tester-server: test execution)

### os.OpenRoot Jail

`mcp-server/main.go` opens the workspace jail once at startup:

```go
rootDir, err := os.OpenRoot("/workspace")  // line 483
```

`os.OpenRoot` (introduced in Go 1.24) returns an `*os.Root` handle bound to the directory.
All subsequent file operations — `Open`, `OpenFile`, `Remove`, `Mkdir`, `WalkDir` — use this
handle. The Go runtime enforces that no path operation through this handle can escape the
root directory, regardless of:
- Symlinks (not followed outside the root)
- `../` sequences (resolved within the jail)
- Null bytes (still blocked by additional input validation in handlers)
- Absolute paths (treated as relative to jail root)

This is a kernel-level guarantee (via `openat2(2)` with `RESOLVE_BENEATH`), not string filtering.
[JAIL: os.OpenRoot]

### tmpfs Shadow over .git

In `docker-compose.yml`:

```yaml
mcp-server:
  volumes:
    - ./workspace:/workspace        # rw mount of workspace
  tmpfs:
    - /workspace/.git:ro,size=0     # Shadow over .git
```

The tmpfs overlay (`size=0`, read-only) is mounted *after* the bind mount. From inside
mcp-server, `/workspace/.git` appears as an empty, read-only tmpfs — the actual `.git`
directory contents are invisible. This ensures:
1. Go code in mcp-server cannot read git hooks from the gitdir
2. Any rogue git subprocess spawned from mcp-server finds no hooks to execute
3. Even if `os.OpenRoot` were somehow bypassed, hook execution would fail (no hooks visible)

This is the third layer of git hook prevention for mcp-server. (The primary hook prevention
for git operations is in `git_mcp.py` via `core.hooksPath=/dev/null`.)

### Read-Only vs Read-Write Mount Decisions

| Mount                     | Mode | Rationale                                                              |
|---------------------------|------|------------------------------------------------------------------------|
| claude-server `/workspace` | `ro` | Agent reads source via MCP; writes go through mcp-server REST API     |
| claude-server `/gitdir`    | `rw` | git_mcp.py needs to write commits, stage files                        |
| claude-server `/docs`      | `ro` | Docs are reference material; agent must not modify them               |
| mcp-server `/workspace`    | `rw` | This is the write path; os.OpenRoot provides the jail                 |
| tester-server `/workspace` | `ro` | Tests must never modify source; enforced at mount level               |
| plan-server `/plans`       | `rw` | Plan state must be writable; no workspace access                      |

### Git Directory Separation

The git data directory (`/gitdir`) is separated from the working tree (`/workspace`):

- `GIT_DIR=/gitdir` — git looks here for refs, objects, config, hooks
- `GIT_WORK_TREE=/workspace` — git looks here for the working files
- `/workspace/.git` in mcp-server is shadowed by tmpfs (invisible)
- `/workspace/.git` in claude-server is bind-mounted as `/gitdir` (the actual git data)

This separation means:
- mcp-server (which has workspace write access) **cannot** read or write git metadata
- claude-server's git operations via `git_mcp.py` use the real gitdir, but the workspace
  is mounted read-only — git can read the working tree but not create/modify files directly
- The agent can commit code changes made via the MCP fileserver, but cannot use git to
  write arbitrary content to the working tree

---

## 7. MCP Security Architecture

### stdio → REST Translation Pattern

All MCP servers follow the same pattern:

```
Claude Code ←stdio/JSON-RPC→ mcp-watchdog ←→ python3 <server>.py ←HTTPS/REST→ backend
```

Claude Code communicates with MCP servers via **stdio** (JSON-RPC over stdin/stdout). Each
MCP server (`files_mcp.py`, `git_mcp.py`, etc.) is a Python process that:
1. Implements the MCP protocol using the `mcp` SDK (`Server`, `stdio_server`)
2. Translates tool calls into either HTTPS REST calls or local subprocesses
3. Returns results as MCP `CallToolResult` objects

This pattern was chosen because the backend services (`mcp-server`, `plan-server`,
`tester-server`) speak REST, not the MCP protocol. A stdio wrapper bridges the two
without requiring the backends to implement MCP. It also keeps backends simple,
independently testable Go/Python services.

### mcp-watchdog

`mcp-watchdog` (v0.1.9, from `bountyyfi/mcp-watchdog`) is the command prefix for every
MCP server in `.mcp.json`:

```json
"fileserver": {
  "command": "mcp-watchdog",
  "args": ["--verbose", "--", "python3", "/app/files_mcp.py"]
}
```

`mcp-watchdog` sits between Claude Code and the Python MCP server, intercepting all
JSON-RPC traffic (both directions) over stdio. It blocks 40+ attack classes including:
- Prompt injection via tool results
- Tool schema poisoning
- Malicious `initialize` responses
- Oversized payloads
- Protocol-level attacks on the JSON-RPC framing

`--verbose` enables logging of all intercepted messages to stderr. The watchdog wraps
all five MCP servers (fileserver, git, docs, planner, tester).

### Tool Registration and .mcp.json

The authoritative `.mcp.json` is **baked into the Docker image** at build time
(`Dockerfile.claude`, lines ~60–88):

```dockerfile
COPY --chown=appuser:appgroup <<EOF /home/appuser/sandbox/.mcp.json
{ "mcpServers": { "fileserver": {...}, "git": {...}, ... } }
EOF
```

The file is owned by `appuser` but the directory `/home/appuser/sandbox` is mode 500
(owner execute only — no write). The agent cannot add, remove, or modify MCP server
registrations at runtime. The `verify_isolation.py` startup check confirms the file
exists and contains valid `mcpServers.fileserver` entry.

A reference copy with full tool schemas lives in `docs/mcp-tools.json` (readable via the
docs MCP tool) but is not the authoritative runtime config.

Claude Code is invoked with `--mcp-config /home/appuser/sandbox/.mcp.json` explicitly,
rather than relying on auto-discovery, because `--print` mode does not auto-discover
config from the default location.

### Input Validation per MCP Tool

| Tool / Handler    | Validated at     | What's checked                                                  |
|-------------------|------------------|-----------------------------------------------------------------|
| `read_workspace_file` | `handleRead` (Go) | path non-empty, no null bytes, ≤4096 bytes; then os.OpenRoot  |
| `write_file`      | `handleWrite` (Go) | JSON decode; os.OpenRoot rejects traversal                    |
| `delete_file`     | `handleRemove` (Go)| os.OpenRoot enforces jail                                     |
| `create_file`     | `handleCreate` (Go)| O_CREATE|O_EXCL prevents overwrite; os.OpenRoot jail          |
| `grep_files`      | `handleGrep` (Go)  | pattern non-empty; `regexp.Compile` validates regex           |
| `replace_in_file` | `handleReplace` (Go)| path non-empty; returns 422 if zero matches (fail-closed)    |
| `append_file`     | `handleAppend` (Go)| path non-empty; os.OpenRoot jail                              |
| `create_directory`| `handleMkdir` (Go) | path non-empty; os.IsExist → 409                              |
| `git_add`         | `git_mcp.py`       | paths non-empty; cross-repo detection; converts to abs paths  |
| `git_commit`      | `git_mcp.py`       | message non-empty; `--no-verify` always set                   |
| `git_reset_soft`  | `git_mcp.py`       | count 1–5; baseline floor enforcement via merge-base check    |
| `read_doc`        | `docs_mcp.py`      | `os.path.realpath` check — path must stay inside DOCS_DIR     |
| `plan_create`     | `plan_server.py`   | 1–10 tasks; task fields required                              |
| `plan_complete`   | `plan_server.py`   | task_id must match current task (prevents out-of-order ops)   |
| `plan_update_task`| `plan_server.py`   | field whitelisted; files field must be valid JSON array       |
| `run_tests`       | `tester/main.go`   | 409 if run already in progress; script existence check        |

---

## 8. Design Trade-offs

### Claude Code CLI subprocess vs. SDK integration

| | |
|---|---|
| **Chosen** | Spawn `claude --print` as a subprocess per request |
| **Rejected** | Use Anthropic Python SDK with tool-calling loop |
| **Why** | Claude Code CLI handles tool orchestration, retry logic, multi-step reasoning, and MCP protocol natively. Building equivalent orchestration in Python would replicate the Claude Code codebase without its hardening. |
| **Security implication** | Subprocess boundary means Claude Code cannot directly call Python functions; it can only interact through the MCP stdio protocol, which mcp-watchdog intercepts |
| **Known limitation** | Claude Code version must be pinned (`@2.1.74`); flag behavior (especially `--print`, `--mcp-config`, `--output-format json`) may change between versions |

### stdio MCP wrappers vs. direct HTTP MCP protocol

| | |
|---|---|
| **Chosen** | Python stdio wrappers translate MCP → REST calls |
| **Rejected** | Backends implement the MCP HTTP transport directly |
| **Why** | REST backends are simpler, independently testable, and language-agnostic. stdio wrappers are small and co-located with the agent code. |
| **Security implication** | The translation layer adds a validation surface (each wrapper can check arguments before forwarding). The mcp-watchdog wraps the stdio layer, not the REST layer — but the REST layer has its own auth and input validation. |
| **Known limitation** | Two serialization/deserialization steps per tool call |

### Submodule split vs. monorepo

| | |
|---|---|
| **Chosen** | Parent repo (secure-claude) + agent/planner/tester as git submodules |
| **Rejected** | All code in one repo |
| **Why** | The agent workspace can be any submodule; the parent repo contains Dockerfiles, certs, secrets, and cluster config that must not be visible to the agent. A submodule mount ensures the agent sees only its own code. |
| **Security implication** | Parent repo artifacts (Dockerfiles, docker-compose.yml, .secrets.env) are verified absent from `/workspace` at startup (14 forbidden path checks) |
| **Known limitation** | Git identity must be propagated to submodules before mounting (documented in WORKSPACE_INTERFACE.md) |

### Plan storage in parent repo vs. agent workspace

| | |
|---|---|
| **Chosen** | `../plans` (parent repo directory) mounted into plan-server |
| **Rejected** | Plans stored inside the agent workspace |
| **Why** | If plans were in the workspace, the agent could modify them via the `fileserver` MCP tool, circumventing the plan-server's access controls and status transition logic |
| **Security implication** | Agent has no filesystem path to plan files; only the plan-server REST API (with structured endpoints) can mutate plans |
| **Known limitation** | Plans are not committed to the agent workspace repo; they accumulate in the parent repo's `plans/` directory |

### Pinned Claude Code version vs. latest

| | |
|---|---|
| **Chosen** | `@anthropic-ai/claude-code@2.1.74` pinned in Dockerfile.claude |
| **Rejected** | `@latest` or unpinned |
| **Why** | `--print` mode and `--mcp-config` behavior, output format (`--output-format json`), and subprocess environment passing have all changed between versions. Unpinned installs risk silent breakage at rebuild time. |
| **Security implication** | Known-good version means no surprise changes to permission model or tool execution |
| **Known limitation** | Security patches in newer versions require manual version bump and test cycle |

### Direct subprocess test runner vs. Docker-in-Docker

| | |
|---|---|
| **Chosen** | `exec.Command("bash", "/workspace/test.sh")` inside tester-server container |
| **Rejected** | Mount Docker socket; spawn sibling containers for test isolation |
| **Why** | Docker socket access would give the agent an escape path (could spawn arbitrary containers, access host filesystem). Direct subprocess is simpler and requires no elevated privileges. |
| **Security implication** | Tests run as `appuser` (UID 1000) with no capabilities; `/workspace:ro` prevents test modification of source; no network (int_net, internal: true) |
| **Known limitation** | Test process inherits tester-server's network isolation (no internet in unit tests); resource exhaustion risk if test.sh hangs (Phase 5: add timeout) |

### Shared MCP_API_TOKEN vs. per-service tokens

| | |
|---|---|
| **Chosen** | One `MCP_API_TOKEN` shared across mcp-server, plan-server, tester-server |
| **Rejected** | Separate token per backend service |
| **Why** | Reduces operational complexity; all three services are equally trusted internal endpoints; a compromised `files_mcp.py` already has `MCP_API_TOKEN` in scope |
| **Security implication** | Compromise of any one MCP wrapper gives access to all three backends. Mitigated by: each backend has independent auth check; blast radius is still limited to workspace R/W + plans R/W + test execution — no credential access |
| **Known limitation** | PLAN.md notes a separate `PLAN_API_TOKEN` as out-of-scope but worth adding |

### System prompts as files vs. inline strings

| | |
|---|---|
| **Chosen** | System prompts loaded from `/app/prompts/ask.md` and `/app/prompts/plan.md` at startup |
| **Rejected** | Inline string literals in server.py or docker-compose environment |
| **Why** | Files allow the prompts to live in the agent submodule (`cluster/agent/prompts/system/`) where they can be version-controlled, reviewed, and updated independently of the server code |
| **Security implication** | Prompt files are root-owned, mode 444, directory mode 555 — agent cannot modify its own instructions at runtime. Verified by `check_prompt_immutability()` at startup. |
| **Known limitation** | Prompt changes require a Docker image rebuild |

---

## 9. Operational Security

### Certificate Generation and Rotation

The cluster uses a **self-signed CA** generated by `run.sh`:

```bash
# Generated once (persists in cluster/certs/ca.key, cluster/certs/ca.crt):
openssl genrsa -out cluster/certs/ca.key 4096
openssl req -x509 ... -days 3650 -out cluster/certs/ca.crt
```

Leaf certificates for each service are generated **at Docker build time** via a dedicated
`signer` stage in each Dockerfile. The CA private key is bind-mounted into the build stage
(`--mount=type=bind`) and is never written to any image layer. Each leaf cert is 365-day RSA
(2048 or 3072 bit depending on service) with per-service SAN (DNS + IP).

To rotate all leaf certs: run `run.sh` (which triggers `docker-compose up --build --force-recreate`).
To rotate the CA: delete `cluster/certs/ca.key` and `cluster/certs/ca.crt`, then run `run.sh`.
All containers trust only the cluster CA (`ca.crt` injected into system store, certifi, and
Node.js at build time).

### Secret Management

`.secrets.env` holds `ANTHROPIC_API_KEY` and `HOST_DOMAIN`:
- Listed in `.gitignore` and `.dockerignore` — never committed or included in images
- Loaded by `run.sh` via `source .secrets.env`; not passed directly to Docker Compose
- `run.sh` generates ephemeral tokens (`DYNAMIC_AGENT_KEY`, `MCP_API_TOKEN`, `CLAUDE_API_TOKEN`)
  into `.env` on every cluster start

`.env` and `.cluster_tokens.env` are:
- Deleted at the start of each `run.sh` run (`rm -f .env .cluster_tokens.env`)
- Not committed (`.gitignore`)
- The verify_isolation checks on each container confirm that secret files are not present
  inside any container image at paths like `/app/.secrets.env` or `/workspace/.secrets.env`

### Log Handling

- All Python services use `logging` module; level configured at startup
- `verify_isolation.py` logs each check violation to stderr before exiting
- `server.py` logs query text, stdout/stderr/returncode of each Claude Code subprocess invocation
  (NOTE: this includes the full model response in logs — no current output sanitization)
- `main.go` (fileserver) logs `FILE_SUCCESS`, `FILE_WRITTEN`, `FILE_REMOVED`, etc. per operation
- `mcp-watchdog --verbose` logs all JSON-RPC messages intercepted
- No structured log aggregation currently; logs available via `docker logs <container>`
- **Gap:** Claude Code subprocess stdout (model output) is logged verbatim in `server.py` —
  if the model echoes any secret it received via tool results, it would appear in logs

### Upgrade Path for Claude Code Version Changes

1. Update `npm install -g @anthropic-ai/claude-code@<new-version>` in `Dockerfile.claude`
2. Run `test-integration.sh` to verify `--print`, `--mcp-config`, `--output-format json`
   still behave as expected
3. Check that `--dangerously-skip-permissions` flag is still accepted
4. Verify `ANTHROPIC_API_KEY` environment variable is still passed to the subprocess

### Post-Startup Isolation Verification

`verify_isolation.py` is designed to be re-runnable:

```bash
docker exec claude-server python /app/verify_isolation.py claude-server
docker exec mcp-server /app/entrypoint.sh  # re-runs checks (also restarts server)
```

The isolation checks cover runtime state (env vars, mounted paths) as well as build-time
state (files baked into image). Running them post-start catches any drift introduced by
volume mounts or environment injection that wasn't present at image build time.

---

## 10. Comparison to Alternatives

### Running Claude Code directly on the host

| secure-claude provides additionally |
|-------------------------------------|
| Agent cannot access host filesystem (only mounted workspace) |
| Agent cannot access host credentials or SSH keys |
| Agent cannot reach the internet directly (only through LiteLLM proxy) |
| Real API key never exposed to agent process |
| Git hook execution structurally prevented (3 independent layers) |
| Workspace isolated to a single sub-repo (parent repo not visible) |
| Startup isolation checks catch misconfiguration before serving traffic |

Running Claude Code on the host gives the AI process the same access as the developer's shell.
A single prompt injection or errant tool call could exfiltrate SSH keys, AWS credentials,
or any file on the filesystem.

### Using LangChain/LangGraph with tool calling

| secure-claude provides additionally |
|-------------------------------------|
| No custom tool orchestration code to audit or maintain |
| Native Claude Code reasoning about multi-step tasks, plans, and retries |
| MCP protocol with mcp-watchdog security layer on all tool traffic |
| Structural isolation rather than framework-level access controls |
| Claude Code CLI is developed and maintained by Anthropic with built-in safety behaviors |

LangChain/LangGraph tool execution happens in-process; a tool that reads a file runs in the
same Python process as the orchestrator. secure-claude's tools all cross a TLS+auth boundary
into isolated containers, so tool compromise is contained.

### Commercial AI agent platforms

| secure-claude provides additionally |
|-------------------------------------|
| Full auditability — all code is in-repo, no black-box SaaS components |
| No data sent to platform vendor (only to Anthropic API) |
| Air-gapped-ready — can run on an isolated network with local proxy |
| Customizable isolation: add containers, change workspace, adjust token grants |
| No per-seat or per-execution pricing for the platform itself |

Commercial platforms typically offer convenience and scalability; secure-claude offers
transparency and structural control suitable for regulated or security-sensitive environments.

### Simple Docker container with API key mounted

| secure-claude provides additionally |
|-------------------------------------|
| Real API key not present in agent container (DYNAMIC_AGENT_KEY instead) |
| Dual-network isolation prevents agent from reaching internet directly |
| Filesystem jail (os.OpenRoot) prevents path traversal within workspace |
| Plan isolation prevents agent from modifying its own task queue |
| Startup isolation checks verify structural invariants before each run |
| mcp-watchdog blocks 40+ MCP-protocol-level attack classes |
| Git hook prevention (3 layers) blocks supply-chain-style attacks via gitdir |

The simplest hardened setup might be a Docker container with a mounted API key and workspace.
secure-claude adds defense-in-depth across credential isolation, network, filesystem, git,
MCP protocol, and plan integrity — each layer independently limiting blast radius if
another layer is bypassed.

---

*Document generated by reading: `docs/CONTEXT.md`, `docs/PLAN.md`, `docs/WORKSPACE_INTERFACE.md`,
`docs/mcp-tools.json`, `cluster/docker-compose.yml`, `cluster/Dockerfile.*`, `cluster/caddy/Caddyfile`,
`cluster/caddy/caddy_entrypoint.sh`, `cluster/agent/claude/server.py`,
`cluster/agent/claude/verify_isolation.py`, `cluster/agent/claude/files_mcp.py`,
`cluster/agent/claude/git_mcp.py`, `cluster/agent/claude/docs_mcp.py`,
`cluster/agent/claude/tester_mcp.py`, `cluster/agent/fileserver/main.go`,
`cluster/agent/fileserver/entrypoint.sh`, `cluster/planner/planner/plan_server.py`,
`cluster/tester/main.go`, `cluster/tester/entrypoint.sh`,
`cluster/proxy/proxy_wrapper.py`, `cluster/proxy/proxy_config.yaml`, `run.sh`,
`cluster/start-cluster.sh`.*
