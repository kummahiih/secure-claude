#!/bin/bash
set -e

# 1. Force the context to the directory where this script is located
cd "$(dirname "$0")"

# 3. Docker Execution
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

echo "[$(date +'%H:%M:%S')] Tearing down old stack..."
docker-compose down --remove-orphans

echo "[$(date +'%H:%M:%S')] Building and starting containers..."
# --build: Rebuilds the custom non-root Caddy and Proxy images
# --force-recreate: Ensures fresh containers even if config hasn't changed
# -d: Run in detached mode
docker-compose up -d --build --force-recreate

echo "[$(date +'%H:%M:%S')] Stack is active."