#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/server"

if ! grep -q 'YOUR_GOOGLE_API_KEY_HERE' .env 2>/dev/null; then
    : # API key is set
else
    echo "ERROR: Edit server/.env and replace YOUR_GOOGLE_API_KEY_HERE with your Gemini API key."
    echo "       Get one at https://aistudio.google.com/app/apikey"
    exit 1
fi

echo "Starting mem0 stack with Podman..."
podman-compose up -d --build

echo ""
echo "Waiting for API to be ready..."
until curl -fsS http://localhost:8888/auth/setup-status >/dev/null 2>&1; do sleep 2; done

echo "Waiting for dashboard..."
until curl -fsS http://localhost:3000/api/health >/dev/null 2>&1; do sleep 2; done

echo ""
echo "Stack is ready!"
echo "  API:        http://localhost:8888"
echo "  Dashboard:  http://localhost:3000"
echo "  API Docs:   http://localhost:8888/docs"
