#!/bin/bash
# caddy_test.sh

# We mount the local certs directory to the path the Caddyfile expects
# Note: Since run.sh --setup-only was called, ca.crt exists.
# We temporarily mount ca.crt as caddy.crt just for the 'validate' check 
# so Caddy sees a valid file exists.
docker run --rm \
  -v "$(pwd)/cluster/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$(pwd)/cluster/certs/ca.crt:/etc/caddy/certs/ca.crt:ro" \
  -v "$(pwd)/cluster/certs/ca.crt:/etc/caddy/certs/caddy.crt:ro" \
  -v "$(pwd)/cluster/certs/ca.key:/etc/caddy/certs/caddy.key:ro" \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile