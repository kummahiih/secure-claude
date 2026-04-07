"""
git_mcp.py — MCP stdio server wrapping the git-server REST API.
Standalone version for codex-server: reads tokens from environment directly.
"""

import asyncio
import os
import time
from typing import Any

import requests
import mcp.server.stdio
import mcp.types as types
from mcp.server.lowlevel import Server

GIT_SERVER_URL = os.environ.get("GIT_SERVER_URL", "https://git-server:8443")
GIT_API_TOKEN = os.environ.get("GIT_API_TOKEN", "")
LOG_SERVER_URL = os.environ.get("LOG_SERVER_URL", "https://log-server:8443")
LOG_API_TOKEN = os.environ.get("LOG_API_TOKEN", "")

HEADERS = {"Authorization": f"Bearer {GIT_API_TOKEN}"}
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
    except Exception:
        pass


def _ok(text: str) -> types.CallToolResult:
    return types.CallToolResult(
        content=[types.TextContent(type="text", text=text)],
        isError=False,
    )


def _err(text: str) -> types.CallToolResult:
    return types.CallToolResult(
        content=[types.TextContent(type="text", text=text)],
        isError=True,
    )


def git_status(submodule_path: str | None = None) -> types.CallToolResult:
    try:
        params: dict = {}
        if submodule_path:
            params["submodule_path"] = submodule_path
        t0 = time.time()
        resp = requests.get(
            f"{GIT_SERVER_URL}/status",
            params=params,
            headers=HEADERS,
            verify=VERIFY,
            timeout=30,
        )
        if resp.status_code == 200:
            event: dict = {"event_type": "git_op", "operation": "git_status", "duration_ms": int((time.time() - t0) * 1000)}
            if submodule_path:
                event["submodule_path"] = submodule_path
            _emit_log_event(event)
            return _ok(resp.json()["output"])
        elif resp.status_code == 401:
            return _err("Unauthorized: invalid or missing GIT_API_TOKEN")
        else:
            return _err(resp.json().get("error", f"HTTP {resp.status_code}"))
    except requests.exceptions.Timeout:
        return _err("git status timed out")
    except Exception as e:
        return _err(f"git status error: {e}")


def git_diff(staged: bool = False, submodule_path: str | None = None) -> types.CallToolResult:
    try:
        params: dict = {"staged": str(staged).lower()}
        if submodule_path:
            params["submodule_path"] = submodule_path
        t0 = time.time()
        resp = requests.get(
            f"{GIT_SERVER_URL}/diff",
            params=params,
            headers=HEADERS,
            verify=VERIFY,
            timeout=30,
        )
        if resp.status_code == 200:
            event: dict = {"event_type": "git_op", "operation": "git_diff", "duration_ms": int((time.time() - t0) * 1000)}
            if submodule_path:
                event["submodule_path"] = submodule_path
            _emit_log_event(event)
            return _ok(resp.json()["output"])
        elif resp.status_code == 401:
            return _err("Unauthorized: invalid or missing GIT_API_TOKEN")
        else:
            return _err(resp.json().get("error", f"HTTP {resp.status_code}"))
    except requests.exceptions.Timeout:
        return _err("git diff timed out")
    except Exception as e:
        return _err(f"git diff error: {e}")


def git_add(paths: list[str]) -> types.CallToolResult:
    if not paths:
        return _err("No paths provided to git add")
    try:
        t0 = time.time()
        resp = requests.post(
            f"{GIT_SERVER_URL}/add",
            json={"paths": paths},
            headers=HEADERS,
            verify=VERIFY,
            timeout=30,
        )
        if resp.status_code == 200:
            _emit_log_event({"event_type": "git_op", "operation": "git_add", "duration_ms": int((time.time() - t0) * 1000)})
            return _ok(resp.json()["output"])
        elif resp.status_code == 401:
            return _err("Unauthorized: invalid or missing GIT_API_TOKEN")
        else:
            return _err(resp.json().get("error", f"HTTP {resp.status_code}"))
    except requests.exceptions.Timeout:
        return _err("git add timed out")
    except Exception as e:
        return _err(f"git add error: {e}")


def git_commit(message: str, submodule_path: str | None = None) -> types.CallToolResult:
    if not message or not message.strip():
        return _err("Commit message must not be empty")
    try:
        body: dict = {"message": message.strip()}
        if submodule_path:
            body["submodule_path"] = submodule_path
        t0 = time.time()
        resp = requests.post(
            f"{GIT_SERVER_URL}/commit",
            json=body,
            headers=HEADERS,
            verify=VERIFY,
            timeout=30,
        )
        if resp.status_code == 200:
            event: dict = {"event_type": "git_op", "operation": "git_commit", "duration_ms": int((time.time() - t0) * 1000)}
            if submodule_path:
                event["submodule_path"] = submodule_path
            _emit_log_event(event)
            return _ok(resp.json()["output"])
        elif resp.status_code == 401:
            return _err("Unauthorized: invalid or missing GIT_API_TOKEN")
        else:
            return _err(resp.json().get("error", f"HTTP {resp.status_code}"))
    except requests.exceptions.Timeout:
        return _err("git commit timed out")
    except Exception as e:
        return _err(f"git commit error: {e}")


def git_log(max_count: int = 10, submodule_path: str | None = None) -> types.CallToolResult:
    max_count = min(max(1, max_count), 50)
    try:
        params: dict = {"max_count": str(max_count)}
        if submodule_path:
            params["submodule_path"] = submodule_path
        t0 = time.time()
        resp = requests.get(
            f"{GIT_SERVER_URL}/log",
            params=params,
            headers=HEADERS,
            verify=VERIFY,
            timeout=30,
        )
        if resp.status_code == 200:
            event: dict = {"event_type": "git_op", "operation": "git_log", "duration_ms": int((time.time() - t0) * 1000)}
            if submodule_path:
                event["submodule_path"] = submodule_path
            _emit_log_event(event)
            return _ok(resp.json()["output"])
        elif resp.status_code == 401:
            return _err("Unauthorized: invalid or missing GIT_API_TOKEN")
        else:
            return _err(resp.json().get("error", f"HTTP {resp.status_code}"))
    except requests.exceptions.Timeout:
        return _err("git log timed out")
    except Exception as e:
        return _err(f"git log error: {e}")


def git_reset_soft(count: int = 1, submodule_path: str | None = None) -> types.CallToolResult:
    count = min(max(1, count), 5)
    try:
        body: dict = {"count": count}
        if submodule_path:
            body["submodule_path"] = submodule_path
        t0 = time.time()
        resp = requests.post(
            f"{GIT_SERVER_URL}/reset",
            json=body,
            headers=HEADERS,
            verify=VERIFY,
            timeout=30,
        )
        if resp.status_code == 200:
            event: dict = {"event_type": "git_op", "operation": "git_reset_soft", "duration_ms": int((time.time() - t0) * 1000)}
            if submodule_path:
                event["submodule_path"] = submodule_path
            _emit_log_event(event)
            return _ok(resp.json()["output"])
        elif resp.status_code == 401:
            return _err("Unauthorized: invalid or missing GIT_API_TOKEN")
        else:
            return _err(resp.json().get("error", f"HTTP {resp.status_code}"))
    except requests.exceptions.Timeout:
        return _err("git reset timed out")
    except Exception as e:
        return _err(f"git reset error: {e}")


server = Server("git-mcp")

TOOLS = [
    types.Tool(
        name="git_status",
        description="Show working tree status (short format). Returns list of changed files with status codes.",
        inputSchema={
            "type": "object",
            "properties": {
                "submodule_path": {
                    "type": "string",
                    "description": "Submodule path (e.g. 'cluster/agent'). Omit for root repo.",
                },
            },
        },
    ),
    types.Tool(
        name="git_diff",
        description="Show file differences. By default shows unstaged changes. Set staged=true to see changes staged for commit.",
        inputSchema={
            "type": "object",
            "properties": {
                "staged": {
                    "type": "boolean",
                    "description": "If true, show staged (cached) changes instead of unstaged.",
                    "default": False,
                },
                "submodule_path": {
                    "type": "string",
                    "description": "Submodule path (e.g. 'cluster/agent'). Omit for root repo.",
                },
            },
        },
    ),
    types.Tool(
        name="git_add",
        description='Stage files for the next commit. Pass paths relative to workspace root. Use ["."] to stage all changes.',
        inputSchema={
            "type": "object",
            "properties": {
                "paths": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": 'File paths to stage, relative to workspace root. Use ["."] for all.',
                },
            },
            "required": ["paths"],
        },
    ),
    types.Tool(
        name="git_commit",
        description="Create a commit with staged changes. Requires a non-empty commit message.",
        inputSchema={
            "type": "object",
            "properties": {
                "message": {"type": "string", "description": "Commit message."},
                "submodule_path": {
                    "type": "string",
                    "description": "Submodule path (e.g. 'cluster/agent'). Omit for root repo.",
                },
            },
            "required": ["message"],
        },
    ),
    types.Tool(
        name="git_log",
        description="Show recent commits (oneline format). Returns up to max_count commits.",
        inputSchema={
            "type": "object",
            "properties": {
                "max_count": {
                    "type": "integer",
                    "description": "Number of commits to show (default 10, max 50).",
                    "default": 10,
                },
                "submodule_path": {
                    "type": "string",
                    "description": "Submodule path (e.g. 'cluster/agent'). Omit for root repo.",
                },
            },
        },
    ),
    types.Tool(
        name="git_reset_soft",
        description=(
            "Undo the last N commits, keeping all changes staged. "
            "Cannot reset past the baseline commit that existed at startup — "
            "only commits created during this session can be undone."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "count": {
                    "type": "integer",
                    "description": "Number of commits to undo (default 1, max 5).",
                    "default": 1,
                },
                "submodule_path": {
                    "type": "string",
                    "description": "Submodule path (e.g. 'cluster/agent'). Omit for root repo.",
                },
            },
        },
    ),
]


@server.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    return TOOLS


@server.call_tool()
async def handle_call_tool(name: str, arguments: dict[str, Any]) -> types.CallToolResult:
    match name:
        case "git_status":
            return git_status(submodule_path=arguments.get("submodule_path"))
        case "git_diff":
            return git_diff(staged=arguments.get("staged", False), submodule_path=arguments.get("submodule_path"))
        case "git_add":
            return git_add(paths=arguments.get("paths", []))
        case "git_commit":
            return git_commit(message=arguments.get("message", ""), submodule_path=arguments.get("submodule_path"))
        case "git_log":
            return git_log(max_count=arguments.get("max_count", 10), submodule_path=arguments.get("submodule_path"))
        case "git_reset_soft":
            return git_reset_soft(count=arguments.get("count", 1), submodule_path=arguments.get("submodule_path"))
        case _:
            return _err(f"Unknown tool: {name}")


async def main():
    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )


if __name__ == "__main__":
    asyncio.run(main())
