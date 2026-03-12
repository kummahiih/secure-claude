import os
import setuplogging
import logging

logger = logging.getLogger(__name__)

# Environment variables injected by Docker Compose / run.sh
MCP_SERVER_URL = os.getenv("MCP_SERVER_URL", "https://mcp-server:8443")
MCP_API_TOKEN = os.getenv("MCP_API_TOKEN")
CLAUDE_API_TOKEN = os.getenv("CLAUDE_API_TOKEN")
# Ensure we have the key, otherwise the agent will fail silently with 401s
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
if not OPENAI_API_KEY:
    logging.error("DYNAMIC_AGENT_KEY (passed as OPENAI_API_KEY) is not set!")
