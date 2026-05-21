#!/usr/bin/env bash
set -euo pipefail

NAME="${CONTAINER_NAME:-mem0-server}"

if ! podman container exists "$NAME" 2>/dev/null; then
    echo "mem0 server not found ($NAME)"
    exit 0
fi

podman stop "$NAME" 2>/dev/null
podman rm "$NAME" >/dev/null
echo "mem0 server stopped ($NAME)"
