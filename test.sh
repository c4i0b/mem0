#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0
report_pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC} $1"; }
report_fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC} $1"; }

COMPOSE_PROJECT="mem0-dev"
PG_CONTAINER="${COMPOSE_PROJECT}_postgres_1"
OLLAMA_HOST="${OLLAMA_HOST:-localhost:11434}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"

pg_exec() { podman exec "$PG_CONTAINER" psql -U postgres -d postgres -t -A "$@"; }
jget() { echo "$1" | node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8')); process.stdout.write(String($2))" 2>/dev/null; }

echo -e "\n${BOLD}${CYAN}=== mem0 Stack Smoke Test ===${NC}\n"

echo -e "${BOLD}T1  MCP adapter health${NC}"
HEALTH=$(curl -s http://localhost:8890/health)
if echo "$HEALTH" | grep -q '"status":"ok"'; then
  report_pass "$HEALTH"
else
  report_fail "not responding"
fi

echo -e "\n${BOLD}T2  Ollama embed API${NC}"
EMBED_RESULT=$(curl -s -X POST "http://$OLLAMA_HOST/api/embed" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$EMBED_MODEL\",\"input\":\"hello world\"}")
DIMS=$(jget "$EMBED_RESULT" "d.embeddings[0].length")
if [ -n "$DIMS" ] && [ "$DIMS" -gt 0 ]; then
  report_pass "model=$EMBED_MODEL dims=$DIMS"
else
  report_fail "could not embed: $(echo "$EMBED_RESULT" | head -c 200)"
fi

echo -e "\n${BOLD}T3  PostgreSQL + pgvector extension${NC}"
HAS_VECTOR=$(pg_exec -c "SELECT extname FROM pg_extension WHERE extname='vector';")
if [ "$HAS_VECTOR" = "vector" ]; then
  report_pass "pgvector extension loaded"
else
  report_fail "pgvector extension not found"
fi

echo -e "\n${BOLD}T4  Memories table exists${NC}"
HAS_TABLE=$(pg_exec -c "SELECT tablename FROM pg_tables WHERE tablename='memories';")
if [ "$HAS_TABLE" = "memories" ]; then
  report_pass "table memories exists"
else
  report_fail "table memories not found"
fi

echo -e "\n${BOLD}T5  Insert + vector search (round-trip)${NC}"
EMBED_VEC=$(curl -s -X POST "http://$OLLAMA_HOST/api/embed" \
  -H "Content-Type: application/json" \
  -d '{"model":"'"$EMBED_MODEL"'","input":"I love hiking in the mountains"}' | \
  node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8')); process.stdout.write(JSON.stringify(d.embeddings[0]))")

if [ -n "$EMBED_VEC" ]; then
  pg_exec -c "INSERT INTO memories (vector, payload) VALUES ('$EMBED_VEC'::vector, '{\"text\":\"I love hiking in the mountains\",\"user_id\":\"test\"}');" >/dev/null
  MATCH=$(pg_exec -c "SELECT payload->>'text' FROM memories WHERE payload->>'user_id'='test' ORDER BY vector <=> '$EMBED_VEC'::vector LIMIT 1;")
  pg_exec -c "DELETE FROM memories WHERE payload->>'user_id'='test';" >/dev/null
  if echo "$MATCH" | grep -qi "hiking"; then
    report_pass "insert -> cosine search -> match"
  else
    report_fail "search did not match: $MATCH"
  fi
else
  report_fail "could not generate embedding"
fi

echo -e "\n${BOLD}T6  Table row count${NC}"
COUNT=$(pg_exec -c "SELECT COUNT(*) FROM memories;")
report_pass "$COUNT rows in memories table"

echo -e "\n${BOLD}${CYAN}=== SUMMARY ===${NC}"
echo -e "  Total: ${BOLD}$TOTAL${NC}  |  ${GREEN}Pass: $PASS${NC}  |  ${RED}Fail: $FAIL${NC}"
echo ""
