import logging
import requests
import json
import setuplogging
from runenv import MCP_SERVER_URL, MCP_API_TOKEN
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp import types

logger = logging.getLogger(__name__)

server = Server("fileserver")
HEADERS = {"Authorization": f"Bearer {MCP_API_TOKEN}"}
VERIFY = "/app/certs/ca.crt"


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
                "required": ["file_path"]
            }
        ),
        types.Tool(
            name="list_files",
            description="Recursively lists all files and directories in the workspace.",
            inputSchema={
                "type": "object",
                "properties": {}
            }
        ),
        types.Tool(
            name="create_file",
            description="Creates a new empty file in the workspace.",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path for the new file"}
                },
                "required": ["path"]
            }
        ),
        types.Tool(
            name="write_file",
            description="Overwrites the entire content of a file with new content.",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path to the file"},
                    "content": {"type": "string", "description": "Content to write"}
                },
                "required": ["path", "content"]
            }
        ),
        types.Tool(
            name="delete_file",
            description="Removes a file from the workspace.",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path to the file"}
                },
                "required": ["path"]
            }
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    try:
        result = await _dispatch(name, arguments)
    except Exception as e:
        logger.error(f"Tool {name} failed: {e}")
        result = f"Error: {str(e)}"
    return [types.TextContent(type="text", text=result)]


async def _dispatch(name: str, arguments: dict) -> str:
    if name == "read_workspace_file":
        file_path = arguments["file_path"]
        response = requests.get(
            f"{MCP_SERVER_URL}/read?path={file_path}",
            headers=HEADERS, verify=VERIFY, timeout=10
        )
        if response.status_code == 200:
            return response.text
        elif response.status_code == 401:
            return "Error: Unauthorized. Token mismatch."
        elif response.status_code == 404:
            return "Error: File not found or access denied by OS jail."
        else:
            return f"Error: Server returned status {response.status_code}"

    elif name == "list_files":
        response = requests.get(
            f"{MCP_SERVER_URL}/list",
            headers=HEADERS, verify=VERIFY, timeout=10
        )
        if response.status_code == 200:
            files = response.json().get("files", [])
            return json.dumps({"files": files, "count": len(files)})
        else:
            return json.dumps({"error": f"HTTP {response.status_code}", "detail": response.text})

    elif name == "create_file":
        response = requests.post(
            f"{MCP_SERVER_URL}/create?path={arguments['path']}",
            headers=HEADERS, verify=VERIFY, timeout=10
        )
        return "File created" if response.status_code == 201 else f"Error: {response.text}"

    elif name == "write_file":
        response = requests.post(
            f"{MCP_SERVER_URL}/write",
            json={"path": arguments["path"], "content": arguments["content"]},
            headers=HEADERS, verify=VERIFY, timeout=10
        )
        if response.status_code == 200:
            return f"Successfully wrote to {arguments['path']}"
        else:
            return f"Failed to write file: {response.status_code} - {response.text}"

    elif name == "delete_file":
        response = requests.delete(
            f"{MCP_SERVER_URL}/remove?path={arguments['path']}",
            headers=HEADERS, verify=VERIFY, timeout=10
        )
        return "File deleted" if response.status_code == 200 else f"Error: {response.text}"

    else:
        return f"Error: Unknown tool {name}"


if __name__ == "__main__":
    import asyncio
    asyncio.run(stdio_server(server))
```

Add `mcp` to `requirements.txt`:
```
certifi
fastapi
uvicorn
pydantic
requests
mcp