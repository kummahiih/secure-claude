# Codex Integration Plan

**Objective:** Introduce OpenAI's Codex agent (`@openai/codex`) to the Secure Claude architecture as a parallel, isolated service (`codex-server`). This allows utilizing both Claude Code and Codex on the same workspace, sharing the same MCP tools, while maintaining zero-trust credential handling and network isolation.

---

## 1. Container & Infrastructure Layer

### Dockerfile (`cluster/Dockerfile.codex`)
* **Base:** Create a new Dockerfile cloning the structure of `Dockerfile.claude`.
* **Dependencies:** Install Python (for FastAPI server) and Node.js.
* **Agent Installation:** Run `npm install -g @openai/codex` instead of Claude Code.
* **Permissions:** Ensure the `appuser` (UID 1000) owns the necessary config directories (e.g., `~/.codex`).

### Docker Compose (`docker-compose.yml`)
* Add `codex-server` service alongside `claude-server`.
* **Build Context:** Point to `Dockerfile.codex`.
* **Network:** Attach strictly to `int_net` (no external network access).
* **Volumes:** * Mount `./workspace:/workspace` (same as Claude).
    * Mount `certs/` for TLS.
* **Environment Variables:**
    * `OPENAI_BASE_URL=http://proxy:4000/v1` (Forces traffic through LiteLLM).
    * `OPENAI_API_KEY=${DYNAMIC_AGENT_KEY}` (Zero-trust ephemeral token).
    * `CODEX_API_TOKEN=${CODEX_API_TOKEN}` (Ingress protection).

### Caddy Configuration (`cluster/caddy/Caddyfile`)
* **Inbound Rules:** Add a reverse proxy route for the host to access `codex-server`.
    * Map a new port (e.g., `:8444` or base it on path `/codex`) routing to `https://codex-server:8000`.
* **Outbound Rules (Proxy):** Ensure Caddy still strictly prevents external egress for `codex-server`, forcing all outbound LLM traffic to hit the `proxy` service.

---

## 2. Certificates & Authentication

### Initialization Script (`init_build.sh`)
* **Token Generation:** Add logic to generate a `CODEX_API_TOKEN` alongside the existing `CLAUDE_API_TOKEN`. Write this to `.secrets.env`.
* **Certificates:** Add `codex-server` to the `mkcert` generation loop so it gets trusted internal TLS certificates.

### Proxy Configuration (`cluster/proxy/proxy_config.yaml`)
* **LiteLLM Routing:** Add model endpoints for Codex (e.g., `openai/gpt-5.3-codex` or `openai/gpt-4o`).
* **Key Mapping:** Bind these models to `os.environ/OPENAI_API_KEY` (the real key stored in `.secrets.env`).

---

## 3. Service Implementation (`codex-server`)

### Server Wrapper (`cluster/codex-server/server.py`)
* Implement a FastAPI wrapper identical in contract to `claude-server/server.py`.
* **Endpoints Required:**
    * `POST /query` (Executes standard Codex prompt).
    * `POST /plan` (Executes Codex with strict instructions to interact with `plan-server`).
* **Subprocess Execution:** Invoke the Codex CLI using `pexpect` or `subprocess.Popen`, capturing stdout/stderr and streaming it back to the client.
* **Auth Guard:** Validate `X-API-Token` against `CODEX_API_TOKEN`.

### MCP Integration
* Codex needs an MCP configuration file (similar to Claude's tool config).
* Generate a `mcp.json` (or Codex equivalent) during container startup that points Codex to:
    * `https://mcp-server:8443` (Filesystem)
    * `https://git-server:8443` (Git)
    * `https://tester-server:8443` (Tests)
    * `https://plan-server:8443` (Planner)
* Ensure all tool definitions inject the respective subsystem tokens (`MCP_API_TOKEN`, etc.) in the HTTP headers.

---

## 4. Client Shell Scripts

### Parameter Modification: `query.sh` and `plan.sh`
* **Current Signature:** `./query.sh <model> "<query>"`
* **New Signature:** `./query.sh -a <agent> -m <model> "<query>"` (e.g., `./query.sh -a codex -m gpt-4o "do work"`).
* **Fallback/Default:** If `-a` is not provided, default to `claude` to prevent breaking existing developer workflows.
* **Routing Logic:** * If `agent == claude`, curl `https://localhost:8443` with `CLAUDE_API_TOKEN`.
    * If `agent == codex`, curl the new route (e.g., `https://localhost:8444`) with `CODEX_API_TOKEN`.

### Log Tailer (`logs.sh`)
* Add `codex-server` to the `docker compose logs -f` command.
* Color-code `codex-server` output differently from `claude-server` for readability.

---

## 5. Security & Integration Testing

### Test Script (`test-integration.sh`)
* Add endpoint liveliness checks for `codex-server`.
* Run a dummy execution test specifically invoking `./query.sh -a codex -m gpt-4o "echo hello"` to verify end-to-end execution and MCP tool binding.

### Security Assertions (`check_isolation.py`)
* Add a dedicated role and test suite for `codex-server`.
* **Test 1 (Network Egress):** Assert `docker exec codex-server ping 8.8.8.8` fails.
* **Test 2 (Proxy Access):** Assert `docker exec codex-server curl http://proxy:4000/v1/models` succeeds.
* **Test 3 (Filesystem Jail):** Assert `codex-server` cannot access host mounts outside of `/workspace` via tool calls.
* **Test 4 (Key Exposure):** Assert `codex-server` environment variables *do not* contain the real `OPENAI_API_KEY`, only the ephemeral proxy token.

---

## 6. Documentation Updates

### Secrets Environment (`.secrets.env.example`)
* Add `OPENAI_API_KEY=sk-proj-...`
* Add `CODEX_API_TOKEN=gen_...` (auto-generated placeholder).

### Login Instructions / Readme
* Update `README.md` to explain the dual-agent architecture.
* Document how to choose between agents using the `-a` flag.
* *(Optional)* Document the Alternative Authentication flow: If a user wants to use a ChatGPT Plus subscription instead of an API key, explain how to run `codex login` on the host machine and bind-mount `~/.codex/auth.json` to the container (noting the trade-off regarding LiteLLM MITM compatibility).

### Claude's Context (`CLAUDE.md`)
* Update the system architecture diagram/description so Claude understands it has a sibling container (`codex-server`).
* Outline the script signature changes so Claude writes correct commands when creating shell execution plans.