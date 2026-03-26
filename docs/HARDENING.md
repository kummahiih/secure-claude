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

*Already has `cap_drop: ALL` and `user: "1000:1000"`. Further hardening TBD.*

## claude-server

*Hardening TBD.*

## mcp-server

*Hardening TBD.*

## plan-server

*Hardening TBD.*

## tester-server

*Hardening TBD.*
