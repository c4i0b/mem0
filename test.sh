#!/usr/bin/env bash
set -euo pipefail

API_URL="${API_URL:-http://localhost:8888}"

echo "=== mem0 API Test ==="
echo ""

echo "1) Health check..."
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$API_URL/docs")
echo "   API status: $STATUS"

echo ""
echo "2) Adding a memory..."
RESULT=$(curl -s -X POST "$API_URL/memories" \
    -H "Content-Type: application/json" \
    -d '{
        "messages": [
            {"role": "user", "content": "I love sci-fi movies and my favorite is Blade Runner."},
            {"role": "assistant", "content": "Great choice! Blade Runner is a classic sci-fi film."}
        ],
        "user_id": "test-user"
    }')
echo "   $RESULT" | python3 -m json.tool 2>/dev/null || echo "   $RESULT"

echo ""
echo "3) Searching memories..."
RESULT=$(curl -s -X POST "$API_URL/search" \
    -H "Content-Type: application/json" \
    -d '{
        "query": "favorite movies",
        "filters": {"user_id": "test-user"}
    }')
echo "   $RESULT" | python3 -m json.tool 2>/dev/null || echo "   $RESULT"

echo ""
echo "4) Listing all memories..."
RESULT=$(curl -s "$API_URL/memories?user_id=test-user")
echo "   $RESULT" | python3 -m json.tool 2>/dev/null || echo "   $RESULT"

echo ""
echo "=== Test complete ==="
