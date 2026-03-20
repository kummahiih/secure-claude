import os
import sys
import subprocess
import pytest
from unittest.mock import MagicMock, patch

# Mock out modules that require runtime environment / side-effects before importing server
sys.modules.setdefault("setuplogging", MagicMock())
sys.modules["runenv"] = MagicMock(
    CLAUDE_API_TOKEN="dummy-token",
    DYNAMIC_AGENT_KEY="dummy-key",
    ANTHROPIC_BASE_URL="https://api.anthropic.com",
    MCP_API_TOKEN="dummy-mcp-token",
    SYSTEM_PROMPT="test system prompt",
    PLAN_SYSTEM_PROMPT="test plan system prompt",
)
sys.modules["verify_isolation"] = MagicMock()

# server.py lives in cluster/agent/claude/
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cluster", "agent", "claude"))

from fastapi.testclient import TestClient  # noqa: E402
from server import app  # noqa: E402

client = TestClient(app, raise_server_exceptions=False)

AUTH_HEADERS = {"Authorization": "Bearer dummy-token"}
VALID_PAYLOAD = {"query": "hello", "model": "claude-opus-4-5"}


def _oauth_expired_proc():
    """Return a CompletedProcess simulating an OAuth-expired upstream error."""
    return subprocess.CompletedProcess(
        args=[],
        returncode=1,
        stdout="",
        stderr="Error: OAuth token has expired, please re-authenticate.",
    )


class TestAskReturns502OnOauthStderr:
    def test_ask_returns_502_on_oauth_stderr(self):
        """POST /ask returns HTTP 502 when subprocess stderr contains OAuth expiry marker."""
        with patch("subprocess.run", return_value=_oauth_expired_proc()):
            response = client.post("/ask", json=VALID_PAYLOAD, headers=AUTH_HEADERS)
        assert response.status_code == 502


class TestPlanReturns502OnOauthStderr:
    def test_plan_returns_502_on_oauth_stderr(self):
        """POST /plan returns HTTP 502 when subprocess stderr contains OAuth expiry marker."""
        with patch("subprocess.run", return_value=_oauth_expired_proc()):
            response = client.post("/plan", json=VALID_PAYLOAD, headers=AUTH_HEADERS)
        assert response.status_code == 502
