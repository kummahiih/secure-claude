# Moving Certificates from Build Time to Runtime

**Project:** secure-claude
**Goal:** Remove cert material from Docker image builds so the same images can run under Docker Compose today and Kubernetes tomorrow without rebuilding per-environment.
**Status:** Design — not yet implemented.
**Scope:** Certificate delivery only. Container hardening, service-level authorization, and network topology are out of scope for this change.

---

## 0. Answers to prior open questions (for record)

The following decisions shape this document and are final for the purposes of this refactor:

1. **Leaf cert generation lives in a new script `cluster/gen-leaf-certs.sh`**, called from `run.sh`. CA generation stays where it is in `run.sh`.
2. **All paths use the real layout.** Certs live in `cluster/certs/`; compose file is `cluster/docker-compose.yml`; Dockerfiles are at `cluster/Dockerfile.*`.
3. **`claude-server` and `codex-server` are symmetric but get distinct cert filenames.** They share the MCP stack and have identical *trust* requirements, but each gets its own differently-named cert files (`claude.crt`/`claude.key` vs `codex.crt`/`codex.key`). No shared `agent.*` naming anywhere — host-side or container-side. This requires an application-code rename; see §3.9.
4. **`caddy-sidecar` is in scope for internal CA cert delivery** (it currently has a signer stage and uses an internal-CA-signed cert for `:8443`, `:8081`, `:8082`, `:8444`). External/ACME TLS for the real `HOST_DOMAIN` is explicitly out of scope — not wired up in the current Caddyfile and not part of this change.
5. **`proxy` (LiteLLM) is in scope.** `Dockerfile.proxy` has a signer stage and a trust-store injection step that both need to move to runtime.
6. **Hardening considerations are out of scope.** Tmpfs layouts, `read_only`, memory limits, `cap_drop`, etc. remain exactly as they are. Where the trust-store injection needs a writable location, we use `/tmp` and rely on existing tmpfs mounts where they already exist.
7. **Trust-store injection happens in existing entrypoints** (`caddy_entrypoint.sh`, `proxy_wrapper.py`, Go service `entrypoint.sh`, the Python `verify_isolation.py` framework). No new entrypoint scripts are created.
8. **Cert regeneration policy matches token policy: regenerate every `run.sh`.** The CA persists across runs (as it does today — `run.sh` only creates it if missing). Leaf certs and tokens are regenerated fresh every run. Existing behaviour, now also formalized for leaves.
9. **Cert file paths are hardcoded in images, not env-var parameterized.** String search-and-replace is acceptable if paths need to change later.
10. **Minimal changes to `run.sh`.** Add one new step (leaf cert generation), nothing else.

---

## 1. Motivation

### What we do today

Each service Dockerfile that needs an internal-CA-signed cert has a two-stage build. Stage 1 (`signer`) bind-mounts `cluster/certs/ca.key` and `cluster/certs/ca.crt` from the host, generates a per-service keypair, and signs a leaf cert. Stage 2 copies the leaf cert, leaf key, and the CA public cert into the image, and (for some services) injects the CA into the system and Python trust stores via `update-ca-certificates` and appending to `certifi`'s bundle.

Example from `cluster/Dockerfile.claude`:

```dockerfile
FROM alpine:3.23.3 AS signer
RUN apk add --no-cache openssl=3.5.6-r0
WORKDIR /certs
RUN --mount=type=bind,src=./certs/ca.key,target=/tmp/ca.key \
    --mount=type=bind,src=./certs/ca.crt,target=/tmp/ca.crt \
    openssl genrsa -out agent.key 3072 && \
    openssl req -new -key agent.key -out agent.csr -subj "/CN=claude-server" && \
    echo "subjectAltName=DNS:localhost,DNS:claude-server,IP:127.0.0.1" > agent.ext && \
    openssl x509 -req -in agent.csr -CA /tmp/ca.crt -CAkey /tmp/ca.key -CAcreateserial \
    -out agent.crt -days 365 -sha256 -extfile agent.ext

# ...later in final stage:
COPY --from=signer /certs/agent.crt /app/certs/agent.crt
COPY --from=signer /certs/agent.key /app/certs/agent.key
COPY ./certs/ca.crt /app/certs/ca.crt
RUN cat /app/certs/ca.crt >> "$(python -c 'import certifi; print(certifi.where())')" && \
    cp /app/certs/ca.crt /usr/local/share/ca-certificates/internal-ca.crt && \
    update-ca-certificates
```

### Why this has to change

1. **Non-portable images.** Each image only works with the CA it was built against. Same codebase, different environment = rebuild.
2. **Hostile to Kubernetes.** K8s expects images built once, deployed everywhere with config injected at runtime.
3. **Private keys live in image layers.** `agent.key`, `caddy.key`, `proxy.key` all sit in image layers. Anyone with registry pull access has the keys.
4. **The CA private key must be present on every build machine.** The bind mount of `ca.key` during build means CI would need the CA private key in secrets — a significant attack surface for a supposed root of trust.
5. **Rotation requires a rebuild.** Currently acceptable because `run.sh` rebuilds everything, but it means the image layer cache is invalidated every run, which slows iteration.

### Non-goals

- **Not introducing cert-manager, Vault, SPIRE, or a service mesh.** This refactor is the groundwork that makes those easy later.
- **Not changing the TLS trust topology.** Same internal CA, same per-service leaf certs, same CN/SAN layout.
- **Not changing hardening** (`cap_drop`, `read_only`, `pids_limit`, memory limits, tmpfs, etc.).
- **Not adding external ACME / real-domain TLS for `caddy-sidecar` ingress.** Out of scope for this refactor even though the Caddyfile has a TLS stanza — the current certs are internal-CA-signed placeholders.
- **Not changing `mcp-watchdog`, isolation checks semantics, token distribution, or the plan-execute loop.**

---

## 2. Target architecture

```
                 ┌───────────────────────────────────┐
                 │   cluster/certs/ (git-ignored)    │
                 │   - ca.crt, ca.key                │
                 │   - claude.crt/key                │
                 │   - codex.crt/key                 │
                 │   - mcp.crt/key                   │
                 │   - plan.crt/key                  │
                 │   - tester.crt/key                │
                 │   - git.crt/key                   │
                 │   - log.crt/key                   │
                 │   - proxy.crt/key                 │
                 │   - caddy.crt/key                 │
                 └──────────────────┬────────────────┘
                                    │
                  generated by run.sh → gen-leaf-certs.sh
                                    │
                                    ▼
                 ┌───────────────────────────────────┐
                 │ Docker Compose runtime            │
                 │   volumes:                        │
                 │     - cluster/certs/ca.crt:ro     │
                 │     - cluster/certs/<svc>.crt:ro  │
                 │     - cluster/certs/<svc>.key:ro  │
                 └───────────────────────────────────┘

                 Same images, later:

                 ┌───────────────────────────────────┐
                 │ Kubernetes runtime                │
                 │   ConfigMap internal-ca           │
                 │   Secret  <svc>-tls               │
                 │   mounted via volumeMounts+subPath│
                 └───────────────────────────────────┘
```

Images contain **no cert material at all**. They provide mount-point directories with correct ownership/permissions. Cert files appear at the paths the current Dockerfiles already use.

### Cert file layout inside containers

Each service gets its own distinctly-named cert file in its container — no shared `agent.*` naming. This refactor renames the in-container cert files for `claude-server` and `codex-server` from the current generic `agent.crt`/`agent.key` to service-specific `claude.crt`/`claude.key` and `codex.crt`/`codex.key`. This requires application-code updates in those services (see §3.9).

All other services' in-container cert paths are preserved as they are today.

**Python/Go services** (general pattern — `<name>` is the service's short name in the table below):

| Path | Content | Mode | Owner |
|---|---|---|---|
| `/app/certs/ca.crt` | CA public cert | 0444 | root:1000 |
| `/app/certs/<name>.crt` | Service leaf cert | 0444 | root:1000 |
| `/app/certs/<name>.key` | Service leaf private key | 0400 | 1000:1000 |

The `<name>` values match the service list below and match the host-side filename, so the mount is a direct `host:container` map with the same basename on both sides.

**Caddy:**

| Path | Content | Mode | Owner |
|---|---|---|---|
| `/etc/caddy/certs/ca.crt` | CA public cert | 0644 | caddyuser:caddygroup |
| `/etc/caddy/certs/caddy.crt` | Caddy leaf cert | 0644 | caddyuser:caddygroup |
| `/etc/caddy/certs/caddy.key` | Caddy leaf private key | 0600 | caddyuser:caddygroup |

Caddy's in-container paths are unchanged; its Caddyfile already references `caddy.crt`/`caddy.key` so no config edits are needed there.

### Service list

| Service | Container user | In-container cert dir | Leaf filename (in container) | Notes |
|---|---|---|---|---|
| claude-server | 1000:1000 | `/app/certs/` | `claude.crt`, `claude.key` | **renamed from `agent.*` — app code update required (§3.9)** |
| codex-server | 1000:1000 | `/app/certs/` | `codex.crt`, `codex.key` | **renamed from `agent.*` — app code update required (§3.9)** |
| mcp-server | 1000:1000 | `/app/certs/` | `mcp.crt`, `mcp.key` | verify against Dockerfile.mcp during pilot; rename app code if currently `agent.*` |
| plan-server | 1000:1000 | `/app/certs/` | `plan.crt`, `plan.key` | verify against Dockerfile.plan during pilot; rename app code if currently `agent.*` |
| tester-server | 1000:1000 | `/app/certs/` | `tester.crt`, `tester.key` | verify against Dockerfile.tester during pilot; rename app code if currently `agent.*` |
| git-server | 1000:1000 | `/app/certs/` | `git.crt`, `git.key` | verify against Dockerfile.git during pilot; rename app code if currently `agent.*` |
| log-server | 1000:1000 | `/app/certs/` | `log.crt`, `log.key` | verify against Dockerfile.log during pilot; rename app code if currently `agent.*` |
| proxy | 1000:1000 | `/app/certs/` | `proxy.crt`, `proxy.key` | unchanged — already service-specific |
| caddy-sidecar | caddyuser:caddygroup | `/etc/caddy/certs/` | `caddy.crt`, `caddy.key` | unchanged — already service-specific |

**Host-side vs container-side filename convention.** To eliminate the mount mapping indirection entirely, host-side filenames match container-side basenames. For example: host `cluster/certs/claude.crt` mounts to container `/app/certs/claude.crt`. No renaming in the mount line, no mental translation. The host-side filename is the single source of truth for "which service does this cert belong to."

### SAN layout

Per service, matching what the current Dockerfiles do:

- `claude-server`: `DNS:claude-server, DNS:localhost, IP:127.0.0.1`
- `codex-server`: `DNS:codex-server, DNS:localhost, IP:127.0.0.1`
- `mcp-server`: `DNS:mcp-server, DNS:localhost, IP:127.0.0.1`
- `plan-server`: `DNS:plan-server, DNS:localhost, IP:127.0.0.1`
- `tester-server`: `DNS:tester-server, DNS:localhost, IP:127.0.0.1`
- `git-server`: `DNS:git-server, DNS:localhost, IP:127.0.0.1`
- `log-server`: `DNS:log-server, DNS:localhost, IP:127.0.0.1`
- `proxy`: `DNS:proxy, DNS:localhost, IP:127.0.0.1`
- `caddy-sidecar`: `DNS:caddy-sidecar, DNS:localhost, IP:127.0.0.1`

---

## 3. Implementation plan

### 3.1 New script: `cluster/gen-leaf-certs.sh`

Replaces the logic currently duplicated in every `signer` Dockerfile stage. Runs every `run.sh` invocation, after CA generation, before `start-cluster.sh`.

Responsibilities:

1. Assume `cluster/certs/ca.crt` and `cluster/certs/ca.key` exist (created by `run.sh` step 4).
2. For each service, generate a fresh 3072-bit RSA key and a 365-day leaf cert signed by the CA.
3. Write host-side filenames as `cluster/certs/<short>.crt` and `cluster/certs/<short>.key`, where `<short>` matches the in-container basename (see service list in §2).
4. Each cert's CN and DNS SAN must be the full Docker-network hostname (e.g. `claude-server`, `caddy-sidecar`) even when the filename is short (e.g. `claude`, `caddy`). The CN/SAN is what matters for TLS hostname verification inside the network; the filename is just a file label.
5. Set file permissions: `.crt` files `0644`, `.key` files `0600`.
6. Overwrite existing leaves without prompting (they are regenerated every run).

Sketch:

```bash
#!/bin/bash
set -e

CERT_DIR="cluster/certs"
CA_CRT="$CERT_DIR/ca.crt"
CA_KEY="$CERT_DIR/ca.key"

if [[ ! -f "$CA_CRT" || ! -f "$CA_KEY" ]]; then
    echo "FATAL: CA files missing — run.sh should have generated them first" >&2
    exit 1
fi

# gen_leaf <filename-stem> <CN-and-primary-DNS-SAN>
# The filename stem is the short name used for file labelling (e.g. "claude").
# The CN/SAN value is the Docker-network hostname used for TLS verification
# (e.g. "claude-server"). localhost and 127.0.0.1 are always added.
gen_leaf() {
    local stem="$1"
    local host="$2"
    local key="$CERT_DIR/$stem.key"
    local crt="$CERT_DIR/$stem.crt"
    local csr
    csr="$(mktemp)"
    local ext
    ext="$(mktemp)"

    openssl genrsa -out "$key" 3072 2>/dev/null
    openssl req -new -key "$key" -out "$csr" -subj "/CN=$host" 2>/dev/null
    echo "subjectAltName=DNS:$host,DNS:localhost,IP:127.0.0.1" > "$ext"
    openssl x509 -req -in "$csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
        -out "$crt" -days 365 -sha256 -extfile "$ext" 2>/dev/null

    chmod 600 "$key"
    chmod 644 "$crt"
    rm -f "$csr" "$ext"
}

#         filename stem    container-network hostname (CN + SAN)
gen_leaf  "claude"         "claude-server"
gen_leaf  "codex"          "codex-server"
gen_leaf  "mcp"            "mcp-server"
gen_leaf  "plan"           "plan-server"
gen_leaf  "tester"         "tester-server"
gen_leaf  "git"            "git-server"
gen_leaf  "log"            "log-server"
gen_leaf  "proxy"          "proxy"
gen_leaf  "caddy"          "caddy-sidecar"
```

The two-column layout makes the stem-vs-hostname split explicit. An agent editing this later should not collapse the columns to a single identifier — they are deliberately different.

Make executable: `chmod +x cluster/gen-leaf-certs.sh`.

### 3.2 Changes to `run.sh`

Exactly one addition: call the new script after the CA block (step 4) and before the mount-prep / permissions block (step 6).

Insert as new step 5:

```bash
# 5. Generate per-service leaf certs (regenerated every run)
echo "[$(date +'%H:%M:%S')] Generating leaf certificates..."
./cluster/gen-leaf-certs.sh
```

That is the only change to `run.sh`.

### 3.3 Dockerfile changes (general pattern)

Apply to every Dockerfile that currently has a `signer` stage: `Dockerfile.claude`, `Dockerfile.codex`, `Dockerfile.mcp`, `Dockerfile.plan`, `Dockerfile.tester`, `Dockerfile.git`, `Dockerfile.log`, `Dockerfile.proxy`, `Dockerfile.caddy`.

**Remove:**

- The entire `FROM alpine:... AS signer` stage.
- The `COPY --from=signer` lines.
- `COPY ./certs/ca.crt ...` (or `COPY certs/ca.crt ...`) lines.
- Any `cat ca.crt >> .../certifi` or `update-ca-certificates` lines (trust-store injection moves to runtime).
- Any `chmod`/`chown` on cert files that no longer exist at build.

**Add** (for 1000:1000 services):

```dockerfile
# Cert material is injected at runtime via volumes (compose) or
# ConfigMaps/Secrets (Kubernetes). The image ships with only the
# mount-point directory pre-created with correct ownership.
RUN mkdir -p /app/certs && \
    chown 1000:1000 /app/certs && \
    chmod 550 /app/certs
```

**Add** (for caddy):

```dockerfile
RUN mkdir -p /etc/caddy/certs && \
    chown caddyuser:caddygroup /etc/caddy/certs && \
    chmod 550 /etc/caddy/certs
```

Place the stub-directory block before the final `USER` line in each Dockerfile.

### 3.4 Trust-store injection moves to runtime

Currently four images inject the CA into the OS / Python trust stores at build time:

- `Dockerfile.claude` — `update-ca-certificates` + `certifi` append
- `Dockerfile.codex` — same (assumed symmetric)
- `Dockerfile.proxy` — `cat internal-ca >> /etc/ssl/certs/ca-certificates.crt` + `certifi` append
- The Go services — some may do this; verify per-Dockerfile

This has to move to runtime because the CA file isn't in the image anymore. The injection must respect each service's existing user and writability constraints.

#### 3.4.1 Python services (claude, codex, proxy)

Inject in the existing startup script:
- `claude-server` / `codex-server`: extend `verify_isolation.py` (or whatever runs before the server process)
- `proxy`: extend `proxy_wrapper.py`

Canonical Python snippet (adapt per service for where it's placed):

```python
import os, shutil, certifi

CA_PATH = "/app/certs/ca.crt"
BUNDLE_DIR = "/tmp/ssl"
BUNDLE = f"{BUNDLE_DIR}/ca-bundle.crt"

def inject_ca_into_trust_store():
    # Cert presence is already validated by isolation checks;
    # this just extends the certifi bundle into a writable location.
    os.makedirs(BUNDLE_DIR, exist_ok=True)
    shutil.copy(certifi.where(), BUNDLE)
    with open(CA_PATH, "rb") as src, open(BUNDLE, "ab") as dst:
        dst.write(b"\n")
        dst.write(src.read())
    os.environ["SSL_CERT_FILE"] = BUNDLE
    os.environ["REQUESTS_CA_BUNDLE"] = BUNDLE
    os.environ["CURL_CA_BUNDLE"] = BUNDLE
    os.environ["NODE_EXTRA_CA_CERTS"] = CA_PATH
```

**Why `/tmp/ssl` and not `update-ca-certificates`?** Several containers have `read_only: true` (proxy, caddy) or run as non-root. Writing `/etc/ssl/certs` is not possible at runtime in those. `/tmp` is already available as a writable tmpfs on services that need it (proxy has `tmpfs: /tmp` sized 256m, which comfortably accommodates the ~250KB bundle).

**Env-var propagation note.** Setting env vars in Python before exec'ing a subprocess (Claude Code CLI, LiteLLM) propagates them. For services where the *Python startup process itself* needs trust-store changes, `os.environ` updates take effect immediately. This matches what the old build-time approach provided.

#### 3.4.2 Go services (mcp, git, tester, log)

These services already have `entrypoint.sh` scripts that do isolation checks. Extend each with:

```bash
# Stage the CA bundle in a writable location; point Go's TLS config at it via env
CA_PATH=/app/certs/ca.crt
BUNDLE=/tmp/ssl/ca-bundle.crt

if [[ ! -s "$CA_PATH" ]]; then
    echo "FATAL: $CA_PATH missing" >&2
    exit 1
fi

mkdir -p /tmp/ssl
# Start from system bundle if present, else just use the internal CA alone
if [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
    cp /etc/ssl/certs/ca-certificates.crt "$BUNDLE"
else
    : > "$BUNDLE"
fi
cat "$CA_PATH" >> "$BUNDLE"

export SSL_CERT_FILE="$BUNDLE"
```

Go's `crypto/tls` honours `SSL_CERT_FILE` out of the box when constructing system cert pools, so this is sufficient for Go services acting as TLS clients. For Go services acting as TLS servers, the server-side `tls.Config` already loads `ca.crt` explicitly from `/app/certs/ca.crt` — that code path is unaffected.

#### 3.4.3 Caddy

Caddy loads `/etc/caddy/certs/ca.crt` directly from the Caddyfile (`tls_trusted_ca_certs /etc/caddy/certs/ca.crt`). No trust-store injection needed — Caddy reads the file at startup from the mounted path. The only change is that the file arrives by mount rather than by COPY.

`caddy_entrypoint.sh` should validate the cert files exist before invoking caddy:

```bash
for f in /etc/caddy/certs/ca.crt /etc/caddy/certs/caddy.crt /etc/caddy/certs/caddy.key; do
    if [[ ! -s "$f" ]]; then
        echo "FATAL: missing cert file: $f" >&2
        exit 1
    fi
done
```

### 3.5 Compose changes

For every service, add volume mounts for its cert trio. Since host-side and container-side basenames now match, the mount lines are symmetric on both sides.

**claude-server:**

```yaml
claude-server:
  # ... existing config unchanged ...
  volumes:
    - ./workspace/docs:/docs:ro
    # NEW:
    - ./certs/ca.crt:/app/certs/ca.crt:ro
    - ./certs/claude.crt:/app/certs/claude.crt:ro
    - ./certs/claude.key:/app/certs/claude.key:ro
```

**codex-server:**

```yaml
codex-server:
  # ... existing config unchanged ...
  volumes:
    - ./workspace/docs:/docs:ro
    # NEW:
    - ./certs/ca.crt:/app/certs/ca.crt:ro
    - ./certs/codex.crt:/app/certs/codex.crt:ro
    - ./certs/codex.key:/app/certs/codex.key:ro
```

Note on the compose cert paths: `docker-compose.yml` lives in `cluster/`, so `./certs/` in the compose file resolves to `cluster/certs/` — which is where `gen-leaf-certs.sh` writes them.

**proxy:**

```yaml
proxy:
  # ... existing config unchanged ...
  volumes:
    - ./proxy/proxy_config.yaml:/tmp/config.yaml:ro
    - ./proxy/proxy_wrapper.py:/app/proxy_wrapper.py:ro
    # NEW:
    - ./certs/ca.crt:/app/certs/ca.crt:ro
    - ./certs/proxy.crt:/app/certs/proxy.crt:ro
    - ./certs/proxy.key:/app/certs/proxy.key:ro
```

**caddy-sidecar:**

```yaml
caddy-sidecar:
  # ... existing config unchanged ...
  volumes:
    - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
    # NEW:
    - ./certs/ca.crt:/etc/caddy/certs/ca.crt:ro
    - ./certs/caddy.crt:/etc/caddy/certs/caddy.crt:ro
    - ./certs/caddy.key:/etc/caddy/certs/caddy.key:ro
```

Apply the analogous three-mount block to `mcp-server`, `plan-server`, `tester-server`, `git-server`, `log-server`. The host-side basename and the container-side basename are identical per the convention in §2 (e.g. `./certs/mcp.crt:/app/certs/mcp.crt:ro`). If a Dockerfile turns out to still use `agent.crt`/`agent.key` at the application code level, update both the Dockerfile stub and the app code as part of that service's refactor — see §3.9.

`read_only: true` on `proxy` and `caddy-sidecar` is **not affected** — these are read-only file mounts, compatible with a read-only rootfs.

### 3.6 The `proxy` system trust store — specific note

`Dockerfile.proxy` currently does two distinct trust-store operations at build:

```dockerfile
cat /tmp/internal-ca.crt >> /etc/ssl/certs/ca-certificates.crt
cat /tmp/internal-ca.crt >> "$(python -c 'import certifi; print(certifi.where())')"
```

The first (`/etc/ssl/certs/ca-certificates.crt`) is the *system* trust store. On a read-only rootfs at runtime, this file is not writable. The new `proxy_wrapper.py` injection staged in `/tmp/ssl/ca-bundle.crt` + `SSL_CERT_FILE` replaces both operations. Python code honours `SSL_CERT_FILE` via `ssl.get_default_verify_paths()` and `certifi` clients honour `REQUESTS_CA_BUNDLE`. LiteLLM's upstream requests pick up `SSL_CERT_FILE`.

**If a LiteLLM-internal code path reads `/etc/ssl/certs/ca-certificates.crt` directly** (bypassing the env var), this refactor will break it. The pilot for `proxy` should include a smoke test that makes a request through the proxy and confirms the upstream (Anthropic) TLS handshake still works via `caddy-sidecar:8081`. If it breaks, the fallback is to mount the CA bundle over the system trust store path:

```yaml
# Fallback only if the SSL_CERT_FILE approach fails for LiteLLM:
- ./certs/ca.crt:/etc/ssl/internal-ca.crt:ro
# plus: entrypoint concatenates /etc/ssl/internal-ca.crt onto
# a writable bundle location and re-bind-mounts as needed
```

But try `SSL_CERT_FILE` first — it's the clean answer.

### 3.7 Developer workflow changes

Unchanged in the common case:

```bash
./run.sh
```

`run.sh` now also regenerates leaves. Because leaves regenerate every run, matching the existing token-regeneration behaviour, there is no new mental model to learn.

Document in `README.md`:
- Where certs live: `cluster/certs/`
- That `cluster/certs/ca.key` is the root of trust
- That leaves are ephemeral and regenerated every `run.sh`
- That the CA persists until `cluster/certs/ca.crt`/`ca.key` are manually deleted

### 3.8 Kubernetes-forward-compatibility check

With this design, moving to K8s later requires zero image changes. The only thing that differs is how the files arrive at `/app/certs/` (or `/etc/caddy/certs/`):

- **Compose:** bind mounts from `cluster/certs/`
- **Kubernetes:** a `ConfigMap` for `ca.crt` and a `Secret` of type `kubernetes.io/tls` per service, mounted via `volumeMounts` with `subPath`

The entrypoint validation and trust-store injection logic runs identically. This is the central win of the refactor.

### 3.9 Application-code rename for `agent.*` → service-specific names

Because the in-container cert basenames are changing for services that currently use `agent.crt`/`agent.key`, any application code that reads those paths must be updated. This is an intrinsic cost of Option A (distinct per-service names everywhere) chosen in §0.

**Where to look** — for each affected service, grep the service's code tree for:

```bash
grep -rn 'agent\.crt\|agent\.key\|/app/certs/agent' cluster/agent/claude/ cluster/agent/codex/ cluster/agent/mcp/ cluster/planner/ cluster/tester/ cluster/client/
```

The common locations where these paths appear are:

- `verify_isolation.py` and any isolation-check helpers that reference cert paths
- FastAPI server startup where `ssl_certfile` / `ssl_keyfile` are passed to `uvicorn`
- `entrypoint.sh` scripts that `exec` the server with cert paths as args
- Any Go `tls.LoadX509KeyPair` call in `cluster/tester/`, `git-server`, `mcp-server`, `log-server`
- Unit tests and smoke tests that construct cert paths

**Per-service rename table:**

| Service | Old in-container path | New in-container path |
|---|---|---|
| claude-server | `/app/certs/agent.crt` | `/app/certs/claude.crt` |
| claude-server | `/app/certs/agent.key` | `/app/certs/claude.key` |
| codex-server | `/app/certs/agent.crt` | `/app/certs/codex.crt` |
| codex-server | `/app/certs/agent.key` | `/app/certs/codex.key` |
| mcp-server | `/app/certs/agent.*` (if used) | `/app/certs/mcp.*` |
| plan-server | `/app/certs/agent.*` (if used) | `/app/certs/plan.*` |
| tester-server | `/app/certs/agent.*` (if used) | `/app/certs/tester.*` |
| git-server | `/app/certs/agent.*` (if used) | `/app/certs/git.*` |
| log-server | `/app/certs/agent.*` (if used) | `/app/certs/log.*` |

**Scope note.** If `claude-server` and `codex-server` share any code (they're described as symmetric in the architecture docs), that shared code must not hardcode a single `agent.*` path — each container must reference *its own* cert. The cleanest way is to parameterize via an env var or a constant defined per-service. If the shared code currently does `open("/app/certs/agent.crt")`, that's now two different paths and needs branching or config.

**Suggested env-var seam** (optional, not required for this refactor — but if touching the code anyway):

```python
# in some config module
import os
CERT_PATH = os.environ.get("SERVICE_CERT_PATH", "/app/certs/claude.crt")
KEY_PATH = os.environ.get("SERVICE_KEY_PATH", "/app/certs/claude.key")
```

Set per service in `docker-compose.yml`:

```yaml
claude-server:
  environment:
    - SERVICE_CERT_PATH=/app/certs/claude.crt
    - SERVICE_KEY_PATH=/app/certs/claude.key
codex-server:
  environment:
    - SERVICE_CERT_PATH=/app/certs/codex.crt
    - SERVICE_KEY_PATH=/app/certs/codex.key
```

This makes the shared code path-agnostic. Whether to introduce this seam is up to the implementing agent; a straight hardcoded rename is also acceptable if the codebases are truly separate.

---

## 4. Migration steps (ordered for the implementing agent)

The word **"pilot"** here means: apply all changes to one service first, test thoroughly, then propagate the pattern to the remaining services one by one.

1. **Create `cluster/gen-leaf-certs.sh`.** Test by running it standalone with a pre-existing CA in `cluster/certs/`. Verify 9 leaf pairs land with correct permissions, CNs, and SANs. Check that CNs are full hostnames (`claude-server`, `caddy-sidecar`) and filenames are short stems (`claude.crt`, `caddy.crt`). Run it twice; verify the second run overwrites cleanly.
2. **Update `run.sh`** to call `cluster/gen-leaf-certs.sh` between step 4 (CA) and step 6 (permissions). Verify `./run.sh --setup-only` now leaves 9 leaf pairs in `cluster/certs/`.
3. **Confirm `.gitignore`** excludes `cluster/certs/*.crt`, `cluster/certs/*.key`, and `cluster/certs/*.srl`. If `cluster/certs/ca.crt` was previously committed, leave the entry as specific as needed — the CA key must never be committed.
4. **Pick `log-server` as pilot.** Smallest surface area, easy to integration-test independently.
5. **Read `cluster/Dockerfile.log`** and record the in-container leaf filename currently used (likely `agent.crt`/`agent.key`). This refactor renames it to `log.crt`/`log.key`.
6. **Grep `log-server`'s code tree for any `agent.crt`/`agent.key`/`/app/certs/agent` references** (per §3.9). Update each to `log.crt`/`log.key`/`/app/certs/log.*`. This includes the Go TLS config, any helper scripts, and any tests.
7. **Edit `Dockerfile.log`:** remove `signer` stage, remove `COPY --from=signer`, remove `COPY ./certs/ca.crt`, remove trust-store injection. Add the stub `/app/certs` directory. If there's a `chmod`/`chown` on now-absent files, remove that too.
8. **Edit `log-server`'s `entrypoint.sh`:** add the Go trust-store injection block (§3.4.2). If it previously validated `agent.*` paths, update to `log.*`.
9. **Edit `cluster/docker-compose.yml`:** add the three cert mounts to `log-server` (`./certs/ca.crt`, `./certs/log.crt`, `./certs/log.key` — symmetric on both sides of the colon).
10. **Pilot test:**
    ```bash
    ./run.sh
    # verify log-server starts, check health endpoint,
    # verify TLS cert presented is log-server's leaf signed by CA
    openssl s_client -connect <host>:<log-port> -CAfile cluster/certs/ca.crt -showcerts < /dev/null
    # verify a log-writing request works end-to-end
    ```
11. **Negative tests:**
    - Remove `cluster/certs/log.key` between `./run.sh --setup-only` and `./cluster/start-cluster.sh`, start only log-server, confirm the FATAL message fires and the container exits (not restart-looping silently).
    - Swap `log.crt` with `mcp.crt` in the compose mount line, confirm TLS handshake fails with hostname mismatch (same CA, wrong SAN — log-server would present a cert whose SAN says `mcp-server`).
12. **Apply the pattern to each remaining service in this order**, doing both the Dockerfile/compose changes AND the app-code rename per §3.9 for each:
    - `git-server`, `plan-server`, `tester-server`, `mcp-server` (Go/Python backend services)
    - `proxy` (includes the trust-store subtlety in §3.6; already uses `proxy.*` so no code rename)
    - `codex-server`, `claude-server` (symmetric — do them as a pair; grep for `agent.*` carefully, especially in code shared between them)
    - `caddy-sidecar` (last, because if it breaks nothing else is reachable externally; already uses `caddy.*` so no code rename)
13. **Full integration test:** fresh `./run.sh` from scratch (delete `cluster/certs/` first to exercise CA regen too). Exercise the end-to-end flow: `POST /plan` → `POST /ask` → agent reads files, edits, runs tests, commits, completes plan. Every service touched, every TLS handshake tested.
14. **Verify no `agent.*` references remain:**
    ```bash
    grep -rn 'agent\.crt\|agent\.key\|/app/certs/agent' cluster/ && echo 'LEFTOVERS FOUND' || echo 'CLEAN'
    ```
    Expected: `CLEAN`. Any remaining references indicate a missed rename.
15. **Verify no cert material in images:**
    ```bash
    for img in cluster-claude-server cluster-codex-server cluster-mcp-server \
               cluster-plan-server cluster-tester-server cluster-git-server \
               cluster-log-server cluster-proxy cluster-caddy-sidecar; do
        docker run --rm --entrypoint sh "$img" -c \
            'ls -la /app/certs/ 2>/dev/null; ls -la /etc/caddy/certs/ 2>/dev/null'
    done
    ```
    Expected: empty directories (or directory-not-present for services that use a different mount point). Any `*.crt` or `*.key` file inside an image is a regression.
16. **Documentation:** update `docs/` with the new cert lifecycle. Consider a new `docs/certs.md` describing the trust topology for future contributors.

---

## 5. Risks and mitigations

**Risk:** A Dockerfile uses a leaf filename the grep misses (e.g. embedded in a generated config file the app reads at runtime).
**Mitigation:** §3.9 defines a one-line grep (`grep -rn 'agent\.crt\|agent\.key\|/app/certs/agent' cluster/`) that is part of the acceptance criteria. Step 14 of the migration runs it as a regression check.

**Risk:** Shared code between `claude-server` and `codex-server` hardcodes a single `agent.*` path and breaks when each needs a different path.
**Mitigation:** §3.9 calls this out explicitly and suggests the env-var seam (`SERVICE_CERT_PATH`) as the cleanest fix. Step 12 of the migration does claude and codex as a pair precisely to catch this.

**Risk:** LiteLLM internally reads `/etc/ssl/certs/ca-certificates.crt` directly and ignores `SSL_CERT_FILE`.
**Mitigation:** Pilot the proxy service specifically (§3.6). If `SSL_CERT_FILE` alone doesn't suffice, fall back to mounting the CA over `/etc/ssl/certs/ca-certificates.crt` directly via an init step that concatenates into a writable location — documented as a fallback plan.

**Risk:** Certs expire and services silently start failing.
**Mitigation:** Leaves regenerate every `run.sh`, so expiry requires the cluster to have been running untouched for 365 days. If that ever matters, add `openssl x509 -checkend 604800` warnings to the entrypoints as a follow-up.

**Risk:** A mount path typo in compose silently points at a nonexistent file.
**Mitigation:** Docker will fail the container start with a clear "no such file" error. The entrypoint validation block adds a second layer of defence with a more specific FATAL message.

**Risk:** The tmpfs for `/tmp` on some services is sized too small for the certifi bundle copy (~250KB).
**Mitigation:** Smallest current tmpfs is 64MB (Caddy), and Caddy doesn't do the certifi-style injection anyway. Proxy has 256MB. No concern; verify after migration.

**Risk:** Someone commits `cluster/certs/` by accident.
**Mitigation:** `.gitignore` entry. Optional pre-commit hook refusing commits touching `*.key` files.

**Risk:** The build cache retains old cert material in intermediate layers.
**Mitigation:** Once the signer stage is removed from each Dockerfile, there's no layer that ever contained the cert. A `docker system prune -a` after the migration flushes any historical layers.

---

## 6. What this explicitly does not do

- Does not introduce cert rotation automation (leaves already rotate every run).
- Does not encrypt cert material at rest beyond filesystem permissions.
- Does not add external ACME / real-domain TLS for caddy ingress.
- Does not change `mcp-watchdog`, isolation checks, token distribution, or the plan-execute loop.
- Does not change container hardening (memory, CPU, pids, cap_drop, read_only, tmpfs). Any observations about hardening gaps are **deliberately out of scope** for this refactor.

---

## 7. Acceptance criteria

The migration is complete when all of the following hold:

- [ ] No Dockerfile contains a `FROM ... AS signer` stage.
- [ ] No Dockerfile contains `openssl` invocations.
- [ ] No Dockerfile contains `COPY ./certs/` or `COPY certs/` for any `.crt` or `.key` file.
- [ ] `grep -r "ca.key" cluster/Dockerfile*` returns nothing.
- [ ] `grep -rn 'agent\.crt\|agent\.key\|/app/certs/agent' cluster/` returns nothing.
- [ ] `cluster/gen-leaf-certs.sh` exists, is executable, and is called from `run.sh`.
- [ ] After `./run.sh --setup-only`, `cluster/certs/` contains `ca.{crt,key}` plus 9 leaf pairs with correct permissions. Leaf filenames are short stems: `claude.*`, `codex.*`, `mcp.*`, `plan.*`, `tester.*`, `git.*`, `log.*`, `proxy.*`, `caddy.*`.
- [ ] Each leaf cert's CN and DNS SAN is the full Docker-network hostname (`claude-server`, `caddy-sidecar`, etc.), not the short filename stem.
- [ ] `docker compose build` succeeds with `cluster/certs/` deleted (proves images are cert-free at build).
- [ ] `docker compose up` fails fast with a clear error when any expected cert file is missing.
- [ ] `docker compose up` succeeds and all internal TLS handshakes work when `cluster/certs/` is populated.
- [ ] Step 15 of the migration (image cert-inventory check) returns no cert files inside any image.
- [ ] End-to-end agent flow (`POST /plan` → `POST /ask` → completion) succeeds.
- [ ] External Anthropic API call via `caddy-sidecar:8081` succeeds (proves proxy trust-store injection works).
- [ ] `cluster/docker-compose.yml` shows exactly three new mount lines per service (ca, leaf-crt, leaf-key), with host-side and container-side basenames matching.
- [ ] Documentation updated to reflect the new cert lifecycle.
