"""
log_mcp.py — MCP stdio server wrapping the log-server REST API.
Standalone version for codex-server: reads tokens from environment directly.

Tools:
  list_sessions        — list recent sessions
  get_session_summary  — summary stats for a session
  query_logs           — query log events by type/time
  get_token_breakdown  — per-call token counts for a session
  get_file_dedup_report — duplicate file reads with wasted token estimates
"""

import asyncio
import json
import logging
import os

import requests
from mcp.server import Server
from mcp import types
from mcp.types import CallToolResult, TextContent
from mcp.server.stdio import stdio_server

logger = logging.getLogger(__name__)

LOG_SERVER_URL = os.environ.get("LOG_SERVER_URL", "https://log-server:8443")
LOG_API_TOKEN = os.environ.get("LOG_API_TOKEN", "")

HEADERS = {"Authorization": f"Bearer {LOG_API_TOKEN}"}
VERIFY = "/app/certs/ca.crt"

server = Server("log")


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="list_sessions",
            description="List recent sessions with timestamps and summary stats.",
            inputSchema={
                "type": "object",
                "properties": {
                    "limit": {"type": "integer", "description": "Max sessions to return"},
                    "since": {"type": "string", "description": "ISO timestamp lower bound"},
                },
            },
        ),
        types.Tool(
            name="get_session_summary",
            description="Get summary stats for a session: LLM calls, tokens, tool calls, task count, duration.",
            inputSchema={
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Session ID"},
                },
                "required": ["session_id"],
            },
        ),
        types.Tool(
            name="query_logs",
            description="Query structured log entries for a session, filtered by event type and time range.",
            inputSchema={
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Session ID"},
                    "event_type": {
                        "type": "string",
                        "description": "Event type filter: llm_call, tool_call, file_read, test_run",
                        "enum": ["llm_call", "tool_call", "file_read", "test_run"],
                    },
                    "time_range": {
                        "type": "object",
                        "description": "Optional time range with 'from' and 'to' ISO timestamps",
                        "properties": {
                            "from": {"type": "string"},
                            "to": {"type": "string"},
                        },
                    },
                },
                "required": ["session_id"],
            },
        ),
        types.Tool(
            name="get_token_breakdown",
            description="Get per-call token counts (input, output, cache read/write, model) for a session.",
            inputSchema={
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Session ID"},
                },
                "required": ["session_id"],
            },
        ),
        types.Tool(
            name="get_file_dedup_report",
            description="Show duplicate file reads for a session, grouped by sha256, with estimated wasted tokens.",
            inputSchema={
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Session ID"},
                },
                "required": ["session_id"],
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
    if name == "list_sessions":
        params = {}
        if "limit" in arguments:
            params["limit"] = arguments["limit"]
        if "since" in arguments:
            params["since"] = arguments["since"]
        response = requests.get(
            f"{LOG_SERVER_URL}/sessions",
            params=params,
            headers=HEADERS,
            verify=VERIFY,
            timeout=30,
        )
        if response.status_code == 200:
            return json.dumps(response.json(), indent=2)
        elif response.status_code == 401:
            raise PermissionError("Unauthorized. Token mismatch.")
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "get_session_summary":
        session_id = arguments["session_id"]
        response = requests.get(
            f"{LOG_SERVER_URL}/sessions/{session_id}/summary",
            headers=HEADERS,
            verify=VERIFY,
            timeout=30,
        )
        if response.status_code == 200:
            return json.dumps(response.json(), indent=2)
        elif response.status_code == 401:
            raise PermissionError("Unauthorized. Token mismatch.")
        elif response.status_code == 404:
            raise FileNotFoundError(f"Session {session_id!r} not found")
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "query_logs":
        session_id = arguments["session_id"]
        body = {}
        if "event_type" in arguments:
            body["event_type"] = arguments["event_type"]
        if "time_range" in arguments:
            body["time_range"] = arguments["time_range"]
        response = requests.post(
            f"{LOG_SERVER_URL}/sessions/{session_id}/query",
            json=body,
            headers=HEADERS,
            verify=VERIFY,
            timeout=30,
        )
        if response.status_code == 200:
            return json.dumps(response.json(), indent=2)
        elif response.status_code == 401:
            raise PermissionError("Unauthorized. Token mismatch.")
        elif response.status_code == 404:
            raise FileNotFoundError(f"Session {session_id!r} not found")
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "get_token_breakdown":
        session_id = arguments["session_id"]
        response = requests.get(
            f"{LOG_SERVER_URL}/sessions/{session_id}/tokens",
            headers=HEADERS,
            verify=VERIFY,
            timeout=30,
        )
        if response.status_code == 200:
            return json.dumps(response.json(), indent=2)
        elif response.status_code == 401:
            raise PermissionError("Unauthorized. Token mismatch.")
        elif response.status_code == 404:
            raise FileNotFoundError(f"Session {session_id!r} not found")
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "get_file_dedup_report":
        session_id = arguments["session_id"]
        response = requests.get(
            f"{LOG_SERVER_URL}/sessions/{session_id}/file-dedup",
            headers=HEADERS,
            verify=VERIFY,
            timeout=30,
        )
        if response.status_code == 401:
            raise PermissionError("Unauthorized. Token mismatch.")
        elif response.status_code == 404:
            raise FileNotFoundError(f"Session {session_id!r} not found")
        elif response.status_code != 200:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")
        data = response.json()
        if not data:
            return f"No duplicate file reads detected for session {session_id}."
        lines = [f"{'path':<60} {'sha256':>12}  {'reads':>5}  {'wasted_tokens':>13}"]
        lines.append("-" * 97)
        for row in data:
            path = row.get("path", "")
            sha = row.get("sha256", "")[:12]
            reads = row.get("read_count", 0)
            wasted = row.get("est_wasted_tokens", 0)
            lines.append(f"{path:<60} {sha:>12}  {reads:>5}  {wasted:>13}")
        return "\n".join(lines)

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
