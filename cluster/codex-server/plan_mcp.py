"""
plan_mcp.py — MCP stdio server wrapping the plan-server REST API.
Standalone version for codex-server: reads tokens from environment directly.

Tools:
  plan_current     — get the current task
  plan_list        — summary of all tasks
  plan_complete    — mark current task done
  plan_block       — mark current task blocked
  plan_unblock     — unblock a blocked task
  plan_create      — create a new plan
  plan_update_task — update a field on a specific task
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

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("plan_mcp")

PLAN_SERVER_URL = os.environ.get("PLAN_SERVER_URL", "https://plan-server:8443")
PLAN_API_TOKEN = os.environ.get("PLAN_API_TOKEN", "")
HEADERS = {"Authorization": f"Bearer {PLAN_API_TOKEN}"}
VERIFY = "/app/certs/ca.crt"

server = Server("planner")


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="plan_current",
            description="Get the current task from the active plan. Call this before starting work.",
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="plan_list",
            description="Get a summary of all tasks in the active plan (id, name, status only).",
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="plan_complete",
            description="Mark the current task as completed. Automatically advances to the next task.",
            inputSchema={
                "type": "object",
                "properties": {
                    "task_id": {"type": "string", "description": "ID of the current task (must match)"},
                },
                "required": ["task_id"],
            },
        ),
        types.Tool(
            name="plan_block",
            description="Mark the current task as blocked. Does NOT advance — human intervention needed.",
            inputSchema={
                "type": "object",
                "properties": {
                    "task_id": {"type": "string", "description": "ID of the current task (must match)"},
                    "reason": {"type": "string", "description": "Why the task is blocked"},
                    "context": {"type": "string", "description": "Summary of work already done — used to resume if unblocked"},
                },
                "required": ["task_id", "reason"],
            },
        ),
        types.Tool(
            name="plan_unblock",
            description="Unblock a blocked task and resume execution. Returns the task with its block reason and resume context.",
            inputSchema={
                "type": "object",
                "properties": {
                    "task_id": {"type": "string", "description": "ID of the blocked task to unblock"},
                },
                "required": ["task_id"],
            },
        ),
        types.Tool(
            name="plan_create",
            description="Create a new plan with a goal and list of tasks.",
            inputSchema={
                "type": "object",
                "properties": {
                    "goal": {"type": "string", "description": "What this plan aims to achieve"},
                    "tasks": {
                        "type": "array",
                        "description": "List of tasks (2-10)",
                        "items": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string", "description": "Short task name"},
                                "files": {"type": "array", "items": {"type": "string"}, "description": "Files this task will touch"},
                                "action": {"type": "string", "description": "What to do"},
                                "verify": {"type": "string", "description": "How to verify the work"},
                                "done": {"type": "string", "description": "Unambiguous completion condition"},
                            },
                            "required": ["name", "files", "action", "verify", "done"],
                        },
                    },
                },
                "required": ["goal", "tasks"],
            },
        ),
        types.Tool(
            name="plan_update_task",
            description="Update a field on a specific task (name, files, action, verify, or done).",
            inputSchema={
                "type": "object",
                "properties": {
                    "task_id": {"type": "string", "description": "Task ID to update"},
                    "field": {
                        "type": "string",
                        "description": "Field to update",
                        "enum": ["name", "files", "action", "verify", "done"],
                    },
                    "value": {"type": "string", "description": "New value (for files, use JSON array string)"},
                },
                "required": ["task_id", "field", "value"],
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
    if name == "plan_current":
        response = requests.get(
            f"{PLAN_SERVER_URL}/current",
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            return json.dumps(response.json(), indent=2)
        elif response.status_code == 404:
            return json.dumps({"message": "No active plan found"})
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "plan_list":
        response = requests.get(
            f"{PLAN_SERVER_URL}/list",
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            return json.dumps(response.json(), indent=2)
        elif response.status_code == 404:
            return json.dumps({"message": "No active plan found"})
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "plan_complete":
        response = requests.post(
            f"{PLAN_SERVER_URL}/complete",
            json={"task_id": arguments["task_id"]},
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            return json.dumps(response.json(), indent=2)
        elif response.status_code == 400:
            raise ValueError(response.json().get("detail", "Bad request"))
        elif response.status_code == 404:
            raise FileNotFoundError("No active plan found")
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "plan_block":
        body = {"task_id": arguments["task_id"], "reason": arguments["reason"]}
        if "context" in arguments:
            body["context"] = arguments["context"]
        response = requests.post(
            f"{PLAN_SERVER_URL}/block",
            json=body,
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            return json.dumps(response.json(), indent=2)
        elif response.status_code == 400:
            raise ValueError(response.json().get("detail", "Bad request"))
        elif response.status_code == 404:
            raise FileNotFoundError("No active plan found")
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "plan_unblock":
        response = requests.post(
            f"{PLAN_SERVER_URL}/unblock",
            json={"task_id": arguments["task_id"]},
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            return json.dumps(response.json(), indent=2)
        elif response.status_code == 400:
            raise ValueError(response.json().get("detail", "Bad request"))
        elif response.status_code == 404:
            raise FileNotFoundError("No active plan found")
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "plan_create":
        response = requests.post(
            f"{PLAN_SERVER_URL}/plan",
            json={"goal": arguments["goal"], "tasks": arguments["tasks"]},
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 201:
            return json.dumps(response.json(), indent=2)
        elif response.status_code == 400:
            raise ValueError(response.json().get("detail", "Bad request"))
        else:
            raise RuntimeError(f"HTTP {response.status_code}: {response.text}")

    elif name == "plan_update_task":
        response = requests.patch(
            f"{PLAN_SERVER_URL}/task",
            json={
                "task_id": arguments["task_id"],
                "field": arguments["field"],
                "value": arguments["value"],
            },
            headers=HEADERS,
            verify=VERIFY,
            timeout=10,
        )
        if response.status_code == 200:
            return json.dumps(response.json(), indent=2)
        elif response.status_code in (400, 404):
            raise ValueError(response.json().get("detail", "Bad request"))
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
