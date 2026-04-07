"""
docs_mcp.py — MCP stdio server for read-only docs access.
Standalone version for codex-server.

Read-only access to project documentation (CONTEXT.md, PLAN.md, etc.)
mounted at /docs. The agent can read docs for guidance but cannot modify them.

Security:
- All operations are read-only
- Path restricted to DOCS_DIR (structural, via os.path.realpath check)
- Must NOT call verify_isolation.py (child process issue)
"""

import asyncio
import os
import sys
from typing import Any

import mcp.server.stdio
import mcp.types as types
from mcp.server.lowlevel import Server

DOCS_DIR = os.environ.get("DOCS_DIR", "/docs")

if not os.path.isdir(DOCS_DIR):
    print(f"Warning: DOCS_DIR={DOCS_DIR} does not exist", file=sys.stderr)


def _safe_path(relative_path: str) -> str | None:
    """Resolve a path and verify it's inside DOCS_DIR.

    Returns the resolved absolute path, or None if it escapes.
    """
    resolved = os.path.realpath(os.path.join(DOCS_DIR, relative_path))
    if not resolved.startswith(os.path.realpath(DOCS_DIR) + os.sep):
        return None
    return resolved


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


def list_docs() -> types.CallToolResult:
    """List all files in the docs directory."""
    try:
        if not os.path.isdir(DOCS_DIR):
            return _err(f"Docs directory not found: {DOCS_DIR}")
        files = []
        for root, dirs, filenames in os.walk(DOCS_DIR):
            for f in filenames:
                full = os.path.join(root, f)
                rel = os.path.relpath(full, DOCS_DIR)
                files.append(rel)
        if not files:
            return _ok("No files in docs directory.")
        return _ok("\n".join(sorted(files)))
    except Exception as e:
        return _err(f"Error listing docs: {e}")


def read_doc(path: str) -> types.CallToolResult:
    """Read a file from the docs directory.

    Args:
        path: File path relative to docs root (e.g. "CONTEXT.md").
    """
    if not path:
        return _err("No path provided")
    safe = _safe_path(path)
    if safe is None:
        return _err(f"Path escapes docs directory: {path}")
    if not os.path.isfile(safe):
        return _err(f"File not found: {path}")
    try:
        with open(safe, "r") as f:
            content = f.read()
        return _ok(content)
    except Exception as e:
        return _err(f"Error reading {path}: {e}")


server = Server("docs-mcp")

TOOLS = [
    types.Tool(
        name="list_docs",
        description="List all files in the project documentation directory.",
        inputSchema={"type": "object", "properties": {}},
    ),
    types.Tool(
        name="read_doc",
        description="Read a documentation file. Path is relative to the docs root (e.g. 'CONTEXT.md', 'PLAN.md').",
        inputSchema={
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "File path relative to docs root.",
                },
            },
            "required": ["path"],
        },
    ),
]


@server.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    return TOOLS


@server.call_tool()
async def handle_call_tool(name: str, arguments: dict[str, Any]) -> types.CallToolResult:
    match name:
        case "list_docs":
            return list_docs()
        case "read_doc":
            return read_doc(path=arguments.get("path", ""))
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
