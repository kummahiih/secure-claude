# Container Hardening Notes

Reference for Docker Compose and Dockerfile hardening decisions, constraints, and workarounds.

---

## Host Environment Constraints

**Kernel:** 6.17.0-19-generic  
**Docker:** 28.4.0  
**Security modules:** AppArmor (enabled), seccomp (builtin profile), cgroupns

### no-new-privileges is broken on this kernel

`security_opt: no-new-privileges:true` causes `exec: operation not permitted` on **any** container, including plain `alpine:3.23.3`. This is not image-specific.

```bash
# Reproducer — fails on kernel 6.17.0-19:
docker run --rm --security-opt no-new-privileges:true alpine:3.23.3 echo "hello"
# exec /bin/echo: operation not permitted
```

`grep NO_NEW_PRIVS /boot/config-$(uname -r)` returns nothing — the config option is not compiled into this kernel build. Disabling AppArmor (`--security-opt apparmor=unconfined`) does not help; the failure is at the kernel level.

**Action:** Do not use `no-new-privileges:true` on this host. Revisit after kernel upgrade. `cap_drop: ALL` on a non-root container with no setuid/setgid binaries provides equivalent practical protection (prevents capability acquisition through exec).

---

## caddy-sidecar

### Applied hardening (docker-compose.yml)

| Directive | Value | Purpose |
|:---|:---|:---|
| `cap_drop` | `ALL` | Drop all Linux capabilities |
| `read_only` | `true` | Immutable root filesystem |
| `pids_limit` | `100` | Fork bomb prevention |
| `tmpfs` | `/tmp:noexec,nosuid,size=64m` | Writable scratch for Caddy (XDG_DATA_HOME, XDG_CONFIG_HOME point here) |

### Required Dockerfile change: strip file capabilities

The `caddy:2-alpine` base image ships `/usr/bin/caddy` with `cap_net_bind_service=ep` (file capabilities). With `cap_drop: ALL` in compose, the kernel refuses to exec a binary that declares file capabilities it cannot grant. The container fails at:

```
caddy_entrypoint.sh: exec: line 17: caddy: Operation not permitted
```

**Fix** (in Dockerfile.caddy, before `USER caddyuser`):

```dockerfile
RUN apk add --no-cache libcap && setcap -r /usr/bin/caddy && apk del libcap
```

This strips the file capability extended attributes. Safe because Caddy binds to port 8443 (unprivileged, >1024), so `cap_net_bind_service` was never needed.

**Note:** The `caddy:2-alpine` image also has `/bin/sh` and `/usr/bin/wget` at mode 777 (world-writable). This is cosmetically bad but does not cause issues with the current hardening set. If `no-new-privileges` becomes available after a kernel upgrade, those will need fixing too:

```dockerfile
RUN chmod 755 /bin/sh /usr/bin/wget
```

### Not applied / deferred

| Directive | Reason |
|:---|:---|
| `no-new-privileges:true` | Kernel 6.17.0-19 does not support it (see above) |
| `user: "1000:1000"` | `caddyuser` is created by `adduser -S` (non-deterministic UID); Dockerfile `USER caddyuser` handles it; pinning UID in compose risks permission mismatch on `/etc/caddy/certs/caddy.key` (mode 600) |
| Removing `extra_hosts` | Required if Caddyfile egress proxy uses `host.docker.internal` — check Caddyfile before removing |
| Removing `ext_net` | Needed for host port binding (8443) and egress proxy route |
| `mem_limit` | Low risk for Caddy; could cause OOM under TLS handshake storms; add conservatively (256m+) if desired |

---

## proxy (litellm-proxy)

### Applied hardening (docker-compose.yml)

| Directive | Value | Purpose |
|:---|:---|:---|
| `cap_drop` | `ALL` | Drop all Linux capabilities (was already present) |
| `user` | `"1000:1000"` | Non-root (was already present) |
| `read_only` | `true` | Immutable root filesystem — blocks persistence artifacts |
| `pids_limit` | `150` | Fork bomb prevention (higher than Caddy; LiteLLM may spawn worker processes) |
| `tmpfs` | `/tmp:noexec,nosuid,size=256m` | Writable scratch for Python, tiktoken cache (~4MB), LiteLLM runtime files |

### No Dockerfile changes required

The LiteLLM Docker image (`ghcr.io/berriai/litellm`) is Python-based with no file capabilities or setuid binaries. `cap_drop: ALL` works without modification.

### tmpfs sizing rationale

LiteLLM writes to `/tmp` because `HOME=/tmp` is set in compose. Primary consumers:
- **tiktoken cache** (`/tmp/tiktoken_cache/`): BPE token encoding data, ~4MB for `cl100k_base` (Anthropic models)
- **Python bytecode**: `__pycache__` files
- **LiteLLM runtime**: config parsing, in-memory cache spillover

256MB is generous for Anthropic-only usage. If disk caching is enabled (`cache_params.type: disk`), increase accordingly.

### noexec on tmpfs

Currently set. LiteLLM loads tiktoken data via Python `open()`, not `exec`. Python `.pyc` bytecode is interpreted, not executed as binaries. If unexplained Python import errors appear, removing `noexec` is the first thing to try.

### Supply chain attack analysis: TeamPCP LiteLLM compromise (March 24, 2026)

LiteLLM PyPI versions 1.82.7 and 1.82.8 were backdoored with a credential-stealing payload by threat actor TeamPCP. The payload had three stages: credential harvesting (SSH keys, cloud tokens, env vars, wallets), Kubernetes lateral movement, and persistent systemd backdoor. Version 1.82.8 used a `.pth` file that fires on any Python interpreter startup — no import required.

**This cluster is not affected** — we use a pinned Docker image (`ghcr.io/berriai/litellm:main-v1.82.3-stable.patch.2`), not a PyPI install. The attack targeted PyPI packages.

**How current hardening would have performed if a compromised image were used:**

| Attack stage | Blocked? | Why |
|:---|:---|:---|
| Stage 0: Payload execution (`.pth` or `proxy_server.py` injection) | **No** | Runs inside the Python process before any wrapper code |
| Stage 1: Read `ANTHROPIC_API_KEY` from process env | **No** | Environment variables are readable by the running process |
| Stage 1: Harvest SSH keys, wallets, `.env` files from filesystem | **Yes** | `read_only: true`, non-root, no such files exist in container |
| Stage 1: Exfiltrate data to `models.litellm.cloud` | **Yes** | Proxy on `int_net` only; Caddy egress proxy only forwards to `api.anthropic.com` (see Egress Filtering section) |
| Stage 2: Kubernetes lateral movement | **Yes** | No Kubernetes, no socket access, `cap_drop: ALL` |
| Stage 3: Write persistence to `~/.config/sysmon/` | **Yes** | `read_only: true` blocks writes outside tmpfs |
| Stage 3: Write `/tmp/pglog`, `/tmp/.pg_state` | **Partial** | tmpfs is writable, but `noexec` blocks binary execution from `/tmp` |
| Stage 3: Install systemd backdoor | **Yes** | `read_only: true`, no systemd in container |

**Key gap closed: egress filtering.** The proxy container now routes all outbound traffic through `caddy-sidecar:8081`, which only forwards to `api.anthropic.com`. See the Egress Filtering section below for details.

### Not applied / deferred

| Directive | Reason |
|:---|:---|
| `no-new-privileges:true` | Kernel 6.17.0-19 does not support it (see Host Environment Constraints) |
| `mem_limit` | LiteLLM is heavier than Caddy; needs profiling before setting a safe limit |

---

## Internal CA Certificate

### Required extensions for OpenSSL 3.x compatibility

The internal CA certificate (`cluster/certs/ca.crt`) must include `basicConstraints` and `keyUsage` extensions. OpenSSL 3.x (used by Python's `ssl` module in the LiteLLM and plan-server images) rejects CA certificates that lack the `keyUsage: keyCertSign` extension with:

```
SSLCertVerificationError: CA cert does not include key usage extension
```

The CA is generated in `run.sh` with:

```bash
openssl req -x509 ... \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"
```

`pathlen:0` restricts this CA to signing end-entity certificates only — it cannot sign intermediate CAs.

**If the CA cert is regenerated**, all container images must be rebuilt (every Dockerfile has a signer stage that uses `ca.key` + `ca.crt` to sign leaf certs, and every image bakes in `ca.crt` for trust).

### LiteLLM startup warning (expected)

With the proxy container on `int_net` only, LiteLLM logs this on every startup:

```
WARNING: Failed to fetch remote model cost map from https://raw.githubusercontent.com/.../model_prices_and_context_window.json: [Errno -2] Name or service not known. Falling back to local backup.
```

This is expected and harmless — LiteLLM tries to fetch updated pricing data from GitHub, fails because external DNS is unreachable, and falls back to its bundled copy. The warning confirms egress restriction is working.

---

## Egress Filtering (proxy → Caddy → api.anthropic.com)

### Problem

The proxy container holds `ANTHROPIC_API_KEY` and previously had direct internet access via `ext_net`. A compromised LiteLLM process (e.g. supply-chain attack like the TeamPCP incident) could exfiltrate the key to any arbitrary domain over HTTPS.

### Solution

Route all proxy outbound traffic through a dedicated Caddy reverse proxy endpoint that only forwards to `api.anthropic.com`.

**Architecture:**

```
proxy (int_net only)
  └─ HTTPS ─→ caddy-sidecar:8081 (int_net + ext_net)
                  └─ reverse_proxy ─→ api.anthropic.com:443
```

### Changes applied

| Component | Change | Detail |
|:---|:---|:---|
| Caddyfile | New `:8081` listener | Reverse-proxies exclusively to `api.anthropic.com:443`; TLS with internal CA certs; sets `Host: api.anthropic.com` and `tls_server_name` |
| Caddyfile | Removed `:8080` egress block | The general-purpose egress proxy through `host.docker.internal` is no longer needed |
| docker-compose.yml | proxy: removed `ext_net` | Proxy is now `int_net` only — no direct internet access |
| docker-compose.yml | proxy: removed `dns` | No external DNS needed; proxy resolves `caddy-sidecar` via Docker's internal DNS on `int_net` |
| proxy_config.yaml | `api_base: https://caddy-sidecar:8081` | LiteLLM sends Anthropic API calls to Caddy instead of directly to `api.anthropic.com` |

### How LiteLLM reaches the Anthropic API

LiteLLM's `proxy_config.yaml` must set `api_base` for the Anthropic provider to `https://caddy-sidecar:8081`. The proxy container already trusts the internal CA (`SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`), so TLS to Caddy works. Caddy then forwards to `api.anthropic.com:443` using public TLS — no internal CA involved on the outbound leg.

The `Host` header and TLS SNI are set to `api.anthropic.com` so the Anthropic API sees a normal request. The `Authorization` header (containing `ANTHROPIC_API_KEY`) passes through Caddy untouched — Caddy never logs or inspects it, and `ANTHROPIC_API_KEY` is not in Caddy's environment (enforced by `caddy_entrypoint.sh`).

### What this blocks

A compromised process inside the proxy container can only make outbound HTTPS connections to `caddy-sidecar:8081`. Caddy hardcodes the upstream as `api.anthropic.com:443` — there is no way for the client to influence the destination. Attempts to exfiltrate data to `models.litellm.cloud` or any other attacker domain fail because:

1. The proxy container has no route to the internet (`int_net` is `internal: true`)
2. The only reachable egress path (`caddy-sidecar:8081`) only forwards to `api.anthropic.com`
3. DNS resolution for external domains fails inside `int_net` (no external DNS configured on proxy)

### Supply chain attack impact (revised)

With egress filtering applied, the TeamPCP attack analysis from above changes:

| Attack stage | Blocked? | Why |
|:---|:---|:---|
| Stage 1: Exfiltrate to `models.litellm.cloud` | **Yes** | No route to internet; Caddy only proxies to `api.anthropic.com` |

**Remaining gap:** A sophisticated attacker could encode exfiltrated data in the *body* of legitimate-looking Anthropic API requests (e.g., stuffing the key into a prompt). This is a covert-channel concern common to all allowlist-based egress filtering — mitigating it would require deep packet inspection of API request bodies, which is out of scope.

### TLS trust chain

```
proxy ──TLS (internal CA)──→ caddy-sidecar:8081 ──TLS (public CA)──→ api.anthropic.com:443
```

The proxy trusts the internal CA for the first hop. Caddy uses the system trust store (Alpine's `ca-certificates`) for the second hop to Anthropic's public endpoint.

### Rollback

To restore direct proxy internet access (e.g., for debugging):

1. Add `ext_net` back to the proxy service's `networks`
2. Restore `dns: [8.8.8.8, 1.1.1.1]` on the proxy service
3. Revert `api_base` in `proxy_config.yaml` to `https://api.anthropic.com`

---

## claude-server

### Applied hardening (docker-compose.yml)

| Directive | Value | Purpose |
|:---|:---|:---|
| `cap_drop` | `ALL` | Drop all Linux capabilities |
| `mem_limit` | `4g` | Bound memory; Claude Code subprocess + Node.js runtime + 5 MCP stdio servers justify higher limit |
| `cpus` | `2.0` | Cap CPU to prevent runaway subprocess saturation |
| `pids_limit` | `200` | Fork bomb prevention; allows Claude Code + MCP child processes |

### Sizing rationale

claude-server runs the Claude Code CLI, which spawns a Node.js process plus up to 5 MCP server subprocesses (fileserver, git, docs, planner, tester) over stdio. Each MCP server is an independent process. 4 GB RAM and 2 CPUs are the minimum comfortable headroom for this workload; lower limits risk OOM-killing mid-task.

### Not applied / deferred

| Directive | Reason |
|:---|:---|
| `no-new-privileges:true` | Kernel 6.17.0-19 does not support it (see Host Environment Constraints) |
| `read_only: true` | claude-server writes to `~/.claude/` (session state, credentials) and `/tmp`; making root read-only would require enumerating every writable path and mounting tmpfs entries for each — deferred |

---

## mcp-server

### Applied hardening (docker-compose.yml)

| Directive | Value | Purpose |
|:---|:---|:---|
| `cap_drop` | `ALL` | Drop all Linux capabilities |
| `mem_limit` | `512m` | Bound memory; Go binary is lightweight, 512 MB is generous headroom |
| `cpus` | `1.0` | Cap CPU; file I/O workload is not CPU-intensive |
| `pids_limit` | `100` | Fork bomb prevention; single Go server, no subprocess spawning expected |

### Not applied / deferred

| Directive | Reason |
|:---|:---|
| `no-new-privileges:true` | Kernel 6.17.0-19 does not support it (see Host Environment Constraints) |
| `read_only: true` | `/workspace` is mounted read-write; making root read-only deferred until all write paths are audited |

---

## plan-server

### Applied hardening (docker-compose.yml)

| Directive | Value | Purpose |
|:---|:---|:---|
| `cap_drop` | `ALL` | Drop all Linux capabilities |
| `mem_limit` | `256m` | Bound memory; minimal Python REST server, smallest memory footprint in the cluster |
| `cpus` | `0.5` | Cap CPU; lightweight request handler, no heavy computation |
| `pids_limit` | `50` | Fork bomb prevention; single-process Python server |

### Not applied / deferred

| Directive | Reason |
|:---|:---|
| `no-new-privileges:true` | Kernel 6.17.0-19 does not support it (see Host Environment Constraints) |
| `read_only: true` | `/plans` is mounted read-write for plan state persistence; deferred until write paths are mapped to tmpfs entries |

---

## tester-server

### Applied hardening (docker-compose.yml)

| Directive | Value | Purpose |
|:---|:---|:---|
| `cap_drop` | `ALL` | Drop all Linux capabilities |
| `mem_limit` | `1g` | Bound memory; runs arbitrary `test.sh` which may compile Go code — 1 GB accommodates Go test compilation |
| `cpus` | `1.0` | Cap CPU for test runs |
| `pids_limit` | `1024` | Fork bomb prevention; test subprocess may spawn compiler + linker child processes |

### Not applied / deferred

| Directive | Reason |
|:---|:---|
| `no-new-privileges:true` | Kernel 6.17.0-19 does not support it (see Host Environment Constraints) |
| `read_only: true` | Test subprocess needs `/tmp` for compilation artifacts and test scratch space; deferred |