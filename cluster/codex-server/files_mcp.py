"""
files_mcp.py — MCP stdio server wrapping the mcp-server REST API.
Standalone version for codex-server: reads tokens from environment directly.
"""

import logging
import os
import json
import requests
import threading
import asyncio
from mcp.server import Server
from mcp import types
from mcp.types import CallToolResult, TextContent
from mcp.server.stdio import stdio_server

logger = logging.getLogger(__name__)

MCP_SERVER_URL = os.environ.get("MCP_SERVER_URL", "https://mcp-server:8443")
MCP_API_TOKEN = os.environ.get("MCP_API_TOKEN", "")
LOG_SERVER_URL = os.environ.get("LOG_SERVER_URL", "https://log-server:8443")
LOG_API_TOKEN = os.environ.get("LOG_API_TOKEN", "")

HEADERS = {"Authorization": f"Bearer {MCP_API_TOKEN}"}
VERIFY = "/app/certs/ca.crt"


def _emit_log_event(event: dict) -> None:
    """Fire-and-forget: POST event to log-server /ingest."""
    if not LOG_SERVER_URL or not LOG_API_TOKEN:
        return
    try:
        requests.post(
            f"{LOG_SERVER_URL}/ingest",
            json=event,
            headers={"Authorization": f"Bearer {LOG_API_TOKEN}"},
            verify=VERIFY,
            timeout=5,
        )
    except Exception as exc:
        logger.debug("log_emit failed: %s", exc)


server = Server("fileserver")


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="read_workspace_file",
            description="Reads the contents of a file from the secure workspace.",
            inputSchema={
                "type": "object",
                "properties": {
                    "file_path": {"type": "string", "description": "Path to the file"}
                },
                "required": ["file_path"],
            },
        ),
        types.Tool(
            name="list_files",
            description="Recursively lists all files and directories in the workspace.",
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="create_file",
            description="Creates a new empty file in the workspace.",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path for the new file"}
                },
                "required": ["path"],
            },
        ),
        types.Tool(
            name="write_file",
            description="Overwrites the entire content of a file with new content.",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path to the file"},
                    "content": {"type": "string", "description": "Content to write"},
                },
                "required": ["path", "content"],
            },
        ),
        types.Tool(
            name="delete_file",
            description="Removes a file from the workspace.",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path to the file"}
                },
                "required": ["path"],
            },
        ),
        types.Tool(
            name="grep_files",
            description="Search all files in the workspace for lines matching a regexp pattern. Returns results as 'file:lineno: line' strings.",
            inputSchema={
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "Regular expression pattern to search for"},
                    "max_results": {"type": "integer", "description": "Maximum number of matching lines to return (default 100)"},
                },
                "required": ["pattern"],
            },
        ),
        types.Tool(
            name="replace_in_file",
            description="Replace all occurrences of old_string with new_string in a file. Returns the number of replacements made.",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path to the file"},
                    "old_string": {"type": "string", "description": "String to search for"},
                    "new_string": {"type": "string", "description": "String to replace with"},
                },
                "required": ["path", "old_string", "new_string"],
            },
        ),
        types.Tool(
            name="append_file",
            description="Appends content to an existing (or new) file. Returns the number of bytes written.",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path to the file"},
                    "content": {"type": "string", "description": "Content to append"},
                },
                "required": ["path", "content"],
            },
        ),
        types.Tool(
            name="create_directory",
            description="Creates a new directory in the workspace.",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path for the new directory"}
                },
                "required": ["path"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> CallToolResult:
    try:
        result = await _dispatch(name, arguments)
        return CallToolResult(
            content=[TextContent(type="text", text=result)],
            isError=False,
        )
    except Exception as e:
        logger.error(f"Tool {name} error: {e}")
        return CallToolResult(
            content=[TextContent(type="text", text=str(e))],
            isError=True,
        )


async def _dispatch(name: str, arguments: dict) -> str:
    if name == "read_workspace_file":
        response = requests.get(
            f"{MCP_SERVER_URL}/read",
            params={"path": arguments["file_path"]},
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            threading.Thread(
                target=_emit_log_event,
                args=({"event_type": "file_read", "path": arguments["file_path"], "size_bytes": len(response.text)},),
                daemon=True,
            ).start()
            return response.text
        elif response.status_code == 401:
            raise PermissionError("Unauthorized. Token mismatch.")
        elif response.status_code == 404:
            raise FileNotFoundError("File not found or access denied by OS jail.")
        else:
            raise RuntimeError(f"Server returned status {response.status_code}")

    elif name == "list_files":
        response = requests.get(
            f"{MCP_SERVER_URL}/list",
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            files = response.json().get("files", [])
            return json.dumps({"files": files, "count": len(files)})
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "create_file":
        response = requests.post(
            f"{MCP_SERVER_URL}/create",
            params={"path": arguments["path"]},
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 201:
            return "File created"
        else:
            raise RuntimeError(response.text)

    elif name == "write_file":
        response = requests.post(
            f"{MCP_SERVER_URL}/write",
            json={"path": arguments["path"], "content": arguments["content"]},
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            return f"Successfully wrote to {arguments['path']}"
        else:
            raise RuntimeError(f"Failed to write: {response.status_code} - {response.text}")

    elif name == "delete_file":
        response = requests.delete(
            f"{MCP_SERVER_URL}/remove",
            params={"path": arguments["path"]},
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            return "File deleted"
        else:
            raise RuntimeError(response.text)

    elif name == "grep_files":
        payload = {"pattern": arguments["pattern"]}
        if "max_results" in arguments:
            payload["max_results"] = arguments["max_results"]
        response = requests.post(
            f"{MCP_SERVER_URL}/grep",
            json=payload,
            headers=HEADERS,
            verify=VERIFY,
            timeout=30,
        )
        if response.status_code == 200:
            matches = response.json()
            lines = [f"{m['file']}:{m['line_number']}: {m['line']}" for m in matches]
            return "\n".join(lines) if lines else "(no matches)"
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "replace_in_file":
        response = requests.post(
            f"{MCP_SERVER_URL}/replace",
            json={
                "path": arguments["path"],
                "old_string": arguments["old_string"],
                "new_string": arguments["new_string"],
            },
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            return str(response.json().get("replacements_made", 0))
        elif response.status_code == 404:
            raise FileNotFoundError("File not found or access denied by OS jail.")
        elif response.status_code == 422:
            raise ValueError("old_string not found in file.")
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "append_file":
        response = requests.post(
            f"{MCP_SERVER_URL}/append",
            json={"path": arguments["path"], "content": arguments["content"]},
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            return str(response.json().get("bytes_written", 0))
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "create_directory":
        response = requests.post(
            f"{MCP_SERVER_URL}/mkdir",
            params={"path": arguments["path"]},
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 201:
            return "Directory created"
        elif response.status_code == 409:
            raise FileExistsError(f"Directory already exists: {arguments['path']}")
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    else:
        raise ValueError(f"Unknown tool {name}")


if __name__ == "__main__":
    async def main():
        async with stdio_server() as (read_stream, write_stream):
            await server.run(
                read_stream,
                write_stream,
                server.create_initialization_options(),
            )

    asyncio.run(main())
