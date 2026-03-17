# secure-claude

Hardened containerized environment for running Claude Code as an autonomous AI agent.

## Architecture
See docs/CONTEXT.md for full architecture, security model, and implementation details.

## Key Commands
- `./run.sh` — generate certs/tokens, start cluster
- `./test.sh` — full test suite (unit + security + integration)
- `./plan.sh <model> "<goal>"` — create a plan (no code execution)
- `./query.sh <model> "<query>"` — send query / execute current task
- `./logs.sh` — tail container logs

## Project Structure
- `cluster/agent/` — agent submodule (code the agent modifies)
- `cluster/planner/` — planner submodule (plan state management)
- `plans/` — JSON plan files (committed)
- Root scripts — touch secrets/Docker, never mounted as /workspace

## Workflow
1. `plan.sh` creates a structured plan (2-5 tasks)
2. `query.sh "work on the current task"` executes one task at a time
3. Claude commits after each task, advances to the next automatically

## Planning
See docs/PLAN.md for the development roadmap.
