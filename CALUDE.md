# secure-claude

Hardened containerized environment for running Claude Code as an autonomous AI agent.

## Architecture
See docs/CONTEXT.md for full architecture, security model, and implementation details.

## Key Commands
- `./run.sh` — generate certs/tokens, start cluster
- `./test.sh` — full test suite (unit + security + integration)
- `./query.sh <model> "<query>"` — send query to agent
- `./logs.sh` — tail container logs

## Project Structure
- `cluster/` — all container source code
- Root scripts — touch secrets/Docker, never mounted as /workspace

## Current Goal
Self-developing agentic loop. See "Next Steps" in docs/CONTEXT.md.

## Planning
See docs/PLAN.md for the current 2-week development plan.