import os
import sys
import pytest
import json
from unittest.mock import patch, MagicMock

# Inject dummy env vars BEFORE importing
os.environ["MCP_API_TOKEN"] = "dummy-mcp-token"
os.environ["MCP_SERVER_URL"] = "https://mcp-server:8443"
os.environ["AGENT_API_TOKEN"] = "dummy-agent-token"

sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from files_mcp import _dispatch, call_tool


# --- _dispatch: read_workspace_file ---

@pytest.mark.asyncio
@patch("files_mcp.requests.get")
async def test_read_file_success(mock_get):
    mock_get.return_value.status_code = 200
    mock_get.return_value.text = "hello world"
    result = await _dispatch("read_workspace_file", {"file_path": "test.txt"})
    assert result == "hello world"


@pytest.mark.asyncio
@patch("files_mcp.requests.get")
async def test_read_file_not_found(mock_get):
    mock_get.return_value.status_code = 404
    with pytest.raises(FileNotFoundError):
        await _dispatch("read_workspace_file", {"file_path": "missing.txt"})


@pytest.mark.asyncio
@patch("files_mcp.requests.get")
async def test_read_file_unauthorized(mock_get):
    mock_get.return_value.status_code = 401
    with pytest.raises(PermissionError):
        await _dispatch("read_workspace_file", {"file_path": "secret.txt"})


@pytest.mark.asyncio
@patch("files_mcp.requests.get")
async def test_read_file_server_error(mock_get):
    mock_get.return_value.status_code = 500
    with pytest.raises(RuntimeError, match="500"):
        await _dispatch("read_workspace_file", {"file_path": "test.txt"})


@pytest.mark.asyncio
@patch("files_mcp.requests.get")
async def test_read_file_connection_failure(mock_get):
    mock_get.side_effect = Exception("Connection refused")
    with pytest.raises(Exception, match="Connection refused"):
        await _dispatch("read_workspace_file", {"file_path": "test.txt"})


# --- _dispatch: list_files ---

@pytest.mark.asyncio
@patch("files_mcp.requests.get")
async def test_list_files_success(mock_get):
    mock_get.return_value.status_code = 200
    mock_get.return_value.json.return_value = {
        "files": ["main.go", "subdir/test.py"],
        "count": 2
    }
    result = await _dispatch("list_files", {})
    data = json.loads(result)
    assert data["count"] == 2
    assert "main.go" in data["files"]


@pytest.mark.asyncio
@patch("files_mcp.requests.get")
async def test_list_files_server_error(mock_get):
    mock_get.return_value.status_code = 500
    mock_get.return_value.text = "server error"
    with pytest.raises(RuntimeError, match="500"):
        await _dispatch("list_files", {})


@pytest.mark.asyncio
@patch("files_mcp.requests.get")
async def test_list_files_connection_failure(mock_get):
    mock_get.side_effect = Exception("Connection refused")
    with pytest.raises(Exception, match="Connection refused"):
        await _dispatch("list_files", {})


# --- _dispatch: create_file ---

@pytest.mark.asyncio
@patch("files_mcp.requests.post")
async def test_create_file_success(mock_post):
    mock_post.return_value.status_code = 201
    result = await _dispatch("create_file", {"path": "new.txt"})
    assert result == "File created"
    args, _ = mock_post.call_args
    assert "new.txt" in args[0]


@pytest.mark.asyncio
@patch("files_mcp.requests.post")
async def test_create_file_already_exists(mock_post):
    mock_post.return_value.status_code = 400
    mock_post.return_value.text = "File already exists"
    with pytest.raises(RuntimeError, match="File already exists"):
        await _dispatch("create_file", {"path": "existing.txt"})


# --- _dispatch: write_file ---

@pytest.mark.asyncio
@patch("files_mcp.requests.post")
async def test_write_file_success(mock_post):
    mock_post.return_value.status_code = 200
    result = await _dispatch("write_file", {"path": "test.txt", "content": "hello"})
    assert "Successfully wrote" in result
    _, kwargs = mock_post.call_args
    assert kwargs["json"] == {"path": "test.txt", "content": "hello"}


@pytest.mark.asyncio
@patch("files_mcp.requests.post")
async def test_write_file_failure(mock_post):
    mock_post.return_value.status_code = 500
    mock_post.return_value.text = "disk full"
    with pytest.raises(RuntimeError, match="disk full"):
        await _dispatch("write_file", {"path": "test.txt", "content": "hello"})


@pytest.mark.asyncio
@patch("files_mcp.requests.post")
async def test_write_file_connection_failure(mock_post):
    mock_post.side_effect = Exception("Connection refused")
    with pytest.raises(Exception, match="Connection refused"):
        await _dispatch("write_file", {"path": "test.txt", "content": "hello"})


# --- _dispatch: delete_file ---

@pytest.mark.asyncio
@patch("files_mcp.requests.delete")
async def test_delete_file_success(mock_delete):
    mock_delete.return_value.status_code = 200
    result = await _dispatch("delete_file", {"path": "old.txt"})
    assert result == "File deleted"
    args, _ = mock_delete.call_args
    assert "old.txt" in args[0]


@pytest.mark.asyncio
@patch("files_mcp.requests.delete")
async def test_delete_file_failure(mock_delete):
    mock_delete.return_value.status_code = 404
    mock_delete.return_value.text = "not found"
    with pytest.raises(RuntimeError, match="not found"):
        await _dispatch("delete_file", {"path": "missing.txt"})


# --- _dispatch: unknown tool ---

@pytest.mark.asyncio
async def test_unknown_tool():
    with pytest.raises(ValueError, match="Unknown tool"):
        await _dispatch("nonexistent_tool", {})


# --- call_tool: success returns isError=False ---

@pytest.mark.asyncio
@patch("files_mcp.requests.get")
async def test_call_tool_success(mock_get):
    mock_get.return_value.status_code = 200
    mock_get.return_value.text = "file contents"
    result = await call_tool("read_workspace_file", {"file_path": "test.txt"})
    assert result.isError is False
    assert result.content[0].text == "file contents"


# --- call_tool: error returns isError=True ---

@pytest.mark.asyncio
@patch("files_mcp.requests.get")
async def test_call_tool_error(mock_get):
    mock_get.return_value.status_code = 404
    result = await call_tool("read_workspace_file", {"file_path": "missing.txt"})
    assert result.isError is True
    assert len(result.content) > 0


@pytest.mark.asyncio
async def test_call_tool_unknown(mock_get=None):
    result = await call_tool("nonexistent_tool", {})
    assert result.isError is True
    assert "Unknown tool" in result.content[0].text