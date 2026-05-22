#!/bin/bash
set -e

ollama serve &
OLLAMA_PID=$!

for i in $(seq 1 30); do
    if curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
        echo "entrypoint: ollama ready after ${i}s"
        break
    fi
    sleep 2
done

EMBEDDER_MODEL="${EMBEDDER_MODEL:-nomic-embed-text}"
echo "entrypoint: pulling ${EMBEDDER_MODEL}..."
ollama pull "${EMBEDDER_MODEL}"
echo "entrypoint: model ready"

exec uvicorn main:app --host 0.0.0.0 --port 8765
