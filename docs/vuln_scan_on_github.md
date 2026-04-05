
High / Critical issues (action ASAP)
1) Private CA key and private keys being used at build time and included in images
   - Evidence:
     - cluster/Dockerfile.claude: RUN --mount=type=bind,src=./certs/ca.key,target=/tmp/ca.key (lines 8–9) and COPY --from=signer /certs/agent.key /app/certs/agent.key (lines 95–96).
     - cluster/Dockerfile.proxy and cluster/Dockerfile.caddy have the same build-time bind and signer usage (proxy lines 8–14, caddy lines 6–12).
   - Risk: embedding private keys into images or exposing them via build cache lets any holder of the image or builder cache extract private keys, leading to full compromise (impersonation, MITM).
   - Remediation:
     - Never bake private keys into images. Use runtime mounts/secrets or a secure secret store. If you must provision certs during build, use ephemeral build secrets that are not written into the final image and avoid copying private keys into final stages.
     - If keys were distributed in any images or CI caches, rotate/replace the CA and all affected certificates immediately.

2) Private keys present in image final stage (sensitive data in images)
   - Evidence: cluster/Dockerfile.claude copies generated agent.key into the final image (line 96).
   - Risk: images are often pushed/shared; private keys inside an image are a major supply-chain/credential exposure.
   - Remediation: remove copying of private keys into final image; mount private keys at runtime or use an external certificate provisioning mechanism.

3) Use of curl | bash in image builds (remote code execution risk)
   - Evidence: cluster/Dockerfile.claude runs: curl -fsSL https://deb.nodesource.com/setup_22.x | bash - (line 44).
   - Risk: piping remote script to shell executes unverified remote code during image build; upstream compromise or MITM could inject malicious code.
   - Remediation: avoid piped installer scripts. Prefer official, pinned base images that include Node or download an archive and verify checksum/signature before installing. Or use a multi-stage build that uses an official node base as builder.

High risk / Supply-chain & image issues
4) Unpinned external base image by tag
   - Evidence: cluster/Dockerfile.proxy FROM ghcr.io/berriai/litellm:main-v1.82.3-stable.patch.2 (line 17) uses a tag rather than a digest.
   - Risk: tag can be moved; attacker with registry access could replace tag contents.
   - Remediation: pin external images by digest (sha256) and verify provenance.

5) NPM global install of third‑party package
   - Evidence: cluster/Dockerfile.claude RUN npm install -g @anthropic-ai/claude-code@2.1.74 (line 48).
   - Risk: arbitrary code installed, possible malicious package or vulnerability. Global npm installs increase attack surface.
   - Remediation: prefer installing only required, audited packages, lockfile-based installs, or including a build step that verifies packages (npm audit/fix, verify checksums).

Medium issues
6) Secrets passed via environment variables in docker-compose
   - Evidence: cluster/docker-compose.yml sets many env vars from host (examples: DYNAMIC_AGENT_KEY, ANTHROPIC_API_KEY, MCP_API_TOKEN, CLAUDE_API_TOKEN, GIT_API_TOKEN, LOG_API_TOKEN) (lines 44–58 and 75–92).
   - Risk: env vars are exposed via docker inspect and process environment; risk of accidental leakage and easier exfiltration if container is compromised.
   - Remediation: use Docker secrets or a secrets manager; avoid placing long-lived credentials in plain env vars in shared config. Ensure any .env files are not committed and are in .gitignore.

7) Host mounts that expose host filesystem and .git directory
   - Evidence: docker-compose mounts:
     - claude-server: ./workspace/docs:/docs:ro (line 95)
     - mcp-server: ./workspace:/workspace (line 122)
     - git-server: ./workspace/.git:/gitdir and ./workspace:/workspace:ro (lines 190–191)
     - log-server: ./logs:/logs:rw (line 211)
   - Risk: read-write mounts of host dirs allow processes in containers to read or modify host files; mounting .git into a container that has access could leak repository secrets or be used to tamper with code.
   - Remediation: restrict mounts, use least privilege (read-only where possible), use dedicated data volumes rather than direct host paths, and review which services truly require access to host .git. For git-like services, use isolated git server storage.

8) Attempted .git shadowing via tmpfs may be fragile
   - Evidence: mcp-server tmpfs: /workspace/.git:ro,size=0 — intended "Shadow .git — structural hook prevention" (line 124).
   - Risk: tmpfs overlay semantics plus host mounts can be platform-dependent; could fail to prevent hooks or allow .git access inadvertently.
   - Remediation: validate behavior across target platforms; prefer not to rely on tmpfs/size=0 tricks. Use proper volume isolation or remove .git from workspace before mounting.

9) TLS verification disabled in healthcheck
   - Evidence: cluster/Dockerfile.caddy HEALTHCHECK uses wget --no-check-certificate https://localhost:8443/ (line 49).
   - Risk: no verification diminishes the value of the healthcheck and can mask TLS problems; it may also be a sign of misconfigured TLS trust.
   - Remediation: configure healthcheck to use the container's CA bundle, or call a local HTTP endpoint, or use curl with --cacert pointing to the CA certificate.

Low / informational items
10) Pinned Python and Alpine base images (good) but mixed package managers
    - Evidence: cluster/Dockerfile.claude uses python:3.12-slim@sha256:... (line 16) and earlier Alpine:3.23.3 in signer stage (line 1).
    - Notes: pinning by digest is good for reproducibility. However, the Dockerfile mixes Debian-based apt operations and an external curl script; review consistency.

12) Submodules and external repositories (supply chain)
    - Evidence: .gitmodules references external repos (cluster/agent, cluster/planner, cluster/tester) (lines 1–9).
    - Risk: submodule code is a supply-chain vector; changes in those repos affect build/run security.
    - Remediation: pin submodule commits (avoid floating refs), review and audit submodule contents, and lock submodule SHAs in your repo.


Recommended immediate steps (concise)
- Immediately ensure private keys are not baked into any published image. If any images containing private keys were pushed or shared, rotate the CA and any affected certificates.
- Stop using curl | bash in builds; replace with verified installs or use official node base images pinned to digest.
- Replace env-based secret injection for sensitive long-lived tokens with a secrets manager or Docker secrets; do not commit .env files. Rotate tokens if they were exposed.
- Scan dependencies and images with vulnerability scanners (SCA for Python/npm, container scanners). Fix any CVEs found and enable automated dependency alerts (e.g., Dependabot or equivalent).
- Pin external images to digests and pin submodule commits.


- Search repo for accidental secrets: grep -RI --line-number -E "BEGIN RSA PRIVATE KEY|PRIVATE KEY|AWS_SECRET|AWS_ACCESS_KEY_ID|ANTHROPIC|API_KEY|PASSWORD" .

- Check built images for embedded secrets: docker run --rm -it --entrypoint sh <image> -c "find / -name '*.key' -o -name '*.pem' -o -readlink -f /app/certs || true"

