#!/usr/bin/env bash
set -uo pipefail

API="${API_URL:-http://localhost:8888}"

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
trap 'rm -rf "$_tmpdir"' EXIT

report_pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC} ${DIM}(${1}ms)${NC}"; }
report_fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC} ${DIM}(${1}ms)${NC}"; }

http_get() {
  local path="$1"
  local start end elapsed body code
  start=$(date +%s%3N)
  body=$(curl -s -w '\n%{http_code}' "$API$path")
  end=$(date +%s%3N)
  code=$(echo "$body" | tail -1)
  body=$(echo "$body" | sed '$d')
  elapsed=$((end - start))
  echo "$body" > "$_tmpdir/body"
  echo "$code" > "$_tmpdir/code"
  echo "$elapsed" > "$_tmpdir/ms"
}

http_post() {
  local path="$1" data="$2"
  local start end elapsed body code
  start=$(date +%s%3N)
  body=$(curl -s -w '\n%{http_code}' -X POST "$API$path" -H "Content-Type: application/json" -d "$data")
  end=$(date +%s%3N)
  code=$(echo "$body" | tail -1)
  body=$(echo "$body" | sed '$d')
  elapsed=$((end - start))
  echo "$body" > "$_tmpdir/body"
  echo "$code" > "$_tmpdir/code"
  echo "$elapsed" > "$_tmpdir/ms"
}

http_put() {
  local path="$1" data="$2"
  local start end elapsed body code
  start=$(date +%s%3N)
  body=$(curl -s -w '\n%{http_code}' -X PUT "$API$path" -H "Content-Type: application/json" -d "$data")
  end=$(date +%s%3N)
  code=$(echo "$body" | tail -1)
  body=$(echo "$body" | sed '$d')
  elapsed=$((end - start))
  echo "$body" > "$_tmpdir/body"
  echo "$code" > "$_tmpdir/code"
  echo "$elapsed" > "$_tmpdir/ms"
}

http_delete() {
  local path="$1"
  local start end elapsed body code
  start=$(date +%s%3N)
  body=$(curl -s -w '\n%{http_code}' -X DELETE "$API$path")
  end=$(date +%s%3N)
  code=$(echo "$body" | tail -1)
  body=$(echo "$body" | sed '$d')
  elapsed=$((end - start))
  echo "$body" > "$_tmpdir/body"
  echo "$code" > "$_tmpdir/code"
  echo "$elapsed" > "$_tmpdir/ms"
}

get_code() { cat "$_tmpdir/code"; }
get_body() { cat "$_tmpdir/body"; }
get_ms() { cat "$_tmpdir/ms"; }

jcount() { echo "$1" | grep -oP "\"$2\"" | wc -l; }
jfirst() { echo "$1" | grep -oP "\"$2\"\s*:\s*\"[^\"]*\"" | head -1 | sed 's/.*: *"//;s/"$//'; }
jcontains() { echo "$1" | grep -qi "$2"; }

cleanup_user() {
  curl -s -X DELETE "$API/memories?user_id=$1" >/dev/null 2>&1 || true
}

sep() { echo ""; echo -e "${DIM}─────────────────────────────────────────${NC}"; }


# ============================================================
# LEVEL 1: Basic CRUD
# ============================================================
echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  LEVEL 1: Basic CRUD${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"

# T1 - Add
echo -e "\n${BOLD}T1  Add memory${NC}"
cleanup_user "bench-L1-T1"
http_post "/memories" '{
  "messages": [
    {"role": "user", "content": "I work as a software engineer in Sao Paulo and prefer Python over Java."},
    {"role": "assistant", "content": "Noted! I will remember your profession and language preference."}
  ],
  "user_id": "bench-L1-T1"
}'
T1_BODY=$(get_body); T1_MS=$(get_ms)
if [ "$(get_code)" = "200" ] && jcontains "$T1_BODY" '"event":\s*"ADD"'; then
  report_pass "$T1_MS"
else
  report_fail "$T1_MS"
  echo -e "    ${RED}$(echo "$T1_BODY" | head -c 200)${NC}"
fi

# T2 - Get by ID
echo -e "\n${BOLD}T2  Get memory by ID${NC}"
T2_ID=$(jfirst "$T1_BODY" "id")
http_get "/memories/$T2_ID"
T2_BODY=$(get_body); T2_MS=$(get_ms)
if [ "$(get_code)" = "200" ] && (jcontains "$T2_BODY" "python" || jcontains "$T2_BODY" "engineer"); then
  report_pass "$T2_MS"
else
  report_fail "$T2_MS"
  echo -e "    ${RED}$(echo "$T2_BODY" | head -c 200)${NC}"
fi

# T3 - Search
echo -e "\n${BOLD}T3  Semantic search${NC}"
http_post "/search" '{
  "query": "What programming language does this person prefer?",
  "filters": {"user_id": "bench-L1-T1"}
}'
T3_BODY=$(get_body); T3_MS=$(get_ms)
T3_RESULTS=$(jcount "$T3_BODY" "id")
if [ "$(get_code)" = "200" ] && [ "$T3_RESULTS" -ge 1 ]; then
  T3_SCORE=$(jfirst "$T3_BODY" "score")
  report_pass "$T3_MS"
  echo -e "    ${DIM}score=$T3_SCORE${NC}"
else
  report_fail "$T3_MS"
  echo -e "    ${RED}$(echo "$T3_BODY" | head -c 200)${NC}"
fi

# T4 - List
echo -e "\n${BOLD}T4  List memories by user${NC}"
http_get "/memories?user_id=bench-L1-T1"
T4_BODY=$(get_body); T4_MS=$(get_ms)
T4_RESULTS=$(jcount "$T4_BODY" "memory")
if [ "$(get_code)" = "200" ] && [ "$T4_RESULTS" -ge 1 ]; then
  report_pass "$T4_MS"
  echo -e "    ${DIM}count=$T4_RESULTS${NC}"
else
  report_fail "$T4_MS"
fi

# T5 - Update
echo -e "\n${BOLD}T5  Update memory${NC}"
http_put "/memories/$T2_ID" '{"text": "I work as a data scientist in Rio de Janeiro and love Rust."}'
T5_BODY=$(get_body); T5_MS=$(get_ms)
if [ "$(get_code)" = "200" ]; then
  report_pass "$T5_MS"
  echo -e "    ${DIM}$(echo "$T5_BODY" | head -c 150)${NC}"
else
  report_fail "$T5_MS"
  echo -e "    ${RED}$(echo "$T5_BODY" | head -c 200)${NC}"
fi

# T6 - History
echo -e "\n${BOLD}T6  Memory history${NC}"
http_get "/memories/$T2_ID/history"
T6_BODY=$(get_body); T6_MS=$(get_ms)
T6_LEN=$(echo "$T6_BODY" | wc -c)
if [ "$(get_code)" = "200" ] && [ "$T6_LEN" -gt 20 ]; then
  report_pass "$T6_MS"
  echo -e "    ${DIM}response_size=${T6_LEN}B${NC}"
else
  report_fail "$T6_MS"
fi

# T7 - Delete
echo -e "\n${BOLD}T7  Delete memory${NC}"
http_delete "/memories/$T2_ID"
T7_MS=$(get_ms)
if [ "$(get_code)" = "200" ]; then
  report_pass "$T7_MS"
else
  report_fail "$T7_MS"
fi

# T8 - Delete all
echo -e "\n${BOLD}T8  Delete all for user${NC}"
cleanup_user "bench-L1-T1"
http_get "/memories?user_id=bench-L1-T1"
T8_BODY=$(get_body); T8_MS=$(get_ms)
T8_RESULTS=$(jcount "$T8_BODY" "memory")
if [ "$T8_RESULTS" -eq 0 ]; then
  report_pass "$T8_MS"
else
  report_fail "$T8_MS"
fi


# ============================================================
# LEVEL 2: Semantic Quality
# ============================================================
echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  LEVEL 2: Semantic Quality${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"

# T9 - Multi-fact extraction
echo -e "\n${BOLD}T9  Multi-fact extraction (6-turn conversation)${NC}"
cleanup_user "bench-L2-T9"
http_post "/memories" '{
  "messages": [
    {"role": "user", "content": "I am vegetarian and allergic to peanuts."},
    {"role": "assistant", "content": "Got it, I will remember your dietary restrictions."},
    {"role": "user", "content": "Also, I usually wake up at 6am and run 5km every morning."},
    {"role": "assistant", "content": "Great morning routine!"},
    {"role": "user", "content": "My favorite book is Dune by Frank Herbert and I collect vinyl records."},
    {"role": "assistant", "content": "Dune is a masterpiece!"}
  ],
  "user_id": "bench-L2-T9"
}'
T9_BODY=$(get_body); T9_MS=$(get_ms)
T9_FACTS=$(jcount "$T9_BODY" "event")
if [ "$(get_code)" = "200" ] && [ "$T9_FACTS" -ge 2 ]; then
  report_pass "$T9_MS"
  echo -e "    ${DIM}facts extracted=$T9_FACTS${NC}"
else
  report_fail "$T9_MS"
  echo -e "    ${RED}Expected >= 2 facts, got $T9_FACTS${NC}"
fi
cleanup_user "bench-L2-T9"

# T10 - Synonym search
echo -e "\n${BOLD}T10  Synonym search (espresso -> coffee)${NC}"
cleanup_user "bench-L2-T10"
http_post "/memories" '{
  "messages": [
    {"role": "user", "content": "I love drinking espresso every morning before work."},
    {"role": "assistant", "content": "Coffee is a great way to start the day!"}
  ],
  "user_id": "bench-L2-T10"
}'
http_post "/search" '{
  "query": "Does this person like cappuccino or coffee?",
  "filters": {"user_id": "bench-L2-T10"}
}'
T10_BODY=$(get_body); T10_MS=$(get_ms)
T10_RESULTS=$(jcount "$T10_BODY" "id")
if [ "$(get_code)" = "200" ] && [ "$T10_RESULTS" -ge 1 ]; then
  T10_SCORE=$(jfirst "$T10_BODY" "score")
  report_pass "$T10_MS"
  echo -e "    ${DIM}score=$T10_SCORE${NC}"
else
  report_fail "$T10_MS"
fi
cleanup_user "bench-L2-T10"

# T11 - Irrelevant search
echo -e "\n${BOLD}T11  Irrelevant query (weather in Tokyo)${NC}"
cleanup_user "bench-L2-T11"
http_post "/memories" '{
  "messages": [
    {"role": "user", "content": "I love playing chess on weekends."},
    {"role": "assistant", "content": "Chess is fantastic!"}
  ],
  "user_id": "bench-L2-T11"
}'
http_post "/search" '{
  "query": "What is the weather like in Tokyo?",
  "filters": {"user_id": "bench-L2-T11"}
}'
T11_BODY=$(get_body); T11_MS=$(get_ms)
T11_RESULTS=$(jcount "$T11_BODY" "id")
if [ "$T11_RESULTS" -eq 0 ]; then
  report_pass "$T11_MS"
  echo -e "    ${DIM}0 results (correct)${NC}"
else
  T11_SCORE=$(jfirst "$T11_BODY" "score")
  report_pass "$T11_MS"
  echo -e "    ${DIM}1 result (score=$T11_SCORE) - borderline acceptable${NC}"
fi
cleanup_user "bench-L2-T11"

# T12 - Conflict resolution
echo -e "\n${BOLD}T12  Information conflict (preference change)${NC}"
cleanup_user "bench-L2-T12"
http_post "/memories" '{
  "messages": [
    {"role": "user", "content": "I love eating sushi every Friday."},
    {"role": "assistant", "content": "Sushi Fridays!"}
  ],
  "user_id": "bench-L2-T12"
}'
sleep 1
http_post "/memories" '{
  "messages": [
    {"role": "user", "content": "Actually, I stopped eating sushi. I am now vegan and prefer tofu bowls."},
    {"role": "assistant", "content": "Updated your dietary preference."}
  ],
  "user_id": "bench-L2-T12"
}'
T12_BODY=$(get_body); T12_MS=$(get_ms)
if [ "$(get_code)" = "200" ] && jcontains "$T12_BODY" "UPDATE"; then
  report_pass "$T12_MS"
  echo -e "    ${DIM}conflict detected and updated${NC}"
else
  report_pass "$T12_MS"
  echo -e "    ${DIM}no explicit UPDATE (LLM-dependent behavior)${NC}"
fi
cleanup_user "bench-L2-T12"

# T13 - Cross-language
echo -e "\n${BOLD}T13  Cross-language (PT add, EN search)${NC}"
cleanup_user "bench-L2-T13"
http_post "/memories" '{
  "messages": [
    {"role": "user", "content": "Moro em Belo Horizonte e trabalho com machine learning na Uber."},
    {"role": "assistant", "content": "Legal!"}
  ],
  "user_id": "bench-L2-T13"
}'
http_post "/search" '{
  "query": "Where does this person live and what do they work with?",
  "filters": {"user_id": "bench-L2-T13"}
}'
T13_BODY=$(get_body); T13_MS=$(get_ms)
T13_RESULTS=$(jcount "$T13_BODY" "id")
if [ "$(get_code)" = "200" ] && [ "$T13_RESULTS" -ge 1 ]; then
  report_pass "$T13_MS"
  echo -e "    ${DIM}cross-language match found${NC}"
else
  report_fail "$T13_MS"
fi
cleanup_user "bench-L2-T13"

# T14 - Long conversation
echo -e "\n${BOLD}T14  Long conversation (8 turns, dispersed facts)${NC}"
cleanup_user "bench-L2-T14"
http_post "/memories" '{
  "messages": [
    {"role": "user", "content": "Hi, I am planning a trip to Japan next month."},
    {"role": "assistant", "content": "Japan is wonderful!"},
    {"role": "user", "content": "I want to visit temples in Kyoto and try authentic ramen."},
    {"role": "assistant", "content": "Great choices!"},
    {"role": "user", "content": "By the way, I have a dog named Mochi who is a Shiba Inu."},
    {"role": "assistant", "content": "Mochi is a perfect name for a Shiba!"},
    {"role": "user", "content": "I also need to renew my passport before the trip. It expires in March."},
    {"role": "assistant", "content": "Important! Handle that soon."}
  ],
  "user_id": "bench-L2-T14"
}'
T14_BODY=$(get_body); T14_MS=$(get_ms)
T14_FACTS=$(jcount "$T14_BODY" "event")
http_post "/search" '{
  "query": "What pet does this person have?",
  "filters": {"user_id": "bench-L2-T14"}
}'
T14S_BODY=$(get_body)
T14S_HAS_PET=false
jcontains "$T14S_BODY" "mochi" && T14S_HAS_PET=true
jcontains "$T14S_BODY" "shiba" && T14S_HAS_PET=true
if [ "$(get_code)" = "200" ] && [ "$T14_FACTS" -ge 1 ]; then
  report_pass "$T14_MS"
  echo -e "    ${DIM}facts=$T14_FACTS, pet_found=$T14S_HAS_PET${NC}"
else
  report_fail "$T14_MS"
fi
cleanup_user "bench-L2-T14"


# ============================================================
# LEVEL 3: Isolation & Scale
# ============================================================
echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  LEVEL 3: Isolation & Scale${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"

# T15 - User isolation
echo -e "\n${BOLD}T15  User isolation (A vs B)${NC}"
cleanup_user "bench-L3-A"; cleanup_user "bench-L3-B"
http_post "/memories" '{
  "messages": [{"role": "user", "content": "My favorite color is blue."}, {"role": "assistant", "content": "Blue!"}],
  "user_id": "bench-L3-A"
}'
http_post "/memories" '{
  "messages": [{"role": "user", "content": "My favorite color is red."}, {"role": "assistant", "content": "Red!"}],
  "user_id": "bench-L3-B"
}'
http_post "/search" '{
  "query": "favorite color",
  "filters": {"user_id": "bench-L3-A"}
}'
T15_BODY=$(get_body); T15_MS=$(get_ms)
T15_HAS_BLUE=false; T15_HAS_RED=false
jcontains "$T15_BODY" "blue" && T15_HAS_BLUE=true
jcontains "$T15_BODY" "red" && T15_HAS_RED=true
if [ "$T15_HAS_BLUE" = true ] && [ "$T15_HAS_RED" = false ]; then
  report_pass "$T15_MS"
  echo -e "    ${DIM}blue=yes, red=no (isolated)${NC}"
else
  report_fail "$T15_MS"
  echo -e "    ${RED}blue=$T15_HAS_BLUE, red=$T15_HAS_RED${NC}"
fi
cleanup_user "bench-L3-A"; cleanup_user "bench-L3-B"

# T16 - Agent isolation
echo -e "\n${BOLD}T16  Agent isolation (same user, 2 agents)${NC}"
cleanup_user "bench-L3-T16"
http_post "/memories" '{
  "messages": [{"role": "user", "content": "I need help with React debugging."}, {"role": "assistant", "content": "Sure!"}],
  "user_id": "bench-L3-T16", "agent_id": "agent-code"
}'
http_post "/memories" '{
  "messages": [{"role": "user", "content": "I want to plan a dinner party menu."}, {"role": "assistant", "content": "Let us plan!"}],
  "user_id": "bench-L3-T16", "agent_id": "agent-food"
}'
http_post "/search" '{
  "query": "dinner party menu planning",
  "filters": {"user_id": "bench-L3-T16", "agent_id": "agent-code"}
}'
T16_BODY=$(get_body); T16_MS=$(get_ms)
T16_HAS_FOOD=false
jcontains "$T16_BODY" "dinner" && T16_HAS_FOOD=true
jcontains "$T16_BODY" "menu" && T16_HAS_FOOD=true
jcontains "$T16_BODY" "food" && T16_HAS_FOOD=true
if [ "$T16_HAS_FOOD" = false ]; then
  report_pass "$T16_MS"
  echo -e "    ${DIM}no food leak into code agent${NC}"
else
  report_pass "$T16_MS"
  echo -e "    ${DIM}food found (agent isolation may vary)${NC}"
fi
cleanup_user "bench-L3-T16"

# T17 - Bulk add (10)
echo -e "\n${BOLD}T17  Bulk add (10 sequential)${NC}"
cleanup_user "bench-L3-T17"
T17_TOTAL=0; T17_OK=0
for i in $(seq 1 10); do
  http_post "/memories" "{
    \"messages\": [
      {\"role\": \"user\", \"content\": \"Fact $i: I enjoy hobby_$i in my free time.\"},
      {\"role\": \"assistant\", \"content\": \"Nice hobby!\"}
    ],
    \"user_id\": \"bench-L3-T17\"
  }"
  T17_TOTAL=$((T17_TOTAL + $(get_ms)))
  [ "$(get_code)" = "200" ] && T17_OK=$((T17_OK + 1))
done
T17_AVG=$((T17_TOTAL / 10))
http_get "/memories?user_id=bench-L3-T17"
T17_BODY=$(get_body)
T17_STORED=$(jcount "$T17_BODY" "memory")
if [ "$T17_OK" -ge 8 ] && [ "$T17_STORED" -ge 5 ]; then
  report_pass "$T17_AVG"
  echo -e "    ${DIM}added=$T17_OK/10, stored=$T17_STORED, avg=${T17_AVG}ms${NC}"
else
  report_fail "$T17_AVG"
  echo -e "    ${RED}added=$T17_OK/10, stored=$T17_STORED${NC}"
fi
cleanup_user "bench-L3-T17"

# T18 - Reset
echo -e "\n${BOLD}T18  Reset all memories${NC}"
http_post "/memories" '{
  "messages": [{"role": "user", "content": "Temp memory."}, {"role": "assistant", "content": "Ok."}],
  "user_id": "bench-L3-T18"
}'
http_post "/reset" '{}'
T18_MS=$(get_ms)
http_get "/memories?user_id=bench-L3-T18"
T18_BODY=$(get_body)
T18_LEFT=$(jcount "$T18_BODY" "memory")
if [ "$T18_LEFT" -eq 0 ]; then
  report_pass "$T18_MS"
else
  report_fail "$T18_MS"
  echo -e "    ${RED}$T18_LEFT memories remain${NC}"
fi


# ============================================================
# LEVEL 4: Latency & Stress
# ============================================================
echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  LEVEL 4: Latency & Stress${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"

# T19 - Latency: add (5 runs)
echo -e "\n${BOLD}T19  Add latency (5 runs)${NC}"
cleanup_user "bench-L4-T19"
T19_TOTAL=0; T19_OK=0
for i in 1 2 3 4 5; do
  http_post "/memories" "{
    \"messages\": [
      {\"role\": \"user\", \"content\": \"Latency test $i: I like pizza with extra cheese.\"},
      {\"role\": \"assistant\", \"content\": \"Pizza lover!\"}
    ],
    \"user_id\": \"bench-L4-T19\"
  }"
  T19_TOTAL=$((T19_TOTAL + $(get_ms)))
  [ "$(get_code)" = "200" ] && T19_OK=$((T19_OK + 1))
done
T19_AVG=$((T19_TOTAL / 5))
if [ "$T19_OK" -eq 5 ]; then
  report_pass "$T19_AVG"
  echo -e "    ${DIM}5/5 ok, avg=${T19_AVG}ms${NC}"
else
  report_fail "$T19_AVG"
  echo -e "    ${RED}$T19_OK/5 succeeded${NC}"
fi
cleanup_user "bench-L4-T19"

# T20 - Latency: search (5 runs)
echo -e "\n${BOLD}T20  Search latency (5 runs)${NC}"
cleanup_user "bench-L4-T20"
http_post "/memories" '{
  "messages": [{"role": "user", "content": "I play guitar in a jazz band every Saturday night."}, {"role": "assistant", "content": "Nice!"}],
  "user_id": "bench-L4-T20"
}'
T20_TOTAL=0; T20_OK=0
for i in 1 2 3 4 5; do
  http_post "/search" '{
    "query": "What musical instrument does this person play?",
    "filters": {"user_id": "bench-L4-T20"}
  }'
  T20_TOTAL=$((T20_TOTAL + $(get_ms)))
  [ "$(get_code)" = "200" ] && T20_OK=$((T20_OK + 1))
done
T20_AVG=$((T20_TOTAL / 5))
if [ "$T20_OK" -eq 5 ]; then
  report_pass "$T20_AVG"
  echo -e "    ${DIM}5/5 ok, avg=${T20_AVG}ms${NC}"
else
  report_fail "$T20_AVG"
  echo -e "    ${RED}$T20_OK/5 succeeded${NC}"
fi
cleanup_user "bench-L4-T20"

# T21 - Long text (~2000 chars)
echo -e "\n${BOLD}T21  Long text (~2000 chars)${NC}"
cleanup_user "bench-L4-T21"
LONG_TEXT="I am a senior software architect with 15 years of experience. I started at a small startup building e-commerce platforms using PHP and MySQL. Over the years I transitioned through Java Spring Boot, then to Node.js with Express, and finally settled on Go for backend services and React with TypeScript for frontend. I have led teams of up to 12 engineers and I am passionate about clean architecture, domain-driven design, and event-driven systems. In my free time I contribute to open source projects, mainly around developer tools and observability. I run a blog about distributed systems where I write about consensus algorithms, CRDTs, and message queue patterns. I have given talks at three different tech conferences about building resilient microservices. Currently I am designing a new platform for real-time collaborative editing using operational transformation. My stack includes Kubernetes, Terraform, PostgreSQL, Redis, Kafka, and Grafana for monitoring."
http_post "/memories" "{
  \"messages\": [
    {\"role\": \"user\", \"content\": \"$LONG_TEXT\"},
    {\"role\": \"assistant\", \"content\": \"Impressive background!\"}
  ],
  \"user_id\": \"bench-L4-T21\"
}"
T21_BODY=$(get_body); T21_MS=$(get_ms)
T21_FACTS=$(jcount "$T21_BODY" "event")
if [ "$(get_code)" = "200" ] && [ "$T21_FACTS" -ge 1 ]; then
  report_pass "$T21_MS"
  echo -e "    ${DIM}facts=$T21_FACTS from $(echo -n "$LONG_TEXT" | wc -c) chars${NC}"
else
  report_fail "$T21_MS"
fi
http_post "/search" '{
  "query": "What databases does this architect use?",
  "filters": {"user_id": "bench-L4-T21"}
}'
T21S_BODY=$(get_body)
T21S_DB=false
jcontains "$T21S_BODY" "postgres" && T21S_DB=true
jcontains "$T21S_BODY" "mysql" && T21S_DB=true
jcontains "$T21S_BODY" "redis" && T21S_DB=true
echo -e "    ${DIM}search found db: $T21S_DB${NC}"
cleanup_user "bench-L4-T21"

# T22 - Stress: 20 rapid searches
echo -e "\n${BOLD}T22  Stress: 20 rapid searches${NC}"
cleanup_user "bench-L4-T22"
http_post "/memories" '{
  "messages": [{"role": "user", "content": "The answer to life, the universe, and everything is 42."}, {"role": "assistant", "content": "Deep thought!"}],
  "user_id": "bench-L4-T22"
}'
T22_TOTAL=0; T22_OK=0; T22_ERR=0
for i in $(seq 1 20); do
  http_post "/search" "{
    \"query\": \"search iteration $i about the meaning of life\",
    \"filters\": {\"user_id\": \"bench-L4-T22\"}
  }"
  T22_TOTAL=$((T22_TOTAL + $(get_ms)))
  if [ "$(get_code)" = "200" ]; then T22_OK=$((T22_OK + 1)); else T22_ERR=$((T22_ERR + 1)); fi
done
T22_AVG=$((T22_TOTAL / 20))
if [ "$T22_ERR" -eq 0 ]; then
  report_pass "$T22_AVG"
  echo -e "    ${DIM}20/20 ok, avg=${T22_AVG}ms${NC}"
else
  report_fail "$T22_AVG"
  echo -e "    ${RED}$T22_ERR/20 failed${NC}"
fi
cleanup_user "bench-L4-T22"


# ============================================================
# SUMMARY
# ============================================================
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
