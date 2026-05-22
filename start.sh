#!/usr/bin/env bash
set -euo pipefail

NAME="${CONTAINER_NAME:-mem0-server}"
PORT="${PORT:-8765}"
DATA_DIR="${DATA_DIR:-$HOME/.local/share/mem0}"
OLLAMA_MODELS="$DATA_DIR/ollama"
FAISS_DATA="$DATA_DIR/data"
ENV_FILE="${ENV_FILE:-$DATA_DIR/.env}"

# Create .env from template if missing
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found. Copy openmemory/api/.env.template and fill in values."
    exit 1
fi

if podman container exists "$NAME" 2>/dev/null; then
    if podman ps --filter "name=$NAME" --format '{{.Names}}' | grep -q "$NAME"; then
        echo "mem0 server already running ($NAME)"
        exit 0
    fi
    podman rm "$NAME" >/dev/null
fi

podman run -d \
    --name "$NAME" \
    -p "127.0.0.1:$PORT:8765" \
    -v "$OLLAMA_MODELS:/root/.ollama/models" \
    -v "$FAISS_DATA:/data" \
    -v "$ENV_FILE:/usr/src/openmemory/.env:ro" \
    localhost/mem0:latest

echo "mem0 server starting on http://127.0.0.1:$PORT"
echo "  Ollama models: $OLLAMA_MODELS"
echo "  FAISS data:    $FAISS_DATA"
