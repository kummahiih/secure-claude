import sys
import os
import logging

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("proxy_isolation")

# --- Isolation checks: run before anything else ---
# Proxy MUST have the real API key. It must NOT have agent-side tokens.
REQUIRED = ["ANTHROPIC_API_KEY", "DYNAMIC_AGENT_KEY"]
FORBIDDEN = ["MCP_API_TOKEN", "CLAUDE_API_TOKEN"]

violations = []
for var in REQUIRED:
    if not os.environ.get(var):
        violations.append(f"REQUIRED env var missing: {var}")
for var in FORBIDDEN:
    if os.environ.get(var):
        violations.append(f"FORBIDDEN env var present: {var}")

if violations:
    logger.error("=== PROXY ISOLATION CHECK FAILED ===")
    for v in violations:
        logger.error(f"  ✗ {v}")
    logger.error(f"=== {len(violations)} violation(s) — refusing to start ===")
    sys.exit(1)

logger.info(f"Proxy isolation checks passed ({len(REQUIRED) + len(FORBIDDEN)} checks)")

# --- Normal proxy startup ---
# Import here so it sees the modified environment
from litellm.proxy.proxy_cli import run_server

os.environ['http_proxy'] = ''
os.environ['https_proxy'] = ''
os.environ['HTTP_PROXY'] = ''
os.environ['HTTPS_PROXY'] = ''

if __name__ == "__main__":
    sys.argv = [
        "litellm",
        "--config", "/tmp/config.yaml",
        "--port", "4000",
        "--host", "0.0.0.0",
        "--ssl_keyfile_path", "/app/certs/proxy.key",
        "--ssl_certfile_path", "/app/certs/proxy.crt"
    ]
    run_server()
