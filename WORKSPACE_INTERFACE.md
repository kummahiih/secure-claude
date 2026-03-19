# Workspace Interface Specification

Any repository mounted as the active workspace in secure-claude must follow this structure.

## Required Structure

```
<repo-root>/
├── docs/
│   ├── CONTEXT.md          # Architecture, design decisions, implementation details
│   └── PLAN.md             # Development roadmap and task backlog
├── README.md               # Project overview, setup, usage
└── ...                     # Project source code
```

## Contract

| Item | Requirement |
| :--- | :--- |
| `README.md` | Project overview, local development setup, test instructions |
| `docs/CONTEXT.md` | Architecture the agent needs to understand before making changes |
| `docs/PLAN.md` | Current phase, tasks, acceptance criteria, risks |
| Test command | Documented in README — agent invokes this via test runner MCP |
| Language | One primary language per repo (Python or Go) for test image selection |

## How Mounting Works

In `docker-compose.yml`, the workspace bind mount points to the active sub-repo:

```yaml
# To work on the agent:
- ./agent:/workspace:ro       # claude-server
- ./agent:/workspace:rw       # mcp-server

# To work on the planner:
- ./planner:/workspace:ro     # claude-server
- ./planner:/workspace:rw     # mcp-server
```

The `docs/` folder inside the mounted repo is also mounted read-only into
claude-server at `/docs`, giving the agent access via the docs MCP tool set.

The parent repo's `docs/` folder is **not** mounted — all context the agent
needs must live inside the workspace repo's own `docs/`.
