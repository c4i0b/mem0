#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/server"

if [ ! -f .env ]; then
  cp .env.example .env 2>/dev/null || true
fi

source .env 2>/dev/null || true
MODEL="${EMBED_MODEL:-nomic-embed-text}"

echo "Starting mem0 stack with Podman..."
podman-compose up -d --build

echo ""
echo "Waiting for Ollama..."
until podman exec mem0-dev_ollama_1 ollama list >/dev/null 2>&1; do sleep 2; done

echo "Ensuring embed model is pulled ($MODEL)..."
if ! podman exec mem0-dev_ollama_1 ollama list | grep -q "$MODEL"; then
  echo "  Pulling $MODEL (this may take a moment on first run)..."
  podman exec mem0-dev_ollama_1 ollama pull "$MODEL"
fi
echo "  Model $MODEL ready."

echo ""
echo "Waiting for MCP adapter..."
until curl -fsS http://localhost:8890/health >/dev/null 2>&1; do sleep 2; done

echo ""
echo "Stack is ready!"
echo "  MCP:        http://localhost:8890/mcp"
echo "  Health:     http://localhost:8890/health"
echo "  Embed:      $MODEL"
