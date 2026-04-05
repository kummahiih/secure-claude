# Architecture Detail

> **Scope:** Security, network, and infrastructure reference. Read this document only when working on security, TLS, network, or infrastructure tasks. For routine coding tasks, `ARCHITECTURE_OVERVIEW.md` is sufficient.

---

## Network Topology

### Network Segments

```
ext_net (external — host port binding + Anthropic egress)
  └─ caddy-sidecar:8443   ← user-facing ingress
  └─ caddy-sidecar:8081   ← egress only → api.anthropic.com:443

int_net (internal, Docker bridge, internal: true — no external routing)
  ├─ caddy-sidecar         (also on ext_net)
  ├─ claude-server:8000
  ├─ proxy:4000
  ├─ mcp-server:8443
  ├─ git-server:8443
  ├─ plan-server:8443
  ├─ tester-server:8443
  └─ log-server:8443
```

No service other than `caddy-sidecar` is on `ext_net`. The `int_net` network is `internal: true`, meaning Docker does not add external routing rules for it.

### TLS Configuration

- **Internal CA:** Generated fresh on each `run.sh`. All service-to-service communication uses HTTPS with internal CA verification.
- **TLS 1.3 minimum** on all Go servers (`tls.VersionTLS13` in `tls.Config`). Caddy ingress also TLS 1.3.
- **Egress TLS:** `caddy-sidecar:8081` → `api.anthropic.com:443` uses public CA (Alpine's `ca-certificates`). No `tls_insecure_skip_verify`.
- **CA certificate extensions:** `basicConstraints=critical,CA:TRUE,pathlen:0`, `keyUsage=critical,keyCertSign,cRLSign`, `subjectKeyIdentifier=hash` (required for OpenSSL 3.x compatibility).
- **Cert validity:** 365 days, signed at image build time. No automated rotation (RR-10, open).

### Service-to-Service Routing

```
claude-server ──TLS (internal CA)──→ mcp-server:8443      (Bearer MCP_API_TOKEN)
claude-server ──TLS (internal CA)──→ git-server:8443       (Bearer GIT_API_TOKEN)
claude-server ──TLS (internal CA)──→ plan-server:8443      (Bearer PLAN_API_TOKEN)
claude-server ──TLS (internal CA)──→ tester-server:8443    (Bearer TESTER_API_TOKEN)
claude-server ──TLS (internal CA)──→ log-server:8443       (Bearer LOG_API_TOKEN)
claude-server ──DYNAMIC_AGENT_KEY──→ proxy:4000            (LiteLLM master_key)
proxy         ──TLS (internal CA)──→ caddy-sidecar:8081    (ANTHROPIC_API_KEY passthrough)
caddy-sidecar ──TLS (public CA)───→ api.anthropic.com:443
```

### Egress Filtering

The proxy container holds `ANTHROPIC_API_KEY` but has **no direct internet access** (`int_net` only). All outbound traffic routes through `caddy-sidecar:8081`, which is hardcoded to forward exclusively to `api.anthropic.com:443`. This prevents credential exfiltration to arbitrary domains. DNS resolution for external domains fails inside the proxy container (no external DNS configured).

---

## Security Architecture

### Credential Isolation

The agent uses `DYNAMIC_AGENT_KEY` (short-lived, per-session); the real `ANTHROPIC_API_KEY` is confined to the `proxy` container only. Each backend service has its own scoped token. All tokens are 64-character random hex, regenerated on every `run.sh`.

### Token Isolation Matrix

| Token | claude-server | proxy | mcp-server | plan-server | tester-server | git-server | log-server | caddy |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| ANTHROPIC_API_KEY | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| DYNAMIC_AGENT_KEY | ✓ required | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| CLAUDE_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | — |
| MCP_API_TOKEN | ✓ required | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| PLAN_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| TESTER_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden |
| GIT_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden | ✗ forbidden |
| LOG_API_TOKEN | ✓ required | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✗ forbidden | ✓ required | ✗ forbidden |

Each token is forbidden in all other services' environments, enforced by startup isolation checks (`verify_isolation.py`, `proxy_wrapper.py`, `entrypoint.sh` scripts). All token comparisons use `secrets.compare_digest` (Python) or `subtle.ConstantTimeCompare` (Go).

### Startup Isolation Checks

Every container validates security invariants before serving:

| Container | Check Script | Key Checks |
|:---|:---|:---|
| claude-server | `verify_isolation.py` | 26 checks: forbidden/required env vars for all 8 roles, token presence/absence |
| proxy | `proxy_wrapper.py` | 4 checks: `ANTHROPIC_API_KEY` present, `DYNAMIC_AGENT_KEY` present, forbidden tokens absent |
| mcp-server | `entrypoint.sh` | Env scan + `.env` file scan for forbidden tokens |
| git-server | `entrypoint.sh` | Env scan + token scan |
| plan-server | `plan_server.py` | 10 checks at startup |
| tester-server | `entrypoint.sh` | Env scan + `/workspace` check |
| log-server | `entrypoint.sh` | Env scan + `/logs` check; rejects startup if cross-service tokens present |
| caddy-sidecar | `caddy_entrypoint.sh` | Env scan for forbidden tokens |

### Filesystem Jails

- **mcp-server:** `os.OpenRoot("/workspace")` — Go 1.24+ kernel-level jail. All file operations use this root. Path traversal blocked at runtime level.
- **mcp-server `.git` shadow:** tmpfs mounted at `/workspace/.git` (ro, size=0) prevents git hook execution through the fileserver.
- **git-server:** Separated gitdir (`GIT_DIR=/gitdir`, `GIT_WORK_TREE=/workspace`). `core.hooksPath=/dev/null` on every invocation. `--no-verify` on commits.
- **Baseline commit floor:** `entrypoint.sh` captures `HEAD` at startup. `git_reset_soft` cannot undo pre-session commits. Per-submodule baselines also enforced.

### Container Hardening

| Container | cap_drop | mem_limit | cpus | pids_limit | read_only | user |
|:---|:---|:---|:---|:---|:---|:---|
| caddy-sidecar | ALL | — | — | 100 | true | caddyuser |
| claude-server | ALL | 4g | 2.0 | 200 | — | 1000 |
| proxy | ALL | — | — | 150 | true | 1000 |
| mcp-server | ALL | 512m | 1.0 | 100 | — | 1000 |
| git-server | ALL | — | — | — | — | 1000 |
| plan-server | ALL | 256m | 0.5 | 50 | — | 1000 |
| tester-server | ALL | 1g | 1.0 | 1024 | — | 1000 |
| log-server | ALL | — | — | — | — | 1000 |

**Note:** `no-new-privileges:true` is not used — kernel 6.17.0-19 does not support it (`NO_NEW_PRIVS` not compiled in). `cap_drop: ALL` on non-root containers provides equivalent practical protection.

### Additional Security Layers

1. **MCP security proxy (mcp-watchdog):** Intercepts all JSON-RPC between Claude Code and MCP wrappers, blocking 40+ attack classes before they reach backend servers.
2. **Prompt immutability:** `/app/prompts/` and `~/.claude/commands/` owned by `root:root`, mode `444`/`555`. Agent (UID 1000) cannot modify them.
3. **MCP config as build artifact:** `.mcp.json` baked into image; not runtime-configurable.
4. **Log sanitization:** `_redact_secrets()` replaces all known token values with `[REDACTED]`; subprocess stdout/stderr at DEBUG level only.
5. **Model allowlist:** `ALLOWED_MODELS` frozenset validates `request.model` before subprocess invocation.
6. **Request body size limits:** Pydantic `max_length=100_000` on query, `max_length=200` on model; Caddy caps at 256 KB.
7. **Slash command hardening:** `os.path.basename()` + `PATH_BLACKLIST` prevents traversal.
8. **Plan field-length validation:** All text fields bounded; oversized payloads rejected with HTTP 400.
9. **Structured file-access logging:** Only metadata logged (`FILE_READ: <path> (<n> bytes, sha256=<hex>)`); no file content in logs.
10. **Tester subprocess timeout:** `context.WithTimeout` (300s) + `cmd.WaitDelay = 10s`; exit code 124 on timeout.

---

## Design Decisions

| Decision | Chosen | Rejected | Rationale |
|:---|:---|:---|:---|
| Agent framework | Claude Code CLI subprocess | LangChain | Simpler, no orchestration overhead |
| MCP transport | stdio wrappers → HTTPS REST | HTTP direct to servers | Servers are REST not MCP protocol |
| Git isolation | Submodule repo as workspace | Path filtering | Path filtering vulnerable to traversal |
| Dockerfile location | Parent repo | Inside submodule | Dockerfiles need `certs/`; keeps agent from modifying its container |
| MCP config delivery | `--mcp-config` + build-time `.mcp.json` | `claude mcp add` at runtime | `--print` mode doesn't auto-discover config |
| Claude Code version | Pinned `@2.1.74` | Latest | Flag behavior changes between versions |
| Planning tool | Separate container (plan-server) | File convention or in-process | Prevents agent writing plan files through fileserver MCP |
| Plan format | JSON | XML (GSD-style) | Simpler parsing, no schema library needed |
| Plan storage | Parent repo `plans/` | Agent workspace | Plans are infrastructure, not agent-modifiable code |
| Test execution | Direct subprocess in tester-server | Docker-in-Docker | No socket access needed, simpler, no privilege escalation |
| Tester workspace access | Read-only mount | Read-write | Tests should never modify source |
| Security scans location | `test-integration.sh` only | Sub-repo `test.sh` | Vuln DB fetches need network; sub-repo tests run in network-isolated tester |
| Submodule git routing | `parse_gitmodules` + `git_env_for` | Separate tool per submodule | Single tool surface; auto-detection from file paths |
| Proxy network access | `int_net` only, egress via caddy-sidecar | Direct internet from proxy | Prevents API key exfiltration; all outbound funnelled through caddy-sidecar |
| Architecture doc format | Split overview + detail | Single combined file | Token efficiency: routine tasks need only overview (~3k tok vs ~10k tok combined) |

### Open Residual Risks

| ID | Severity | Description |
|:---|:---|:---|
| RR-8 | Medium | No rate limiting on `/ask` and `/plan` endpoints |
| RR-10 | Low | Cert validity 365 days, no rotation mechanism |
| RR-13 | Medium | Test output not sanitised before presenting to agent |
| RR-17 | Low | Query content logged at INFO without truncation |
| RR-20 | Medium | Session log data retention — no rotation or TTL policy |
| RR-21 | Low | Silent log drops — incomplete audit trail |

Full threat model and residual risk details: [THREAT_MODEL.md](THREAT_MODEL.md)
