#!/bin/bash
set -e

# Run isolation checks before serving traffic
python /app/verify_isolation.py codex-server || exit 1

exec python /app/server.py
