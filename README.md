
# 🛡️ Secure MCP Cluster

A hardened, containerized environment for AI Agents to interact with local system tools via the Model Context Protocol (MCP). This setup utilizes a sidecar architecture to enforce TLS encryption and token-based authentication across all internal services.

## 🏗️ System Architecture



### Service Roles
* **Caddy Sidecar**: The gateway. Handles SSL termination (TLS 1.3) and provides a secure ingress point to the internal network.
* **LangChain Server**: The orchestrator. Runs the LangGraph/Agent logic and coordinates between the LLM and local tools.
* **LiteLLM Proxy**: The API gateway. Provides a unified interface for LLM providers (Ollama, OpenAI, etc.) while managing egress credentials.
* **MCP Server**: The execution layer. A secure Go service using `os.OpenRoot` to provide restricted filesystem access to the `/workspace` volume.

---

## 🔌 Network Topology

The cluster enforces an "Air-Gap" style isolation using two distinct Docker networks:

### 🛰️ Service Inventory
| Service | Image | Network(s) | Ports (Exposed) | Description |
| :--- | :--- | :--- | :--- | :--- |
| **`caddy-sidecar`** | `caddy:2-alpine` | `ext_net`, `int_net` | `8443:8443` | SSL Termination & External Ingress |
| **`proxy`** | `litellm:main-latest` | `ext_net`, `int_net` | *None* | Secure Gateway to Gemini/OpenAI |
| **`claude-server`**| `Dockerfile.claude`| `int_net` | *None* | Logic Engine (Agent) |
| **`mcp-server`** | `Dockerfile.mcp` | `int_net` | *None* | Tool Provider (Workspace Access) |

### Internal Communication Path
1.  **User Request**: `Host` -> `https://localhost:8443` -> `Caddy`
2.  **Logic Processing**: `Caddy` -> `https://claude-server:8000`
3.  **Tool Execution**: `LangChain` -> `https://mcp-server:8443/read`
4.  **Inference**: `LangChain` -> `https://proxy:4000/v1/chat/completions`
---

## 🔒 Security Guardrails

### 1. Unified Trust Chain
All services mount a shared `./certs` volume. By setting the `SSL_CERT_FILE` environment variable, every container (Python, Go, and Caddy) trusts the internal Root CA, allowing for seamless internal HTTPS without `InsecureRequestWarning`.

### 2. Filesystem Jail
The MCP server implements the new `os.OpenRoot` capability. This creates a logical "jail" at `/workspace`. Even if an agent is prompted to perform a directory traversal attack (e.g., `../../etc/passwd`), the Go runtime will block the request at the system level.

### 3. Dual-Layer Authentication
* **Ingress Auth**: Managed by Caddy/FastAPI via `CLAUDE_API_TOKEN`.
* **Service Auth**: The LangChain server communicates with the MCP server using a dedicated `MCP_API_TOKEN`.

### 4. Using https everywhere


---


## 📂 Project files

This project is structured into modular microservices, separating the edge routing, the language model agent, and the file system tools into distinct, containerized domains.

```text
.
├──cluster/
|   ├── claude/                  # Python LangChain integration and agent logic
│   | ├── claude_tests.py     # Unit tests for the agent and tools
│   | └── server.py             # FastAPI server exposing the agent endpoints
|   ├── caddy/                  # Edge router and reverse proxy
|   │   ├── Caddyfile           # TLS and reverse proxy configuration
|   │   └── caddy_test.sh       # Validation script for Caddy configuration
|   ├── fileserver/             # Golang MCP (Model Context Protocol) file server
|   │   ├── go.mod              # Go module dependencies
|   │   ├── main.go             # Core MCP server logic and tool handlers
|   │   └── mcp_test.go         # Unit tests for the Go MCP handlers
|   ├── proxy/                  # Local proxy wrappers and routing
|   │   ├── proxy_config.yaml   # Proxy configuration rules
|   │   └── proxy_wrapper.py    # Python wrapper for proxy execution
|   ├── docker-compose.yml      # Orchestrates the Caddy, Agent, and MCP containers
|   ├── Dockerfile.claude    # Container build steps for the Python agent
|   ├── Dockerfile.mcp          # Container build steps for the Go fileserver
|   ├── Dockerfile.caddy        # Container build steps for the sidecar Caddy
|   ├── Dockerfile.proxy        # Container build steps for the LiteLLM Proxy
|   └── start-cluster.sh        # starts the cluster (used by run.sh)
├── init_build.sh           # Initial environment setup and build script
├── query.sh                # CLI utility for sending test queries to the agent
├── run.sh                  # Operational script (generates certs, manages lifecycle)
├── test.sh                 # Master test suite (runs unit and integration tests)
└── README.md               # Project intruduction
```

## 🛠️ Operational Commands

### Initialize and Start
The `run.sh` script automates certificate generation, token rotation, and container orchestration:
```bash
./run.sh
./query.sh local "Please read info.txt from my workspace."
./query.sh remote "Please read info.txt from my workspace."

```

## 🛡️ Security & Quality Auditing

This project implements a multi-layered security approach to ensure dependencies and infrastructure are secure. We utilize industry-standard open-source tools to scan for vulnerabilities and misconfigurations.

### 🔍 Security Toolset

| Tool | Focus Area | Purpose |
| :--- | :--- | :--- |
| **pip-audit** | Python Libraries | Scans `claude/requirements.txt` for known CVEs. |
| **govulncheck** | Go Modules | Analyzes Go code for reachable vulnerabilities. |
| **hadolint** | Dockerfiles | Lints `Dockerfile.*` for security best practices. |
| **trivy** | Infrastructure | Scans `docker-compose.yml` and images for leaks. |


### 🚀 Running the Full Test Suite
To run the full suite (auditing Python, Go, and Docker configurations), execute:

```bash
./test.sh
```
