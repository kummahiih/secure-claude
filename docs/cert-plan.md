# Cert delivery: build-time → runtime

**Goal:** Remove cert generation from Dockerfiles. Generate certs on the host, mount them into containers. Same images work under Compose today and Kubernetes later.

## 1. New script: `cluster/gen-leaf-certs.sh`

```bash
#!/bin/bash
set -e
CERT_DIR="cluster/certs"
CA_CRT="$CERT_DIR/ca.crt"
CA_KEY="$CERT_DIR/ca.key"

gen_leaf() {
    # $1 = filename stem, $2 = DNS hostname for CN/SAN
    local stem="$1" host="$2"
    local key="$CERT_DIR/$stem.key" crt="$CERT_DIR/$stem.crt"
    local csr ext
    csr="$(mktemp)"; ext="$(mktemp)"
    openssl genrsa -out "$key" 3072 2>/dev/null
    openssl req -new -key "$key" -out "$csr" -subj "/CN=$host" 2>/dev/null
    echo "subjectAltName=DNS:$host,DNS:localhost,IP:127.0.0.1" > "$ext"
    openssl x509 -req -in "$csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
        -out "$crt" -days 365 -sha256 -extfile "$ext" 2>/dev/null
    chmod 600 "$key"; chmod 644 "$crt"
    rm -f "$csr" "$ext"
}

gen_leaf claude  claude-server
gen_leaf codex   codex-server
gen_leaf mcp     mcp-server
gen_leaf plan    plan-server
gen_leaf tester  tester-server
gen_leaf git     git-server
gen_leaf log     log-server
gen_leaf proxy   proxy
gen_leaf caddy   caddy-sidecar
```

Filename stem and CN/SAN are deliberately different: filenames are short (`claude.crt`), CNs are the Docker-network hostnames (`claude-server`).

## 2. Call it from `run.sh`

Add one step between the existing CA generation (step 4) and permissions (step 6):

```bash
# 5. Generate per-service leaf certs
./cluster/gen-leaf-certs.sh
```

## 3. Edit each Dockerfile

**Remove:**
- The `FROM alpine:... AS signer` stage
- `COPY --from=signer ...` lines
- `COPY ./certs/ca.crt ...` lines
- Any `update-ca-certificates` or `cat >> certifi.where()` lines

**Add** (before final `USER` line):
```dockerfile
RUN mkdir -p /app/certs && chown 1000:1000 /app/certs && chmod 550 /app/certs
```

Caddy uses `/etc/caddy/certs` and `caddyuser:caddygroup` instead.

## 4. Edit `cluster/docker-compose.yml`

Add three mounts per service. Host and container basenames match:

```yaml
claude-server:
  volumes:
    - ./certs/ca.crt:/app/certs/ca.crt:ro
    - ./certs/claude.crt:/app/certs/claude.crt:ro
    - ./certs/claude.key:/app/certs/claude.key:ro
```

Same pattern for `codex` (→ `codex.*`), `mcp`, `plan`, `tester`, `git`, `log`, `proxy`. For `caddy-sidecar`, target is `/etc/caddy/certs/` not `/app/certs/`.

## 5. Rename `agent.crt` / `agent.key` in app code

Claude and codex currently read `/app/certs/agent.crt`. Grep and replace:

```bash
grep -rn 'agent\.crt\|agent\.key\|/app/certs/agent' cluster/
```

In `claude-server` code → `claude.crt` / `claude.key`.
In `codex-server` code → `codex.crt` / `codex.key`.

Other services may already use service-specific names; if any still use `agent.*`, rename to match the table in §1.

## 6. Move trust-store injection to runtime

Trust-store injection can't happen at build anymore (CA no longer in image). Move it to the existing startup script in each service.

**Python services** (claude, codex, proxy — in `verify_isolation.py` or `proxy_wrapper.py`):
```python
import os, shutil, certifi
BUNDLE = "/tmp/ssl/ca-bundle.crt"
os.makedirs("/tmp/ssl", exist_ok=True)
shutil.copy(certifi.where(), BUNDLE)
with open("/app/certs/ca.crt", "rb") as f:
    open(BUNDLE, "ab").write(b"\n" + f.read())
os.environ["SSL_CERT_FILE"] = BUNDLE
os.environ["REQUESTS_CA_BUNDLE"] = BUNDLE
os.environ["CURL_CA_BUNDLE"] = BUNDLE
os.environ["NODE_EXTRA_CA_CERTS"] = "/app/certs/ca.crt"
```

**Go services** (mcp, git, tester, log — in their `entrypoint.sh`):
```bash
mkdir -p /tmp/ssl
cp /etc/ssl/certs/ca-certificates.crt /tmp/ssl/ca-bundle.crt 2>/dev/null || : > /tmp/ssl/ca-bundle.crt
cat /app/certs/ca.crt >> /tmp/ssl/ca-bundle.crt
export SSL_CERT_FILE=/tmp/ssl/ca-bundle.crt
```

**Caddy:** nothing to do — Caddyfile already reads `/etc/caddy/certs/ca.crt` via `tls_trusted_ca_certs`.

## Done criteria

- `grep -rn 'FROM.*AS signer' cluster/Dockerfile*` → empty
- `grep -rn 'agent\.crt\|agent\.key' cluster/` → empty
- `./run.sh` starts the cluster cleanly, end-to-end flow works
- Anthropic API calls through `caddy-sidecar:8081` still work (confirms proxy trust injection)
