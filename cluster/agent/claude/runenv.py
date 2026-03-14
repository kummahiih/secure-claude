import os
import setuplogging
import logging

logger = logging.getLogger(__name__)

# Environment variables injected by Docker Compose / run.sh
MCP_SERVER_URL = os.getenv("MCP_SERVER_URL", "https://mcp-server:8443")
MCP_API_TOKEN = os.getenv("MCP_API_TOKEN")
if not MCP_API_TOKEN:
    logging.error("MCP_API_TOKEN is not set!")

CLAUDE_API_TOKEN = os.getenv("CLAUDE_API_TOKEN")
if not CLAUDE_API_TOKEN:
    logging.error("CLAUDE_API_TOKEN is not set!")

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")
# Ensure we have the key, otherwise the agent will fail silently with 401s
if not ANTHROPIC_API_KEY:
    logging.error("DYNAMIC_AGENT_KEY (passed as ANTHROPIC_API_KEY) is not set!")

ANTHROPIC_BASE_URL = os.getenv("ANTHROPIC_BASE_URL")
if not ANTHROPIC_BASE_URL:
    logging.error("ANTHROPIC_BASE_URL is not set!")


