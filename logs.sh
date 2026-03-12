#!/bin/bash
set -e
(
    . .env && \
    . .cluster_tokens.env && \
    . .secrets.env && \
    cd cluster && \
    docker-compose logs --tail 200 proxy && \
    docker-compose logs --tail 200 caddy-sidecar && \
    docker-compose logs --tail 100 claude-server && \
    docker-compose logs --tail 100 mcp-server
)
    

