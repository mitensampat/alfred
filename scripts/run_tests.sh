#!/bin/bash
#
# Alfred Comprehensive Test Runner
# Usage: ./scripts/run_tests.sh [quick|full|stress|all]
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
BASE_URL="${ALFRED_URL:-http://localhost:8080}"
PASSCODE="${ALFRED_PASSCODE:-$(cat ~/.config/alfred/config.json 2>/dev/null | jq -r '.api.passcode // empty')}"
TOKEN=""

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# Helper functions
print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_test() {
    echo -e "  Testing: $1"
}

pass() {
    echo -e "    ${GREEN}✓ PASS${NC}: $1"
    ((PASSED++))
}

fail() {
    echo -e "    ${RED}✗ FAIL${NC}: $1"
    ((FAILED++))
}

skip() {
    echo -e "    ${YELLOW}○ SKIP${NC}: $1"
    ((SKIPPED++))
}

get_token() {
    if [ -z "$PASSCODE" ]; then
        echo -e "${RED}Error: No passcode found. Set ALFRED_PASSCODE or check config.${NC}"
        exit 1
    fi

    TOKEN=$(curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"passcode\":\"$PASSCODE\"}" \
        "$BASE_URL/api/auth/login" 2>/dev/null | jq -r '.token // empty')

    if [ -z "$TOKEN" ]; then
        echo -e "${RED}Error: Failed to authenticate${NC}"
        exit 1
    fi
}

auth_curl() {
    curl -s -m 10 -H "Authorization: Bearer $TOKEN" "$@"
}

check_server() {
    if ! curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/" 2>/dev/null | grep -q "200"; then
        echo -e "${RED}Error: Server not running at $BASE_URL${NC}"
        echo "Start with: alfred server or alfred menubar"
        exit 1
    fi
}

# ============================================================================
# TEST SUITES
# ============================================================================

test_auth() {
    print_header "Authentication Tests"

    # Test 1: Valid login
    print_test "Valid login"
    response=$(curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"passcode\":\"$PASSCODE\"}" \
        "$BASE_URL/api/auth/login")
    if echo "$response" | jq -e '.token' > /dev/null 2>&1; then
        pass "Login returns token"
    else
        fail "Login did not return token"
    fi

    # Test 2: Invalid login
    print_test "Invalid login"
    response=$(curl -s -X POST -H "Content-Type: application/json" \
        -d '{"passcode":"wrongpasscode"}' \
        "$BASE_URL/api/auth/login")
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        pass "Invalid login rejected"
    else
        fail "Invalid login not rejected"
    fi

    # Test 3: Session validation
    print_test "Session validation"
    response=$(auth_curl "$BASE_URL/api/auth/validate")
    if echo "$response" | jq -e '.valid == true' > /dev/null 2>&1; then
        pass "Session is valid"
    else
        fail "Session validation failed"
    fi

    # Test 4: Invalid token
    print_test "Invalid token rejection"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer invalid-token" \
        "$BASE_URL/api/health")
    if [ "$code" == "401" ]; then
        pass "Invalid token rejected with 401"
    else
        fail "Invalid token returned $code instead of 401"
    fi

    # Test 5: Logout
    print_test "Logout"
    response=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/auth/logout")
    if echo "$response" | jq -e '.success == true' > /dev/null 2>&1; then
        pass "Logout successful"
        # Re-authenticate for remaining tests
        get_token
    else
        fail "Logout failed"
    fi
}

test_health() {
    print_header "Health & System Tests"

    # Test 1: Health endpoint
    print_test "Health endpoint"
    response=$(auth_curl "$BASE_URL/api/health")
    if echo "$response" | jq -e '.status == "ok"' > /dev/null 2>&1; then
        pass "Health check OK"
    else
        fail "Health check failed"
    fi
}

test_briefing() {
    print_header "Daily Briefing Tests"

    # Test 1: Briefing endpoint
    print_test "Briefing endpoint (today)"
    today=$(date +%Y-%m-%d)
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/briefing?date=$today")
    if [ "$code" == "200" ]; then
        pass "Briefing endpoint returns 200"
    else
        fail "Briefing endpoint returned $code"
    fi

    # Test 2: Briefing content
    print_test "Briefing content"
    response=$(auth_curl "$BASE_URL/api/briefing?date=$today" -m 30)
    if [ -n "$response" ] && [ "$response" != "null" ]; then
        pass "Briefing returns content"
    else
        fail "Briefing returns empty"
    fi
}

test_calendar() {
    print_header "Calendar Tests"

    # Test 1: Calendar endpoint
    print_test "Calendar endpoint"
    today=$(date +%Y-%m-%d)
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/calendar?date=$today")
    if [ "$code" == "200" ]; then
        pass "Calendar endpoint returns 200"
    else
        fail "Calendar endpoint returned $code"
    fi

    # Test 2: Calendar with filter
    print_test "Calendar with filter (personal)"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/calendar?calendar=personal&date=$today")
    if [ "$code" == "200" ]; then
        pass "Filtered calendar returns 200"
    else
        fail "Filtered calendar returned $code"
    fi
}

test_commitments() {
    print_header "Commitments Tests"

    # Test 1: Get commitments
    print_test "Get commitments"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/commitments")
    if [ "$code" == "200" ]; then
        pass "Commitments endpoint returns 200"
    else
        fail "Commitments endpoint returned $code"
    fi

    # Test 2: Overdue commitments
    print_test "Overdue commitments"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/commitments/overdue")
    if [ "$code" == "200" ]; then
        pass "Overdue endpoint returns 200"
    else
        fail "Overdue endpoint returned $code"
    fi

    # Test 3: Filter by type
    print_test "Filter commitments by type"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/commitments?type=i_owe")
    if [ "$code" == "200" ]; then
        pass "Filtered commitments returns 200"
    else
        fail "Filtered commitments returned $code"
    fi
}

test_messages() {
    print_header "Messages Tests"

    # Test 1: Messages endpoint
    print_test "Messages endpoint"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/messages?platform=whatsapp&timeframe=7d")
    if [ "$code" == "200" ]; then
        pass "Messages endpoint returns 200"
    else
        fail "Messages endpoint returned $code"
    fi
}

test_attention() {
    print_header "Attention Check Tests"

    # Test 1: Attention check
    print_test "Attention check endpoint"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/attention-check" -m 30)
    if [ "$code" == "200" ]; then
        pass "Attention check returns 200"
    else
        fail "Attention check returned $code"
    fi
}

test_work_patterns() {
    print_header "Work Patterns Tests"

    # Test 1: Get stats
    print_test "Work patterns stats"
    response=$(auth_curl "$BASE_URL/api/task-lifecycle/stats")
    if echo "$response" | jq -e '.totalTasks' > /dev/null 2>&1; then
        total=$(echo "$response" | jq '.totalTasks')
        pass "Stats returned (total tasks: $total)"
    else
        fail "Stats endpoint failed"
    fi

    # Test 2: Get changes
    print_test "Work patterns changes"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/task-lifecycle/changes")
    if [ "$code" == "200" ]; then
        pass "Changes endpoint returns 200"
    else
        fail "Changes endpoint returned $code"
    fi

    # Test 3: Get counterparties
    print_test "Work patterns counterparties"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/task-lifecycle/counterparties")
    if [ "$code" == "200" ]; then
        pass "Counterparties endpoint returns 200"
    else
        fail "Counterparties endpoint returned $code"
    fi
}

test_settings() {
    print_header "Settings Tests"

    # Test 1: Get scheduled config
    print_test "Scheduled config"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/config/scheduled")
    if [ "$code" == "200" ]; then
        pass "Scheduled config returns 200"
    else
        fail "Scheduled config returned $code"
    fi

    # Test 2: Get Notion config
    print_test "Notion config"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/config/notion")
    if [ "$code" == "200" ]; then
        pass "Notion config returns 200"
    else
        fail "Notion config returned $code"
    fi
}

test_recent_activity() {
    print_header "Recent Activity Tests"

    # Test 1: Get recent activity
    print_test "Recent activity"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/recent-activity")
    if [ "$code" == "200" ]; then
        pass "Recent activity returns 200"
    else
        fail "Recent activity returned $code"
    fi
}

test_error_handling() {
    print_header "Error Handling Tests"

    # Test 1: Invalid endpoint
    print_test "Invalid endpoint (404)"
    response=$(auth_curl "$BASE_URL/api/nonexistent")
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        pass "Invalid endpoint returns error JSON"
    else
        fail "Invalid endpoint did not return error"
    fi

    # Test 2: Invalid JSON body
    print_test "Malformed JSON"
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "not json" \
        -X POST "$BASE_URL/api/query")
    if [ "$code" == "400" ] || [ "$code" == "200" ]; then
        pass "Malformed JSON handled gracefully"
    else
        fail "Malformed JSON returned unexpected code: $code"
    fi
}

test_concurrent() {
    print_header "Concurrent Request Tests"

    # Test 1: Concurrent requests
    print_test "10 concurrent requests"
    for i in {1..10}; do
        auth_curl "$BASE_URL/api/health" > /dev/null &
    done
    wait

    # Check server still running
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/")
    if [ "$code" == "200" ]; then
        pass "Server survived 10 concurrent requests"
    else
        fail "Server crashed or unavailable"
    fi

    # Test 2: 50 rapid requests
    print_test "50 rapid requests"
    for i in {1..50}; do
        curl -s -o /dev/null "$BASE_URL/" &
    done
    wait

    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/")
    if [ "$code" == "200" ]; then
        pass "Server survived 50 rapid requests"
    else
        fail "Server crashed under load"
    fi
}

test_cli() {
    print_header "CLI Tests"

    ALFRED_BIN="${ALFRED_BIN:-$(which alfred 2>/dev/null || echo "./.build/debug/alfred")}"

    if [ ! -f "$ALFRED_BIN" ]; then
        skip "Alfred binary not found at $ALFRED_BIN"
        return
    fi

    # Test 1: Help
    print_test "alfred --help"
    if $ALFRED_BIN --help > /dev/null 2>&1; then
        pass "Help command works"
    else
        fail "Help command failed"
    fi

    # Test 2: Agents
    print_test "alfred agents"
    if $ALFRED_BIN agents > /dev/null 2>&1; then
        pass "Agents command works"
    else
        fail "Agents command failed"
    fi
}

stress_test() {
    print_header "Stress Tests"

    # Test 1: 100 sequential requests
    print_test "100 sequential requests"
    success=0
    for i in {1..100}; do
        code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/")
        if [ "$code" == "200" ]; then
            ((success++))
        fi
    done
    if [ "$success" -eq 100 ]; then
        pass "All 100 sequential requests succeeded"
    else
        fail "$success/100 requests succeeded"
    fi

    # Test 2: 100 concurrent requests
    print_test "100 concurrent requests"
    for i in {1..100}; do
        curl -s -o /dev/null "$BASE_URL/" &
    done
    wait

    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/")
    if [ "$code" == "200" ]; then
        pass "Server survived 100 concurrent requests"
    else
        fail "Server crashed under heavy load"
    fi

    # Test 3: Memory check
    print_test "Memory usage"
    pid=$(pgrep -f "alfred" | head -1)
    if [ -n "$pid" ]; then
        mem=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print int($1/1024)}')
        if [ "$mem" -lt 500 ]; then
            pass "Memory usage: ${mem}MB (under 500MB)"
        else
            fail "Memory usage: ${mem}MB (exceeds 500MB)"
        fi
    else
        skip "Cannot find alfred process"
    fi
}

# ============================================================================
# MAIN
# ============================================================================

print_summary() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  TEST SUMMARY${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}Passed:${NC}  $PASSED"
    echo -e "  ${RED}Failed:${NC}  $FAILED"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED"
    echo ""

    total=$((PASSED + FAILED))
    if [ "$FAILED" -eq 0 ]; then
        echo -e "  ${GREEN}All tests passed!${NC}"
    else
        pct=$((PASSED * 100 / total))
        echo -e "  ${YELLOW}Pass rate: ${pct}%${NC}"
    fi
    echo ""
}

run_quick() {
    test_auth
    test_health
    test_work_patterns
    test_settings
}

run_full() {
    test_auth
    test_health
    test_briefing
    test_calendar
    test_commitments
    test_messages
    test_attention
    test_work_patterns
    test_settings
    test_recent_activity
    test_error_handling
    test_concurrent
    test_cli
}

run_stress() {
    stress_test
}

run_all() {
    run_full
    run_stress
}

# Parse arguments
MODE="${1:-quick}"

echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           ALFRED COMPREHENSIVE TEST RUNNER                     ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Server: $BASE_URL"
echo "  Mode:   $MODE"
echo ""

# Check server is running
check_server

# Authenticate
get_token
echo -e "  ${GREEN}✓ Authenticated${NC}"

# Run tests based on mode
case "$MODE" in
    quick)
        run_quick
        ;;
    full)
        run_full
        ;;
    stress)
        run_stress
        ;;
    all)
        run_all
        ;;
    *)
        echo "Usage: $0 [quick|full|stress|all]"
        exit 1
        ;;
esac

print_summary

# Exit with appropriate code
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
