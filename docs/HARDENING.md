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
| Stage 1: Exfiltrate data to `models.litellm.cloud` | **No** | Container has `ext_net` + DNS for reaching Anthropic API; outbound HTTPS to arbitrary domains is not restricted |
| Stage 2: Kubernetes lateral movement | **Yes** | No Kubernetes, no socket access, `cap_drop: ALL` |
| Stage 3: Write persistence to `~/.config/sysmon/` | **Yes** | `read_only: true` blocks writes outside tmpfs |
| Stage 3: Write `/tmp/pglog`, `/tmp/.pg_state` | **Partial** | tmpfs is writable, but `noexec` blocks binary execution from `/tmp` |
| Stage 3: Install systemd backdoor | **Yes** | `read_only: true`, no systemd in container |

**Key gap: egress filtering.** The proxy container can reach any internet host via `ext_net`. A compromised process could exfiltrate `ANTHROPIC_API_KEY` to an attacker domain. Restricting egress to only `api.anthropic.com` (via Caddy egress proxy or network policy) would close this gap. See "Planned: egress filtering" below.

### Not applied / deferred

| Directive | Reason |
|:---|:---|
| `no-new-privileges:true` | Kernel 6.17.0-19 does not support it (see Host Environment Constraints) |
| Egress filtering | Planned — route outbound through Caddy to restrict to `api.anthropic.com` only |
| `mem_limit` | LiteLLM is heavier than Caddy; needs profiling before setting a safe limit |

## claude-server

*Hardening TBD.*

## mcp-server

*Hardening TBD.*

## plan-server

*Hardening TBD.*

## tester-server

*Hardening TBD.*
