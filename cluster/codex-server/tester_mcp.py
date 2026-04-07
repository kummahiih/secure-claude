"""
tester_mcp.py — MCP stdio server wrapping the tester-server REST API.
Standalone version for codex-server: reads tokens from environment directly.
"""

import asyncio
import json
import logging
import os
import threading

import requests
from mcp.server import Server
from mcp import types
from mcp.types import CallToolResult, TextContent
from mcp.server.stdio import stdio_server

logger = logging.getLogger(__name__)

TESTER_SERVER_URL = os.environ.get("TESTER_SERVER_URL", "https://tester-server:8443")
TESTER_API_TOKEN = os.environ.get("TESTER_API_TOKEN", "")
LOG_SERVER_URL = os.environ.get("LOG_SERVER_URL", "https://log-server:8443")
LOG_API_TOKEN = os.environ.get("LOG_API_TOKEN", "")

HEADERS = {"Authorization": f"Bearer {TESTER_API_TOKEN}"}
VERIFY = "/app/certs/ca.crt"

# --- 3-Strike Rule State ---
_consecutive_failures = 0


def _reset_strike_counter():
    """For testing purposes: resets the strike counter state."""
    global _consecutive_failures
    _consecutive_failures = 0


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


server = Server("tester")


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="run_tests",
            description="Starts a test run. Call get_test_results for the outcome.",
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="get_test_results",
            description=(
                'Returns the result of the most recent test run (blocks until complete). '
                'On pass: {"status":"pass","exit_code":0} only. '
                "On fail: last 50 lines of output. "
                "Fields: status (pass/fail/running/pending), exit_code, timestamp, output."
            ),
            inputSchema={"type": "object", "properties": {}},
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
    global _consecutive_failures

    if name == "run_tests":
        if _consecutive_failures >= 3:
            raise RuntimeError(
                "HARD STOP: You have failed 3 consecutive test runs. You MUST call `plan_block` immediately with a summary of the failures. Do not attempt to run tests again."
            )
        response = requests.post(
            f"{TESTER_SERVER_URL}/run",
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            return json.dumps(response.json())
        elif response.status_code == 401:
            raise PermissionError("Unauthorized. Token mismatch.")
        elif response.status_code == 409:
            raise RuntimeError("A test run is already in progress. Call get_test_results to wait for completion.")
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "get_test_results":
        response = requests.get(
            f"{TESTER_SERVER_URL}/results?wait=true",
            headers=HEADERS,
            verify=VERIFY,
            timeout=330,
        )
        if response.status_code == 200:
            data = response.json()
            status = data.get("status")

            if status == "fail":
                _consecutive_failures += 1
            elif status == "pass":
                _consecutive_failures = 0

            if status in ("pass", "fail"):
                event = {
                    "event_type": "test_run",
                    "exit_code": data.get("exit_code", 0),
                    "output_size_bytes": len(data.get("output", "")),
                }
                if "duration_ms" in data:
                    event["duration_ms"] = data["duration_ms"]
                threading.Thread(target=_emit_log_event, args=(event,), daemon=True).start()

            if status == "pass":
                data = {"status": "pass", "exit_code": 0}
            elif status == "fail":
                output = data.get("output", "")
                data["output"] = "\n".join(output.splitlines()[-50:])

            return json.dumps(data)
        elif response.status_code == 401:
            raise PermissionError("Unauthorized. Token mismatch.")
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
