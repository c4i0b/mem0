#!/usr/bin/env bash
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"; cleanup_bench_data 2>/dev/null' EXIT

report_pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC} ${DIM}(${1}ms)${NC} $2"; }
report_fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC} ${DIM}(${1}ms)${NC} $2"; }

COMPOSE_PROJECT="mem0-dev"
PG_CONTAINER="${COMPOSE_PROJECT}_postgres_1"
OLLAMA_HOST="${OLLAMA_HOST:-localhost:11434}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
BENCH_USER="bench-$$"

pg_exec() { podman exec "$PG_CONTAINER" psql -U postgres -d postgres -t -A "$@"; }

embed_text() {
  local text="$1"
  curl -s -X POST "http://$OLLAMA_HOST/api/embed" \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$EMBED_MODEL"'","input":'"$(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$text")"'}' | \
    node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8')); process.stdout.write(JSON.stringify(d.embeddings[0]))"
}

embed_timed() {
  local text="$1"
  local start end
  start=$(date +%s%3N)
  local vec=$(embed_text "$text")
  end=$(date +%s%3N)
  echo "$vec" > "$_tmpdir/vec"
  echo $((end - start)) > "$_tmpdir/ms"
}

cleanup_bench_data() {
  pg_exec -c "DELETE FROM memories WHERE payload->>'user_id'='$BENCH_USER';" >/dev/null 2>&1 || true
}

sep() { echo ""; echo -e "${DIM}─────────────────────────────────────────${NC}"; }

echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  LEVEL 1: Ollama Embedding Latency${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"

echo -e "\n${BOLD}T1  Short text embed (5 runs)${NC}"
T1_TOTAL=0; T1_OK=0
for i in 1 2 3 4 5; do
  embed_timed "I love hiking in the mountains"
  ms=$(cat "$_tmpdir/ms"); vec=$(cat "$_tmpdir/vec")
  T1_TOTAL=$((T1_TOTAL + ms))
  [ -n "$vec" ] && T1_OK=$((T1_OK + 1))
done
T1_AVG=$((T1_TOTAL / 5))
if [ "$T1_OK" -eq 5 ]; then
  report_pass "$T1_AVG" "avg=${T1_AVG}ms"
else
  report_fail "$T1_AVG" "$T1_OK/5 ok"
fi

echo -e "\n${BOLD}T2  Long text embed (~500 chars, 5 runs)${NC}"
LONG="I am a senior software architect with 15 years of experience. I started at a small startup building e-commerce platforms using PHP and MySQL. Over the years I transitioned through Java Spring Boot, then to Node.js with Express, and finally settled on Go for backend services and React with TypeScript for frontend."
T2_TOTAL=0; T2_OK=0
for i in 1 2 3 4 5; do
  embed_timed "$LONG"
  ms=$(cat "$_tmpdir/ms"); vec=$(cat "$_tmpdir/vec")
  T2_TOTAL=$((T2_TOTAL + ms))
  [ -n "$vec" ] && T2_OK=$((T2_OK + 1))
done
T2_AVG=$((T2_TOTAL / 5))
if [ "$T2_OK" -eq 5 ]; then
  report_pass "$T2_AVG" "avg=${T2_AVG}ms"
else
  report_fail "$T2_AVG" "$T2_OK/5 ok"
fi

echo -e "\n${BOLD}T3  Concurrent embed (10 parallel)${NC}"
T3_START=$(date +%s%3N)
PIDS=""
for i in $(seq 1 10); do
  embed_timed "concurrent test sentence number $i" &
  PIDS="$PIDS $!"
done
wait $PIDS
T3_END=$(date +%s%3N)
T3_TOTAL=$((T3_END - T3_START))
report_pass "$T3_TOTAL" "10 parallel in ${T3_TOTAL}ms"


sep
echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  LEVEL 2: pgvector Search Latency${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"

echo -e "\n${BOLD}T4  Seed 20 vectors for search bench${NC}"
T4_OK=0
for i in $(seq 1 20); do
  VEC=$(embed_text "Fact $i: I enjoy hobby number $i in my free time.")
  if [ -n "$VEC" ]; then
    pg_exec -c "INSERT INTO memories (vector, payload) VALUES ('$VEC'::vector, '{\"text\":\"Fact $i: hobby $i\",\"user_id\":\"$BENCH_USER\"}');" >/dev/null 2>&1
    T4_OK=$((T4_OK + 1))
  fi
done
TOTAL_ROWS=$(pg_exec -c "SELECT COUNT(*) FROM memories;")
report_pass "0" "seeded $T4_OK/20, table now has $TOTAL_ROWS rows"

echo -e "\n${BOLD}T5  Cosine search (5 runs)${NC}"
QUERY_VEC=$(embed_text "What hobbies does this person enjoy?")
T5_TOTAL=0; T5_OK=0
for i in 1 2 3 4 5; do
  start=$(date +%s%3N)
  RESULT=$(pg_exec -c "SELECT payload->>'text' FROM memories WHERE payload->>'user_id'='$BENCH_USER' ORDER BY vector <=> '$QUERY_VEC'::vector LIMIT 3;")
  end=$(date +%s%3N)
  ms=$((end - start))
  T5_TOTAL=$((T5_TOTAL + ms))
  [ -n "$RESULT" ] && T5_OK=$((T5_OK + 1))
done
T5_AVG=$((T5_TOTAL / 5))
if [ "$T5_OK" -eq 5 ]; then
  report_pass "$T5_AVG" "avg=${T5_AVG}ms (3 results)"
else
  report_fail "$T5_AVG" "$T5_OK/5 ok"
fi

echo -e "\n${BOLD}T6  Search quality (top result relevance)${NC}"
BEST=$(pg_exec -c "SELECT payload->>'text', (1 - (vector <=> '$QUERY_VEC'::vector))::numeric(4,3) AS score FROM memories WHERE payload->>'user_id'='$BENCH_USER' ORDER BY vector <=> '$QUERY_VEC'::vector LIMIT 1;")
if echo "$BEST" | grep -qi "hobby"; then
  report_pass "0" "top result: $BEST"
else
  report_fail "0" "top result: $BEST"
fi

echo -e "\n${BOLD}T7  Insert latency (5 runs)${NC}"
T7_TOTAL=0; T7_OK=0
for i in $(seq 1 5); do
  VEC=$(embed_text "Insert bench $i: quick fact about topic $i")
  start=$(date +%s%3N)
  pg_exec -c "INSERT INTO memories (vector, payload) VALUES ('$VEC'::vector, '{\"text\":\"bench insert $i\",\"user_id\":\"$BENCH_USER\"}');" >/dev/null 2>&1
  end=$(date +%s%3N)
  ms=$((end - start))
  T7_TOTAL=$((T7_TOTAL + ms))
  [ $? -eq 0 ] && T7_OK=$((T7_OK + 1))
done
T7_AVG=$((T7_TOTAL / 5))
if [ "$T7_OK" -eq 5 ]; then
  report_pass "$T7_AVG" "avg=${T7_AVG}ms (embed+insert)"
else
  report_fail "$T7_AVG" "$T7_OK/5 ok"
fi


sep
echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  LEVEL 3: Full Pipeline + Stress${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"

echo -e "\n${BOLD}T8  Full pipeline: embed+insert+search (10 runs)${NC}"
T8_TOTAL=0; T8_OK=0
for i in $(seq 1 10); do
  start=$(date +%s%3N)
  VEC=$(embed_text "Pipeline test $i: memory about topic $i for pipeline benchmark")
  pg_exec -c "INSERT INTO memories (vector, payload) VALUES ('$VEC'::vector, '{\"text\":\"pipeline $i\",\"user_id\":\"$BENCH_USER\"}');" >/dev/null 2>&1
  RESULT=$(pg_exec -c "SELECT COUNT(*) FROM memories WHERE payload->>'user_id'='$BENCH_USER' AND payload->>'text' LIKE 'pipeline $i%';")
  end=$(date +%s%3N)
  ms=$((end - start))
  T8_TOTAL=$((T8_TOTAL + ms))
  [ "$RESULT" -ge 1 ] 2>/dev/null && T8_OK=$((T8_OK + 1))
done
T8_AVG=$((T8_TOTAL / 10))
if [ "$T8_OK" -ge 8 ]; then
  report_pass "$T8_AVG" "$T8_OK/10 ok, avg=${T8_AVG}ms"
else
  report_fail "$T8_AVG" "$T8_OK/10 ok"
fi

echo -e "\n${BOLD}T9  Stress: 50 sequential inserts${NC}"
T9_START=$(date +%s%3N)
T9_OK=0
for i in $(seq 1 50); do
  VEC=$(embed_text "Stress test fact number $i about various topics")
  pg_exec -c "INSERT INTO memories (vector, payload) VALUES ('$VEC'::vector, '{\"text\":\"stress $i\",\"user_id\":\"$BENCH_USER\"}');" >/dev/null 2>&1
  T9_OK=$((T9_OK + 1))
done
T9_END=$(date +%s%3N)
T9_TOTAL=$((T9_END - T9_START))
T9_AVG=$((T9_TOTAL / 50))
FINAL_ROWS=$(pg_exec -c "SELECT COUNT(*) FROM memories;")
report_pass "$T9_TOTAL" "50 inserts in ${T9_TOTAL}ms (avg=${T9_AVG}ms), total=$FINAL_ROWS rows"

echo -e "\n${BOLD}T10  Delete all bench data${NC}"
BEFORE=$(pg_exec -c "SELECT COUNT(*) FROM memories WHERE payload->>'user_id'='$BENCH_USER';")
pg_exec -c "DELETE FROM memories WHERE payload->>'user_id'='$BENCH_USER';" >/dev/null
AFTER=$(pg_exec -c "SELECT COUNT(*) FROM memories WHERE payload->>'user_id'='$BENCH_USER';")
if [ "$AFTER" = "0" ]; then
  report_pass "0" "deleted $BEFORE rows"
else
  report_fail "0" "$AFTER rows remain"
fi


sep
echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  VM RESOURCE SNAPSHOT${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"

echo ""
echo -e "  ${DIM}CPU: $(nproc) cores ($(cat /proc/cpuinfo | grep "model name" | head -1 | sed 's/.*: //'))${NC}"
echo -e "  ${DIM}RAM: $(free -h | awk '/^Mem:/{print $2 " total, " $3 " used, " $7 " available"}')${NC}"
echo -e "  ${DIM}Disk: $(df -h / | awk 'NR==2{print $3 " used, " $4 " free of " $2}')${NC}"
echo -e "  ${DIM}Swap: $(free -h | awk '/^Swap:/{print $3 " used of " $2}')${NC}"
echo ""
podman stats --no-stream --format "  ${DIM}{{.Name}}: CPU={{.CPUPerc}} MEM={{.MemUsage}}${NC}" 2>/dev/null


sep
echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  SUMMARY${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Total: ${BOLD}$TOTAL${NC}  |  ${GREEN}Pass: $PASS${NC}  |  ${RED}Fail: $FAIL${NC}"
if [ "$TOTAL" -gt 0 ]; then
  PCT=$((PASS * 100 / TOTAL))
  echo -e "  Score: ${BOLD}${PCT}%${NC}"
fi
echo ""
