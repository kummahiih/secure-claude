import os
import json
import logging
import secrets
import subprocess
from fastapi import FastAPI, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
import setuplogging
from runenv import CLAUDE_API_TOKEN, ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, MCP_API_TOKEN

logger = logging.getLogger(__name__)

app = FastAPI(title="Secure Claude Code Server")
security = HTTPBearer()


def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
    """Validates the Bearer token in constant time to prevent timing attacks."""
    if not CLAUDE_API_TOKEN:
        logger.error("CLAUDE_API_TOKEN is not configured on the server.")
        raise HTTPException(status_code=500, detail="Server configuration error.")

    if not secrets.compare_digest(credentials.credentials, CLAUDE_API_TOKEN):
        logger.warning("Failed authentication attempt on /ask endpoint.")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API Token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return credentials.credentials


class QueryRequest(BaseModel):
    query: str
    model: str  # kept for API compatibility, passed as --model to claude



@app.get("/health")
async def health_check():
    return {"status": "ok"}


@app.post("/ask")
async def ask_agent(request: QueryRequest, token: str = Depends(verify_token)):
    """External endpoint routed through Caddy, secured with Bearer token."""
    logger.info(f"Received authenticated query: {request.query} for model: {request.model}")
    try:
        result = subprocess.run(
            [
                "claude", "--print",
                "--dangerously-skip-permissions",
                "--output-format", "json",
                "--model", request.model,
                "--system-prompt", "You have access to a workspace through MCP fileserver tools. Always use MCP tools to read, write, list and delete files. Never access the local filesystem directly.",
                request.query],
            cwd="/home/appuser/sandbox",
            capture_output=True,
            text=True,
            timeout=120,
            env={
                **os.environ,
                "CLAUDE_CONFIG_DIR": "/home/appuser",
                "HOME": "/home/appuser",
            }
        )

        logger.info(f"stdout: {result.stdout!r}")
        logger.info(f"stderr: {result.stderr!r}")
        logger.info(f"returncode: {result.returncode}")
        logger.info(f"result: {result!r}")

        if result.returncode != 0:
            logger.error(f"Claude Code exited with error: {result.stderr}")
            return {"error": result.stderr}

        try:
            parsed = json.loads(result.stdout)
            if parsed.get("is_error"):
                return {"error": parsed.get("result", "Unknown error")}
            return {"response": parsed.get("result", "")}
        except json.JSONDecodeError:
            # fallback in case output is plain text
            return {"response": result.stdout.strip()}

    except subprocess.TimeoutExpired:
        logger.error("Claude Code timed out.")
        return {"error": "Agent timed out."}
    except Exception as e:
        logger.error(f"Agent execution failed: {e}")
        return {"error": str(e)}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        ssl_keyfile="/app/certs/agent.key",
        ssl_certfile="/app/certs/agent.crt"
    )