import os
import re
import json
import logging
import secrets
import subprocess
import threading
import time
from datetime import datetime, timezone
import requests
from fastapi import FastAPI, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

CODEX_API_TOKEN = os.getenv("CODEX_API_TOKEN")
DYNAMIC_AGENT_KEY = os.getenv("DYNAMIC_AGENT_KEY") or os.getenv("OPENAI_API_KEY")
MCP_API_TOKEN = os.getenv("MCP_API_TOKEN")
PLAN_API_TOKEN = os.getenv("PLAN_API_TOKEN")
TESTER_API_TOKEN = os.getenv("TESTER_API_TOKEN")
GIT_API_TOKEN = os.getenv("GIT_API_TOKEN")
LOG_API_TOKEN = os.getenv("LOG_API_TOKEN")
LOG_SERVER_URL = os.getenv("LOG_SERVER_URL", "https://log-server:8443")
PLAN_SERVER_URL = os.getenv("PLAN_SERVER_URL", "https://plan-server:8443")

COMMANDS_DIR = "/home/appuser/.codex/commands"

# ---------------------------------------------------------------------------
# Model allowlist
# ---------------------------------------------------------------------------

ALLOWED_MODELS: frozenset[str] = frozenset({
    "gpt-4o",
    "gpt-5.3-codex",
    "o3",
})


def _validate_model(model: str) -> str:
    if model not in ALLOWED_MODELS:
        raise HTTPException(
            status_code=400,
            detail=f"Model '{model}' is not allowed. Allowed: {sorted(ALLOWED_MODELS)}",
        )
    return model


# ---------------------------------------------------------------------------
# Secret redaction
# ---------------------------------------------------------------------------

_SECRET_TOKENS = [
    t for t in [
        CODEX_API_TOKEN, DYNAMIC_AGENT_KEY, MCP_API_TOKEN,
        PLAN_API_TOKEN, TESTER_API_TOKEN, GIT_API_TOKEN, LOG_API_TOKEN,
    ]
    if t
]
_SECRET_RE = (
    re.compile("|".join(re.escape(t) for t in _SECRET_TOKENS))
    if _SECRET_TOKENS else None
)


def _redact_secrets(text: str) -> str:
    if _SECRET_RE is None or not isinstance(text, str):
        return text
    return _SECRET_RE.sub("[REDACTED]", text)


# ---------------------------------------------------------------------------
# Log emission
# ---------------------------------------------------------------------------

_LOG_CA_BUNDLE = "/app/certs/ca.crt"


def _emit_log_event(event: dict) -> None:
    if not LOG_SERVER_URL or not LOG_API_TOKEN:
        return
    try:
        requests.post(
            f"{LOG_SERVER_URL}/ingest",
            json=event,
            headers={"Authorization": f"Bearer {LOG_API_TOKEN}"},
            verify=_LOG_CA_BUNDLE,
            timeout=5,
        )
    except Exception as exc:
        logger.warning(f"Log emission failed (non-critical): {exc}")


def _log_llm_turns(
    session_id: str, model: str, turn_usages: list[dict], duration_ms: int
) -> None:
    n = len(turn_usages)
    for i, usage in enumerate(turn_usages):
        event = {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "session_id": session_id,
            "event_type": "llm_call",
            "model": model,
            "input_tokens": usage.get("input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
            "cache_read_tokens": usage.get("cache_read_tokens", 0),
            "cache_creation_tokens": usage.get("cache_creation_tokens", 0),
            "turn_number": i + 1,
            "duration_ms": duration_ms if i == n - 1 else 0,
        }
        threading.Thread(target=_emit_log_event, args=(event,), daemon=True).start()


# ---------------------------------------------------------------------------
# Slash command expansion
# ---------------------------------------------------------------------------

PATH_BLACKLIST = [
    "\0", "..", "~", ";", "|", "&", "`", "$", "!", "'", '"',
    "\\", "\n", "\r", "\t", ">", "<", "*", "?", "[", "{", "#",
]


def _expand_slash_command(query: str) -> str:
    if not query.startswith("/"):
        return query
    parts = query[1:].split()
    if not parts:
        return query
    name = os.path.basename(parts[0])
    if not name or any(bad in name for bad in PATH_BLACKLIST):
        logger.warning(f"Rejected potentially malicious slash command: {query!r}")
        return query
    cmd_path = os.path.join(COMMANDS_DIR, f"{name}.md")
    if os.path.isfile(cmd_path):
        logger.info(f"Expanding slash command /{name} from {cmd_path}")
        with open(cmd_path, encoding="utf-8") as fh:
            return fh.read()
    logger.warning(f"Unknown slash command: /{name}")
    return query


# ---------------------------------------------------------------------------
# Upstream error detection
# ---------------------------------------------------------------------------


def _check_upstream_errors(text: str) -> None:
    if not text:
        return
    if "OAuth token has expired" in text or "authentication_error" in text:
        raise HTTPException(
            status_code=502,
            detail="Upstream API authentication failure — please refresh your OPENAI_API_KEY.",
        )
    if "rate_limit_error" in text or "429" in text or "Too Many Requests" in text:
        raise HTTPException(
            status_code=429,
            detail="Upstream API rate limit exceeded. Please try again later.",
        )


# ---------------------------------------------------------------------------
# Subprocess helpers
# ---------------------------------------------------------------------------

_PROMPT_DIR = os.environ.get("PROMPT_SYSTEM_DIR", "/app/prompts")


def _load_prompt(name: str) -> str:
    path = os.path.join(_PROMPT_DIR, name)
    if not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8") as fh:
        return fh.read().strip()


SYSTEM_PROMPT = _load_prompt("ask.md")
PLAN_SYSTEM_PROMPT = _load_prompt("plan.md")
ADHOC_SYSTEM_PROMPT = (
    _load_prompt("ask-adhoc.md")
    or "You are a helpful coding assistant. Answer the user's question directly and concisely."
)


def _parse_codex_output(stdout: str) -> tuple[list[dict], str]:
    """Parse Codex CLI output. Returns (turn_usages, response_text).

    Codex CLI outputs plain text (not stream-json), so we treat the entire
    stdout as the response and return an empty usage list.
    """
    return [], stdout.strip()


def _has_active_plan_task() -> bool:
    if not PLAN_SERVER_URL or not PLAN_API_TOKEN:
        return True
    try:
        resp = requests.get(
            f"{PLAN_SERVER_URL}/current",
            headers={"Authorization": f"Bearer {PLAN_API_TOKEN}"},
            verify=_LOG_CA_BUNDLE,
            timeout=5,
        )
        if resp.status_code == 404:
            return False
        if resp.status_code == 200:
            return bool(resp.json().get("task"))
        return True
    except Exception:
        return False


def _run_subagent(query: str, model: str, system_prompt: str) -> tuple[object, int]:
    t0 = time.monotonic()
    env = {
        **os.environ,
        "HOME": "/home/appuser",
        "OPENAI_API_KEY": DYNAMIC_AGENT_KEY or "",
    }
    cmd = ["codex", "--quiet"]
    if model:
        cmd += ["--model", model]
    if system_prompt:
        cmd += ["--instructions", system_prompt]
    cmd += [query]

    result = subprocess.run(
        cmd,
        cwd="/home/appuser/sandbox",
        capture_output=True,
        text=True,
        timeout=600,
        env=env,
    )
    duration_ms = int((time.monotonic() - t0) * 1000)
    logger.debug(f"stdout: {_redact_secrets(result.stdout)!r}")
    logger.debug(f"stderr: {_redact_secrets(result.stderr)!r}")
    logger.debug(f"returncode: {result.returncode}")
    logger.info(
        f"Subagent completed: returncode={result.returncode} "
        f"stdout_bytes={len(result.stdout)} stderr_bytes={len(result.stderr)}"
    )
    return result, duration_ms


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(title="Secure Codex Server")
security = HTTPBearer()


def verify_token(
    credentials: HTTPAuthorizationCredentials = Depends(security),
) -> str:
    if not CODEX_API_TOKEN:
        logger.error("CODEX_API_TOKEN is not configured on the server.")
        raise HTTPException(status_code=500, detail="Server configuration error.")
    if not secrets.compare_digest(credentials.credentials, CODEX_API_TOKEN):
        logger.warning("Failed authentication attempt.")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API Token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return credentials.credentials


class QueryRequest(BaseModel):
    query: str = Field(max_length=100_000)
    model: str = Field(max_length=200)


@app.get("/health")
async def health_check():
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# /ask endpoint
# ---------------------------------------------------------------------------

_DONE_MARKER = "DONE"
_MAX_TASK_ITERATIONS = 50


@app.post("/ask")
async def ask_agent(request: QueryRequest, token: str = Depends(verify_token)):
    logger.info(f"Received authenticated query for model: {request.model}")
    _validate_model(request.model)
    query = _expand_slash_command(request.query)
    task_responses: list[str] = []

    try:
        if not _has_active_plan_task():
            logger.info("No active plan task — running ad-hoc single invocation")
            session_id = secrets.token_hex(8)
            result, duration_ms = _run_subagent(query, request.model, ADHOC_SYSTEM_PROMPT)

            if result.returncode != 0:
                logger.error(f"Subagent error: {_redact_secrets(result.stderr)}")
                _check_upstream_errors(result.stderr)
                return {"error": result.stderr}

            turn_usages, response_text = _parse_codex_output(result.stdout)
            _log_llm_turns(session_id, request.model, turn_usages, duration_ms)
            return {"response": response_text}

        for iteration in range(_MAX_TASK_ITERATIONS):
            logger.info(f"Spawning subagent iteration {iteration + 1}/{_MAX_TASK_ITERATIONS}")
            session_id = secrets.token_hex(8)

            result, duration_ms = _run_subagent(query, request.model, SYSTEM_PROMPT)

            if result.returncode != 0:
                logger.error(f"Subagent error: {_redact_secrets(result.stderr)}")
                _check_upstream_errors(result.stderr)
                return {"error": result.stderr, "responses": task_responses}

            turn_usages, response_text = _parse_codex_output(result.stdout)
            _log_llm_turns(session_id, request.model, turn_usages, duration_ms)
            task_responses.append(response_text)

            if response_text.strip() == _DONE_MARKER:
                logger.info("Subagent returned DONE — no more tasks.")
                break

            if not _has_active_plan_task():
                logger.info("No remaining plan tasks — stopping loop")
                break

        combined = "\n\n---\n\n".join(
            r for r in task_responses if r.strip() != _DONE_MARKER
        )
        return {"response": combined or _DONE_MARKER}

    except subprocess.TimeoutExpired:
        logger.error("Subagent timed out.")
        return {"error": "Agent timed out.", "responses": task_responses}
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Agent execution failed: {e}")
        return {"error": str(e)}


# ---------------------------------------------------------------------------
# /plan endpoint
# ---------------------------------------------------------------------------


@app.post("/plan")
async def plan_agent(request: QueryRequest, token: str = Depends(verify_token)):
    logger.info(f"Received planning query for model: {request.model}")
    _validate_model(request.model)
    query = _expand_slash_command(request.query)
    session_id = secrets.token_hex(8)

    try:
        result, duration_ms = _run_subagent(query, request.model, PLAN_SYSTEM_PROMPT)

        if result.returncode != 0:
            logger.error(f"Subagent error: {_redact_secrets(result.stderr)}")
            _check_upstream_errors(result.stderr)
            return {"error": result.stderr}

        turn_usages, response_text = _parse_codex_output(result.stdout)
        _log_llm_turns(session_id, request.model, turn_usages, duration_ms)
        return {"response": response_text}

    except subprocess.TimeoutExpired:
        logger.error("Codex timed out.")
        return {"error": "Agent timed out."}
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Agent execution failed: {e}")
        return {"error": str(e)}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        ssl_keyfile="/app/certs/agent.key",
        ssl_certfile="/app/certs/agent.crt",
    )
