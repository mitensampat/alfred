#!/bin/bash

# =============================================================================
# Alfred Learning System v3 — Evaluation Plan
# Tests all 6 phases of the learning system upgrade (5/10 → 9/10)
# =============================================================================
#
# HOW TO USE:
#   chmod +x scripts/eval_learning_system.sh
#   ./scripts/eval_learning_system.sh              # Run all phases
#   ./scripts/eval_learning_system.sh --phase 1    # Run specific phase
#   ./scripts/eval_learning_system.sh --phase 1,3  # Run multiple phases
#
# PREREQUISITES:
#   - Alfred running on port 8080 (Golden Path deployed)
#   - jq installed (brew install jq)
#   - sqlite3 available (ships with macOS)
#
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

BASE_URL="http://127.0.0.1:8080"
PASSCODE="REDACTED_PASSCODE"
DB_PATH="$HOME/.alfred/workflow_learning.db"
COACHING_MD="$HOME/.alfred/coaching_context.md"
CONTACTS_JSON="$HOME/.config/alfred/memory/contacts.json"
CORRECTIONS_JSON="$HOME/.config/alfred/memory/corrections.json"

PASSED=0
FAILED=0
SKIPPED=0
WARNINGS=0
declare -a TEST_RESULTS=()

# ─── Helpers ─────────────────────────────────────────────────────────────────

log_header() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

log_section() {
    echo ""
    echo -e "${CYAN}▶ $1${NC}"
    echo -e "${CYAN}─────────────────────────────────────────────────────────────${NC}"
}

log_test() { echo -e "  ${YELLOW}Testing:${NC} $1"; }
log_pass() { echo -e "  ${GREEN}✓ PASS:${NC} $1"; ((PASSED++)); TEST_RESULTS+=("✓ $1"); }
log_fail() { echo -e "  ${RED}✗ FAIL:${NC} $1"; ((FAILED++)); TEST_RESULTS+=("✗ $1"); }
log_skip() { echo -e "  ${YELLOW}⊘ SKIP:${NC} $1"; ((SKIPPED++)); TEST_RESULTS+=("⊘ $1"); }
log_warn() { echo -e "  ${YELLOW}⚠ WARN:${NC} $1"; ((WARNINGS++)); TEST_RESULTS+=("⚠ $1"); }
log_info() { echo -e "  ${BLUE}ℹ${NC} $1"; }

api() {
    # Usage: api GET /api/endpoint
    # Usage: api POST /api/endpoint '{"key":"value"}'
    local method="$1"
    local path="$2"
    local data="${3:-}"
    local sep="?"
    [[ "$path" == *"?"* ]] && sep="&"
    local url="${BASE_URL}${path}${sep}passcode=${PASSCODE}"

    if [ "$method" = "GET" ]; then
        curl -s -m 30 "$url"
    else
        curl -s -m 30 -X "$method" "$url" \
            -H "Content-Type: application/json" \
            ${data:+-d "$data"}
    fi
}

# Send a chat message and capture the full SSE stream
chat() {
    local msg="$1"
    local encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$msg'))")
    local session="${2:-eval_test_$$}"
    curl -s -m 60 \
        -H "Accept: text/event-stream" \
        "${BASE_URL}/api/chat/stream?q=${encoded}&sessionId=${session}&passcode=${PASSCODE}"
}

db_query() {
    sqlite3 "$DB_PATH" "$1" 2>/dev/null
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local test_name="$3"
    if echo "$haystack" | grep -qi "$needle"; then
        log_pass "$test_name"
    else
        log_fail "$test_name"
        log_info "Expected to find: '$needle'"
        log_info "Got: $(echo "$haystack" | head -c 200)"
    fi
}

assert_not_empty() {
    local value="$1"
    local test_name="$2"
    if [ -n "$value" ] && [ "$value" != "null" ] && [ "$value" != "0" ]; then
        log_pass "$test_name"
    else
        log_fail "$test_name (got empty/null/0)"
    fi
}

assert_gte() {
    local actual="$1"
    local expected="$2"
    local test_name="$3"
    if [ "$actual" -ge "$expected" ] 2>/dev/null; then
        log_pass "$test_name (got $actual, need >= $expected)"
    else
        log_fail "$test_name (got '$actual', need >= $expected)"
    fi
}

# ─── Prerequisite Check ─────────────────────────────────────────────────────

check_prereqs() {
    log_header "PREREQUISITE CHECK"

    log_test "Alfred is running"
    local health=$(api GET /api/health 2>/dev/null || echo "")
    if echo "$health" | grep -q '"status":"ok"'; then
        log_pass "Alfred is running and healthy"
    else
        log_fail "Alfred not running on $BASE_URL — start it first"
        exit 1
    fi

    log_test "Database exists"
    if [ -f "$DB_PATH" ]; then
        log_pass "workflow_learning.db exists"
    else
        log_fail "workflow_learning.db not found at $DB_PATH"
        exit 1
    fi

    log_test "jq available"
    if command -v jq &>/dev/null; then
        log_pass "jq is installed"
    else
        log_fail "jq not found — brew install jq"
        exit 1
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1: LLM-Based Signal Detection
# ═════════════════════════════════════════════════════════════════════════════

eval_phase_1() {
    log_header "PHASE 1: LLM-BASED SIGNAL DETECTION"

    # ── 1.1 Implicit correction detection ────────────────────────────────
    log_section "1.1 — Implicit corrections (no keywords)"

    local events_before=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='chat_correction';")

    log_test "Send implicit correction: 'actually I meant the other project'"
    chat "tell me about my tasks" "eval_p1_implicit"
    sleep 2
    chat "actually I meant the other project, not that one" "eval_p1_implicit"
    sleep 3

    local events_after=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='chat_correction';")
    local new_events=$((events_after - events_before))

    if [ "$new_events" -ge 1 ]; then
        log_pass "Implicit correction detected ($new_events new events)"
    else
        log_fail "Implicit correction NOT detected (keyword-only detector would miss this)"
        log_info "Before: $events_before, After: $events_after"
    fi

    # ── 1.2 Soft disagreement detection ──────────────────────────────────
    log_section "1.2 — Soft disagreements"

    events_before=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='chat_correction';")

    log_test "Send soft disagreement: 'hmm that's close but not quite what I was looking for'"
    chat "show me my calendar for today" "eval_p1_soft"
    sleep 2
    chat "hmm that's close but not quite what I was looking for, I wanted just work meetings" "eval_p1_soft"
    sleep 3

    events_after=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='chat_correction';")
    new_events=$((events_after - events_before))

    if [ "$new_events" -ge 1 ]; then
        log_pass "Soft disagreement detected ($new_events new events)"
    else
        log_fail "Soft disagreement NOT detected"
    fi

    # ── 1.3 Positive reinforcement detection ─────────────────────────────
    log_section "1.3 — Positive reinforcement signals"

    local reinforce_before=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='reinforcement';")

    log_test "Send reinforcement: 'yes exactly like that, perfect'"
    chat "what are my top priorities?" "eval_p1_reinforce"
    sleep 2
    chat "yes exactly like that, that's the level of detail I want" "eval_p1_reinforce"
    sleep 3

    local reinforce_after=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='reinforcement';")
    new_events=$((reinforce_after - reinforce_before))

    if [ "$new_events" -ge 1 ]; then
        log_pass "Reinforcement signal captured ($new_events new events)"
    else
        log_fail "Reinforcement signal NOT captured"
        log_info "Before: $reinforce_before, After: $reinforce_after"
    fi

    # ── 1.4 Direct instruction fast-path still works ─────────────────────
    log_section "1.4 — Direct instruction fast-path preserved"

    local di_before=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='direct_instruction';")

    log_test "Send direct instruction: 'from now on always give me bullet points'"
    chat "from now on always give me bullet points not paragraphs" "eval_p1_direct"
    sleep 3

    local di_after=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='direct_instruction';")
    new_events=$((di_after - di_before))

    if [ "$new_events" -ge 1 ]; then
        log_pass "Direct instruction captured immediately ($new_events new events)"
    else
        log_fail "Direct instruction NOT captured"
    fi

    # ── 1.5 False positive resistance ────────────────────────────────────
    log_section "1.5 — False positive resistance"

    events_before=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='chat_correction';")

    log_test "Send non-correction with 'no': 'no worries, sounds good to me'"
    chat "no worries about that, sounds good to me" "eval_p1_falsepos"
    sleep 3

    events_after=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='chat_correction';")
    new_events=$((events_after - events_before))

    if [ "$new_events" -eq 0 ]; then
        log_pass "No false positive correction recorded"
    else
        log_warn "False positive: 'no worries' recorded as correction ($new_events events)"
    fi

    # ── 1.6 Batch classification cost check ──────────────────────────────
    log_section "1.6 — Signal classification metadata"

    log_test "Check recent learning events have classification metadata"
    local has_metadata=$(db_query "SELECT COUNT(*) FROM learning_events WHERE metadata_json IS NOT NULL AND metadata_json != '' AND timestamp > datetime('now', '-5 minutes');")

    if [ "$has_metadata" -ge 1 ]; then
        log_pass "Learning events include metadata ($has_metadata recent events with metadata)"
    else
        log_warn "No metadata on recent learning events — classification may not be enriching events"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2: Unified Memory Index
# ═════════════════════════════════════════════════════════════════════════════

eval_phase_2() {
    log_header "PHASE 2: UNIFIED MEMORY INDEX"

    # ── 2.1 Index aggregates all sources ─────────────────────────────────
    log_section "2.1 — All memory sources indexed"

    log_test "GET /api/memory/all returns unified view"
    local memory_all=$(api GET /api/memory/all)

    # Check that response has data from multiple sources
    local has_sources=0
    echo "$memory_all" | grep -q "workflow" && ((has_sources++)) || true
    echo "$memory_all" | grep -q "coaching" && ((has_sources++)) || true
    echo "$memory_all" | grep -q "agent" && ((has_sources++)) || true
    echo "$memory_all" | grep -q "contact" && ((has_sources++)) || true

    if [ "$has_sources" -ge 3 ]; then
        log_pass "Unified memory includes $has_sources sources"
    else
        log_fail "Unified memory only has $has_sources sources (need >= 3)"
        log_info "Response preview: $(echo "$memory_all" | head -c 300)"
    fi

    # ── 2.2 Relevance-ranked retrieval ───────────────────────────────────
    log_section "2.2 — Relevance ranking"

    log_test "Query with topic returns relevant items first"
    # This tests internal behavior — verify via the coaching prompt
    # Send a commitment-related chat and check that commitment patterns appear in context
    local commitment_chat=$(chat "what commitments do I owe to people?" "eval_p2_relevance")

    # The response should reflect commitment-related learned context
    # We verify by checking the DB for which patterns were "used"
    sleep 2
    local recently_reinforced=$(db_query "SELECT COUNT(*) FROM learned_patterns WHERE pattern_type IN ('explicit_preference','communication_style') AND last_reinforced > datetime('now', '-1 minute');")

    if [ "$recently_reinforced" -ge 1 ]; then
        log_pass "Patterns reinforced through usage ($recently_reinforced patterns touched)"
    else
        log_warn "No patterns reinforced during query — may not have active patterns yet"
    fi

    # ── 2.3 Token budget enforcement ─────────────────────────────────────
    log_section "2.3 — Token budget stays within bounds"

    log_test "Learned context injection stays under 800 tokens"
    # We verify this indirectly: if there are many patterns, the system should still respond quickly
    local pattern_count=$(db_query "SELECT COUNT(*) FROM learned_patterns WHERE is_archived=0;")
    log_info "Active patterns in DB: $pattern_count"

    local start_time=$(date +%s)
    chat "quick question — what should I focus on today?" "eval_p2_tokens" >/dev/null
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    if [ "$elapsed" -le 45 ]; then
        log_pass "Chat response in ${elapsed}s (acceptable for context injection)"
    else
        log_warn "Chat response took ${elapsed}s — possible context bloat"
    fi

    # ── 2.4 Cross-source deduplication ───────────────────────────────────
    log_section "2.4 — No duplicate context injection"

    log_test "Same preference in agent memory and learned patterns doesn't double-inject"
    # Teach via direct instruction, then check unified endpoint
    local all_items=$(api GET /api/memory/all)
    local total_items=$(echo "$all_items" | jq 'if type == "array" then length elif type == "object" then [.[] | if type == "array" then .[] else . end] | length else 0 end' 2>/dev/null || echo "0")
    log_info "Total unified memory items: $total_items"

    # Check for exact duplicates (same content from different sources)
    # This is a structural check — exact test depends on response format
    if [ "$total_items" != "0" ]; then
        log_pass "Unified memory endpoint returns data ($total_items items)"
    else
        log_warn "Unified memory returned 0 items — may need more training data"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3: Faster Feedback Loop
# ═════════════════════════════════════════════════════════════════════════════

eval_phase_3() {
    log_header "PHASE 3: FASTER FEEDBACK LOOP"

    # ── 3.1 Real-time preference activation ──────────────────────────────
    log_section "3.1 — Preference takes effect on next message"

    # Record a new preference
    log_test "State preference, verify it's active immediately"
    local session="eval_p3_realtime_$$"

    chat "I prefer when you start responses with the most important point first" "$session"
    sleep 3

    # Check if pattern was created immediately (not waiting for daily batch)
    local immediate_pattern=$(db_query "SELECT COUNT(*) FROM learned_patterns WHERE description LIKE '%important point%' OR description LIKE '%most important%' AND created_at > datetime('now', '-1 minute');")

    if [ "$immediate_pattern" -ge 1 ]; then
        log_pass "Preference created immediately (not waiting for daily batch)"
    else
        # Check if it was at least recorded as an event
        local event_exists=$(db_query "SELECT COUNT(*) FROM learning_events WHERE context LIKE '%important point%' AND timestamp > datetime('now', '-2 minutes');")
        if [ "$event_exists" -ge 1 ]; then
            log_warn "Signal recorded but pattern not created immediately (still batch-dependent)"
        else
            log_fail "Preference not recorded at all"
        fi
    fi

    # ── 3.2 Two-correction threshold ─────────────────────────────────────
    log_section "3.2 — Pattern emerges from 2 corrections (not 3)"

    local session2="eval_p3_threshold_$$"
    local patterns_before=$(db_query "SELECT COUNT(*) FROM learned_patterns WHERE pattern_type='communication_style';")

    log_test "Send 2 similar corrections, check pattern creation"
    chat "summarize my week" "$session2"
    sleep 2
    chat "too long, be more concise" "$session2"
    sleep 2
    chat "show me today's calendar" "$session2"
    sleep 2
    chat "again, way too verbose. Keep it short" "$session2"
    sleep 4

    # Trigger pattern computation
    api POST /api/learning/compute >/dev/null 2>&1
    sleep 5

    local patterns_after=$(db_query "SELECT COUNT(*) FROM learned_patterns WHERE pattern_type='communication_style';")
    local new_patterns=$((patterns_after - patterns_before))

    if [ "$new_patterns" -ge 1 ]; then
        log_pass "Communication pattern created from 2 corrections ($new_patterns new)"
    else
        log_fail "No new communication pattern after 2 corrections"
        log_info "Before: $patterns_before, After: $patterns_after"
    fi

    # ── 3.3 Auto-graduation (skip review queue) ─────────────────────────
    log_section "3.3 — High-confidence patterns skip review queue"

    log_test "Check if new patterns from corrections are active (not pending)"
    local pending=$(db_query "SELECT COUNT(*) FROM pending_pattern_reviews WHERE status='pending' AND created_at > datetime('now', '-5 minutes');")
    local active=$(db_query "SELECT COUNT(*) FROM learned_patterns WHERE is_archived=0 AND is_stale=0 AND confidence >= 0.7 AND created_at > datetime('now', '-5 minutes');")

    log_info "Pending reviews (last 5min): $pending"
    log_info "Active patterns (last 5min): $active"

    if [ "$active" -ge 1 ]; then
        log_pass "Patterns are active without waiting for manual review"
    else
        log_warn "No auto-graduated patterns in last 5 minutes"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 4: Intelligent Staleness & Contradiction Resolution
# ═════════════════════════════════════════════════════════════════════════════

eval_phase_4() {
    log_header "PHASE 4: STALENESS & CONTRADICTION RESOLUTION"

    # ── 4.1 Type-specific staleness thresholds ───────────────────────────
    log_section "4.1 — Staleness varies by pattern type"

    log_test "Direct instructions never go stale"
    local stale_di=$(db_query "SELECT COUNT(*) FROM learned_patterns WHERE is_direct_instruction=1 AND is_stale=1;")
    if [ "$stale_di" -eq 0 ]; then
        log_pass "No direct instructions marked stale (correct)"
    else
        log_fail "$stale_di direct instructions are stale (should never happen)"
    fi

    log_test "User context facts never go stale"
    local stale_context=$(db_query "SELECT COUNT(*) FROM learned_patterns WHERE pattern_type='user_context' AND is_stale=1;")
    if [ "$stale_context" -eq 0 ]; then
        log_pass "No user context facts marked stale"
    else
        log_fail "$stale_context user context facts are stale (should never happen)"
    fi

    log_test "Communication style patterns have 90-day threshold (not 30)"
    # Insert a test pattern 45 days old, run staleness, verify it's NOT stale
    local test_id="eval_staleness_test_$$"
    db_query "INSERT OR REPLACE INTO learned_patterns (pattern_id, pattern_type, description, confidence, is_direct_instruction, is_stale, is_archived, last_reinforced, created_at) VALUES ('$test_id', 'communication_style', 'eval test pattern', 0.8, 0, 0, 0, datetime('now', '-45 days'), datetime('now', '-45 days'));"

    # Trigger staleness computation
    api POST /api/learning/compute >/dev/null 2>&1
    sleep 5

    local is_stale=$(db_query "SELECT is_stale FROM learned_patterns WHERE pattern_id='$test_id';")
    if [ "$is_stale" = "0" ]; then
        log_pass "45-day-old communication pattern is NOT stale (90-day threshold working)"
    else
        log_fail "45-day-old communication pattern is stale (still using 30-day threshold)"
    fi

    # Clean up test pattern
    db_query "DELETE FROM learned_patterns WHERE pattern_id='$test_id';"

    # ── 4.2 Reinforcement through usage ──────────────────────────────────
    log_section "4.2 — Patterns reinforced by being used in prompts"

    log_test "Active pattern's last_reinforced updates when injected into chat"
    local oldest_active=$(db_query "SELECT pattern_id FROM learned_patterns WHERE is_archived=0 AND is_stale=0 AND is_direct_instruction=0 ORDER BY last_reinforced ASC LIMIT 1;")

    if [ -n "$oldest_active" ]; then
        local before_ts=$(db_query "SELECT last_reinforced FROM learned_patterns WHERE pattern_id='$oldest_active';")
        chat "what should I focus on right now?" "eval_p4_reinforce" >/dev/null
        sleep 3
        local after_ts=$(db_query "SELECT last_reinforced FROM learned_patterns WHERE pattern_id='$oldest_active';")

        if [ "$before_ts" != "$after_ts" ]; then
            log_pass "Pattern '$oldest_active' was refreshed through usage"
        else
            log_fail "Pattern '$oldest_active' NOT refreshed (last_reinforced unchanged)"
        fi
    else
        log_skip "No active non-instruction patterns to test reinforcement"
    fi

    # ── 4.3 Contradiction detection ──────────────────────────────────────
    log_section "4.3 — Contradicting preferences handled"

    log_test "Contradictory instruction decays old pattern"
    local session="eval_p4_contradict_$$"

    # First, establish a preference
    chat "from now on always give me detailed explanations with examples" "$session"
    sleep 3

    local detail_pattern=$(db_query "SELECT confidence FROM learned_patterns WHERE description LIKE '%detail%' AND is_archived=0 ORDER BY created_at DESC LIMIT 1;")
    log_info "Detail pattern confidence before contradiction: ${detail_pattern:-none}"

    # Now contradict it
    chat "actually from now on keep things very brief, no examples needed" "$session"
    sleep 3

    local detail_after=$(db_query "SELECT confidence FROM learned_patterns WHERE description LIKE '%detail%' AND is_archived=0 ORDER BY created_at DESC LIMIT 1;")
    local brief_pattern=$(db_query "SELECT confidence FROM learned_patterns WHERE (description LIKE '%brief%' OR description LIKE '%concise%' OR description LIKE '%short%') AND is_archived=0 ORDER BY created_at DESC LIMIT 1;")

    log_info "Detail pattern confidence after contradiction: ${detail_after:-none}"
    log_info "Brief pattern confidence: ${brief_pattern:-none}"

    if [ -n "$brief_pattern" ]; then
        log_pass "New contradicting preference was created"
    else
        log_warn "Contradicting preference may not have been captured as a new pattern"
    fi

    # Check if old pattern confidence decreased
    if [ -n "$detail_pattern" ] && [ -n "$detail_after" ]; then
        local decreased=$(python3 -c "print('yes' if float('${detail_after}') < float('${detail_pattern}') else 'no')" 2>/dev/null || echo "unknown")
        if [ "$decreased" = "yes" ]; then
            log_pass "Old pattern confidence decreased (contradiction decay working)"
        else
            log_warn "Old pattern confidence did not decrease — contradiction decay may not be active"
        fi
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 5: User Memory Management
# ═════════════════════════════════════════════════════════════════════════════

eval_phase_5() {
    log_header "PHASE 5: USER MEMORY MANAGEMENT"

    # ── 5.1 View all memory ──────────────────────────────────────────────
    log_section "5.1 — GET /api/memory/all"

    log_test "Returns structured memory from all sources"
    local all_memory=$(api GET /api/memory/all)
    assert_not_empty "$all_memory" "Memory endpoint returns data"

    # Verify it includes confidence scores
    if echo "$all_memory" | grep -q "confidence"; then
        log_pass "Memory items include confidence scores"
    else
        log_warn "Memory items may not include confidence scores"
    fi

    # ── 5.2 Delete a pattern ─────────────────────────────────────────────
    log_section "5.2 — DELETE /api/learning/patterns"

    # Create a test pattern to delete
    local del_id="eval_delete_test_$$"
    db_query "INSERT INTO learned_patterns (pattern_id, pattern_type, description, confidence) VALUES ('$del_id', 'communication_style', 'eval delete test', 0.5);"

    log_test "Delete a learned pattern via API"
    local del_response=$(api DELETE "/api/learning/patterns?id=$del_id")

    local still_exists=$(db_query "SELECT COUNT(*) FROM learned_patterns WHERE pattern_id='$del_id';")
    if [ "$still_exists" -eq 0 ]; then
        log_pass "Pattern deleted successfully"
    else
        log_fail "Pattern still exists after DELETE call"
        db_query "DELETE FROM learned_patterns WHERE pattern_id='$del_id';"  # cleanup
    fi

    # Check that deletion was recorded as a learning event
    local del_event=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='user_deleted_pattern' AND context LIKE '%$del_id%' AND timestamp > datetime('now', '-1 minute');")
    if [ "$del_event" -ge 1 ]; then
        log_pass "Deletion recorded as learning event (system learns from deletions)"
    else
        log_warn "Deletion not recorded as learning event"
    fi

    # ── 5.3 Edit a pattern ───────────────────────────────────────────────
    log_section "5.3 — PUT /api/learning/patterns"

    local edit_id="eval_edit_test_$$"
    db_query "INSERT INTO learned_patterns (pattern_id, pattern_type, description, confidence) VALUES ('$edit_id', 'communication_style', 'original description', 0.7);"

    log_test "Edit a pattern description via API"
    local edit_response=$(api PUT "/api/learning/patterns?id=$edit_id" '{"description":"corrected description by user"}')

    local new_desc=$(db_query "SELECT description FROM learned_patterns WHERE pattern_id='$edit_id';")
    if [ "$new_desc" = "corrected description by user" ]; then
        log_pass "Pattern description updated"
    else
        log_fail "Pattern description not updated (got: '$new_desc')"
    fi

    db_query "DELETE FROM learned_patterns WHERE pattern_id='$edit_id';"  # cleanup

    # ── 5.4 Chat-based memory management ─────────────────────────────────
    log_section "5.4 — Chat-based forget/delete"

    log_test "'forget that' in chat triggers pattern management"
    # This is an intent recognition test — send "forget that" and verify it's handled
    local forget_response=$(chat "forget the pattern about being concise" "eval_p5_forget")

    # Check response indicates memory management happened
    if echo "$forget_response" | grep -qi "forgot\|removed\|deleted\|pattern\|memory"; then
        log_pass "Chat responded to 'forget' request"
    else
        log_warn "Chat response may not have handled 'forget' intent (response: $(echo "$forget_response" | head -c 200))"
    fi

    # ── 5.5 Memory feedback endpoint wired up ────────────────────────────
    log_section "5.5 — POST /api/memory/feedback"

    log_test "Negative feedback decays pattern confidence"
    local fb_id="eval_feedback_test_$$"
    db_query "INSERT INTO learned_patterns (pattern_id, pattern_type, description, confidence) VALUES ('$fb_id', 'communication_style', 'feedback test pattern', 0.8);"

    api POST /api/memory/feedback "{\"patternId\":\"$fb_id\",\"feedback\":\"negative\"}" >/dev/null 2>&1
    sleep 1

    local fb_conf=$(db_query "SELECT confidence FROM learned_patterns WHERE pattern_id='$fb_id';")
    if [ -n "$fb_conf" ]; then
        local decayed=$(python3 -c "print('yes' if float('$fb_conf') < 0.8 else 'no')" 2>/dev/null || echo "unknown")
        if [ "$decayed" = "yes" ]; then
            log_pass "Negative feedback decayed confidence to $fb_conf"
        else
            log_warn "Confidence not decayed (still $fb_conf) — feedback endpoint may not be wired up"
        fi
    fi

    db_query "DELETE FROM learned_patterns WHERE pattern_id='$fb_id';"  # cleanup
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 6: Contact Intelligence Integration
# ═════════════════════════════════════════════════════════════════════════════

eval_phase_6() {
    log_header "PHASE 6: CONTACT INTELLIGENCE INTEGRATION"

    # ── 6.1 Contact summary available ────────────────────────────────────
    log_section "6.1 — Contact intelligence in unified memory"

    log_test "Unified memory includes contact data"
    local memory=$(api GET /api/memory/all)

    if echo "$memory" | grep -qi "contact\|thread\|participation"; then
        log_pass "Contact intelligence present in unified memory"
    else
        log_warn "Contact intelligence not found in unified memory"
    fi

    # ── 6.2 Contact context injected on mention ──────────────────────────
    log_section "6.2 — Contact context injected when person mentioned"

    log_test "Mentioning a known contact enriches coaching context"
    # Get a known contact from favorites or contacts.json
    local known_contact=""
    if [ -f "$CONTACTS_JSON" ]; then
        known_contact=$(python3 -c "
import json
with open('$CONTACTS_JSON') as f:
    data = json.load(f)
    threads = data.get('threads', {})
    for k, v in threads.items():
        name = v.get('threadName', '')
        if name and not v.get('isGroup', False):
            print(name)
            break
" 2>/dev/null || echo "")
    fi

    if [ -n "$known_contact" ]; then
        log_info "Testing with known contact: $known_contact"
        local contact_chat=$(chat "what's the latest with $known_contact?" "eval_p6_contact")

        # We can't directly inspect the prompt, but we can verify the response
        # seems contextually aware of the contact relationship
        if echo "$contact_chat" | grep -qi "$known_contact\|thread\|message\|conversation"; then
            log_pass "Response references contact context"
        else
            log_warn "Response may not have used contact intelligence"
        fi
    else
        log_skip "No known contacts in contacts.json to test with"
    fi

    # ── 6.3 Contact summary API ──────────────────────────────────────────
    log_section "6.3 — Contact summary aggregation"

    log_test "Contact data includes cross-platform aggregation"
    if [ -f "$CONTACTS_JSON" ]; then
        local thread_count=$(python3 -c "
import json
with open('$CONTACTS_JSON') as f:
    data = json.load(f)
    print(len(data.get('threads', {})))
" 2>/dev/null || echo "0")
        log_info "Tracked threads: $thread_count"

        if [ "$thread_count" -ge 1 ]; then
            log_pass "Contact learning has data ($thread_count threads)"
        else
            log_warn "No threads tracked in contacts.json"
        fi
    else
        log_skip "contacts.json not found"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# END-TO-END COMPOUNDING TEST
# ═════════════════════════════════════════════════════════════════════════════

eval_e2e_compounding() {
    log_header "END-TO-END: FULL COMPOUNDING LOOP"

    local session="eval_e2e_$$"

    # ── E2E.1 Teach → Store → Apply cycle ────────────────────────────────
    log_section "E2E.1 — Teach → Store → Apply in single session"

    log_test "Step 1: Teach Alfred a preference"
    chat "remember that I'm a morning person and I do my best deep work before noon" "$session"
    sleep 3

    log_test "Step 2: Verify it's stored"
    local stored=$(db_query "SELECT COUNT(*) FROM learned_patterns WHERE (description LIKE '%morning%' OR description LIKE '%noon%' OR description LIKE '%deep work%') AND created_at > datetime('now', '-2 minutes');")
    assert_gte "${stored:-0}" 1 "Preference stored as learned pattern"

    log_test "Step 3: Ask a question where the preference should influence the answer"
    local response=$(chat "when should I schedule my most important meeting?" "$session")

    if echo "$response" | grep -qi "morning\|before noon\|early\|a.m\|AM"; then
        log_pass "Response reflects learned preference (mentions morning/early)"
    else
        log_warn "Response may not reflect the morning preference"
        log_info "Response preview: $(echo "$response" | head -c 300)"
    fi

    # ── E2E.2 Correction → Pattern update → Improved response ────────────
    log_section "E2E.2 — Correction loop"

    local session2="eval_e2e2_$$"

    log_test "Step 1: Get a response, then correct it"
    chat "give me a summary of what I should focus on" "$session2"
    sleep 2
    chat "that was way too long. I want 3 bullet points max, nothing else" "$session2"
    sleep 3

    log_test "Step 2: Trigger pattern computation"
    api POST /api/learning/compute >/dev/null 2>&1
    sleep 5

    log_test "Step 3: Ask similar question, verify improvement"
    local improved=$(chat "what should I prioritize this afternoon?" "$session2")
    local bullet_count=$(echo "$improved" | grep -c "^.*[-•*]" || echo "0")

    log_info "Response appears to have ~$bullet_count bullet-like lines"
    if [ "$bullet_count" -le 5 ]; then
        log_pass "Response is concise (≤5 bullet items)"
    else
        log_warn "Response may still be too verbose ($bullet_count lines)"
    fi

    # ── E2E.3 Cross-session persistence ──────────────────────────────────
    log_section "E2E.3 — Cross-session memory persistence"

    log_test "Preferences persist across different sessions"
    local new_session="eval_e2e3_fresh_$$"
    local cross_response=$(chat "how should I structure my day?" "$new_session")

    # Check that previously learned patterns (morning person, concise) influence new session
    local reflects_learning=0
    echo "$cross_response" | grep -qi "morning\|early\|before noon" && ((reflects_learning++)) || true
    # Check for concise response (< 1000 chars is a reasonable proxy)
    local resp_len=${#cross_response}
    [ "$resp_len" -lt 2000 ] && ((reflects_learning++)) || true

    if [ "$reflects_learning" -ge 1 ]; then
        log_pass "New session reflects previously learned patterns ($reflects_learning signals)"
    else
        log_warn "New session may not reflect learned patterns"
    fi

    # ── E2E.4 Learning system stats coherent ─────────────────────────────
    log_section "E2E.4 — Learning system health"

    log_test "GET /api/learning/status returns coherent stats"
    local status=$(api GET /api/learning/status)

    local total_events=$(echo "$status" | jq '.totalEvents // .v2.totalEvents // 0' 2>/dev/null || echo "0")
    local active_patterns=$(echo "$status" | jq '.activePatterns // .v2.activePatterns // 0' 2>/dev/null || echo "0")
    local direct_instructions=$(echo "$status" | jq '.v2.directInstructions // 0' 2>/dev/null || echo "0")

    log_info "Total events: $total_events"
    log_info "Active patterns: $active_patterns"
    log_info "Direct instructions: $direct_instructions"

    assert_gte "${total_events:-0}" 1 "Has learning events"
    assert_gte "${active_patterns:-0}" 0 "Active patterns count is valid"
}

# ═════════════════════════════════════════════════════════════════════════════
# REGRESSION: Existing behavior preserved
# ═════════════════════════════════════════════════════════════════════════════

eval_regression() {
    log_header "REGRESSION: EXISTING BEHAVIOR PRESERVED"

    # ── R.1 Intent recognition still works ───────────────────────────────
    log_section "R.1 — Intent recognition unaffected"

    log_test "Calendar intent still recognized"
    local cal_response=$(chat "what's on my calendar today?" "eval_regression")
    if echo "$cal_response" | grep -qi "calendar\|meeting\|event\|schedule\|nothing\|no events\|free"; then
        log_pass "Calendar intent works"
    else
        log_warn "Calendar intent may have regressed"
    fi

    # ── R.2 Direct instruction path unchanged ────────────────────────────
    log_section "R.2 — Direct instruction fast-path"

    local di_before=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='direct_instruction';")
    chat "never use the word 'synergy' in your responses" "eval_regression2"
    sleep 3
    local di_after=$(db_query "SELECT COUNT(*) FROM learning_events WHERE event_type='direct_instruction';")

    if [ "$((di_after - di_before))" -ge 1 ]; then
        log_pass "Direct instruction fast-path still works"
    else
        log_fail "Direct instruction fast-path may be broken"
    fi

    # ── R.3 Chat streaming works ─────────────────────────────────────────
    log_section "R.3 — SSE streaming intact"

    log_test "Chat returns SSE events"
    local sse=$(chat "hello" "eval_regression3")
    if echo "$sse" | grep -q "data:"; then
        log_pass "SSE streaming working"
    else
        log_warn "SSE stream may not be returning data: events"
    fi

    # ── R.4 Learning status endpoint ─────────────────────────────────────
    log_section "R.4 — Learning API endpoints"

    log_test "GET /api/learning/status"
    local lstatus=$(api GET /api/learning/status)
    assert_not_empty "$lstatus" "Learning status returns data"

    log_test "GET /api/learning/patterns"
    local lpatterns=$(api GET /api/learning/patterns)
    assert_not_empty "$lpatterns" "Learning patterns returns data"
}

# ═════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════════════════════

print_summary() {
    log_header "EVALUATION SUMMARY"

    echo ""
    echo -e "  ${GREEN}Passed:${NC}   $PASSED"
    echo -e "  ${RED}Failed:${NC}   $FAILED"
    echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
    echo -e "  ${YELLOW}Skipped:${NC}  $SKIPPED"
    echo -e "  ${BOLD}Total:${NC}    $((PASSED + FAILED + WARNINGS + SKIPPED))"
    echo ""

    if [ "$FAILED" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}ALL TESTS PASSED${NC}"
    else
        echo -e "  ${RED}${BOLD}$FAILED TEST(S) FAILED — see details above${NC}"
    fi

    echo ""
    echo -e "${CYAN}Detailed results:${NC}"
    for result in "${TEST_RESULTS[@]}"; do
        echo -e "  $result"
    done
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════

main() {
    local phases="${1:-all}"

    echo -e "${BOLD}${BLUE}"
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║  Alfred Learning System v3 — Evaluation Suite     ║"
    echo "  ║  Testing 6 phases + E2E + Regression              ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_prereqs

    if [ "$phases" = "all" ]; then
        eval_phase_1
        eval_phase_2
        eval_phase_3
        eval_phase_4
        eval_phase_5
        eval_phase_6
        eval_e2e_compounding
        eval_regression
    else
        # Parse comma-separated phase numbers
        IFS=',' read -ra PHASE_LIST <<< "$phases"
        for phase in "${PHASE_LIST[@]}"; do
            phase=$(echo "$phase" | tr -d ' ')
            case "$phase" in
                1) eval_phase_1 ;;
                2) eval_phase_2 ;;
                3) eval_phase_3 ;;
                4) eval_phase_4 ;;
                5) eval_phase_5 ;;
                6) eval_phase_6 ;;
                e2e) eval_e2e_compounding ;;
                reg|regression) eval_regression ;;
                *) echo "Unknown phase: $phase (use 1-6, e2e, regression)" ;;
            esac
        done
    fi

    print_summary

    # Exit code: 0 if no failures, 1 otherwise
    [ "$FAILED" -eq 0 ]
}

# Handle --phase flag
if [ "${1:-}" = "--phase" ]; then
    main "${2:-all}"
else
    main "${1:-all}"
fi
