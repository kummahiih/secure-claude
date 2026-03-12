import os
import sys
import pytest
from fastapi.testclient import TestClient
from unittest.mock import patch, MagicMock

# 1. Inject dummy keys BEFORE importing server.py
os.environ["CLAUDE_API_TOKEN"] = "secure-test-token"

# Ensure the local directory is in the path
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from server import app

client = TestClient(app)


# --- Auth Tests ---

def test_fastapi_endpoint_unauthorized():
    # 1. Test missing token entirely
    response = client.post("/ask", json={"model": "claude-sonnet-4-6", "query": "What is the status?"})
    assert response.status_code == 401

    # 2. Test invalid token
    headers = {"Authorization": "Bearer completely-wrong-token"}
    response = client.post("/ask", headers=headers, json={"model": "claude-sonnet-4-6", "query": "What is the status?"})
    assert response.status_code == 401


def test_fastapi_endpoint_authorized_success():
    headers = {"Authorization": f"Bearer {os.environ['CLAUDE_API_TOKEN']}"}
    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = "Here is the status."

    with patch("server.subprocess.run", return_value=mock_result) as mock_run:
        response = client.post("/ask", headers=headers, json={"model": "claude-sonnet-4-6", "query": "What is the status?"})
        assert response.status_code == 200
        json_response = response.json()
        assert json_response["response"] == "Here is the status."
        mock_run.assert_called_once_with(
            ["claude", "--print", "--model", "claude-sonnet-4-6", "What is the status?"],
            capture_output=True,
            text=True,
            timeout=120,
            env={**os.environ, "CLAUDE_CONFIG_DIR": "/app"}
        )


def test_fastapi_endpoint_authorized_claude_error():
    headers = {"Authorization": f"Bearer {os.environ['CLAUDE_API_TOKEN']}"}
    mock_result = MagicMock()
    mock_result.returncode = 1
    mock_result.stderr = "claude: error: model not found"

    with patch("server.subprocess.run", return_value=mock_result):
        response = client.post("/ask", headers=headers, json={"model": "bad-model", "query": "What is the status?"})
        assert response.status_code == 200
        json_response = response.json()
        assert "error" in json_response
        assert "model not found" in json_response["error"]


def test_fastapi_endpoint_timeout():
    import subprocess
    headers = {"Authorization": f"Bearer {os.environ['CLAUDE_API_TOKEN']}"}

    with patch("server.subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="claude", timeout=120)):
        response = client.post("/ask", headers=headers, json={"model": "claude-sonnet-4-6", "query": "Hang forever"})
        assert response.status_code == 200
        json_response = response.json()
        assert "error" in json_response
        assert "timed out" in json_response["error"]


def test_fastapi_endpoint_unexpected_exception():
    headers = {"Authorization": f"Bearer {os.environ['CLAUDE_API_TOKEN']}"}

    with patch("server.subprocess.run", side_effect=Exception("Unexpected failure")):
        response = client.post("/ask", headers=headers, json={"model": "claude-sonnet-4-6", "query": "Crash this"})
        assert response.status_code == 200
        json_response = response.json()
        assert "error" in json_response
        assert "Unexpected failure" in json_response["error"]


# --- Health Check ---

def test_health_check():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}