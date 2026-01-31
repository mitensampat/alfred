# Alfred Comprehensive Test Plan

## Overview

This document outlines end-to-end testing for the Alfred application across all interfaces:
- **GUI** (Web UI at localhost:8080)
- **CLI** (Command line interface)
- **Menu Bar** (macOS menu bar app)

---

## Prerequisites

### Environment Setup
- [ ] Alfred binary built: `swift build`
- [ ] Config file exists: `~/.config/alfred/config.json`
- [ ] Google Calendar authenticated: `alfred auth`
- [ ] Notion API configured (if using Notion features)
- [ ] Full Disk Access granted (for iMessage features)

### Test Credentials
- Passcode: Check `~/.config/alfred/config.json` > `api.passcode`
- Port: Default 8080 (configurable in config)

---

## 1. Login Screen

### GUI Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 1.1 Login success | 1. Open http://localhost:8080 <br> 2. Enter correct passcode <br> 3. Click "Let's go" | Redirects to main dashboard |
| 1.2 Login failure | 1. Enter incorrect passcode <br> 2. Click "Let's go" | Shows error message, stays on login |
| 1.3 Empty passcode | 1. Leave passcode blank <br> 2. Click "Let's go" | Shows validation error |
| 1.4 Session persistence | 1. Login successfully <br> 2. Refresh page | Stays logged in (within 24h) |
| 1.5 Session expiration | 1. Login <br> 2. Wait 24+ hours <br> 3. Refresh | Returns to login screen |

### API Tests
```bash
# 1.1 Valid login
curl -X POST -H "Content-Type: application/json" \
  -d '{"passcode":"YOUR_PASSCODE"}' \
  http://localhost:8080/api/auth/login
# Expected: {"success":true,"token":"...","expiresAt":"..."}

# 1.2 Invalid login
curl -X POST -H "Content-Type: application/json" \
  -d '{"passcode":"wrong"}' \
  http://localhost:8080/api/auth/login
# Expected: {"error":"Invalid passcode"}

# 1.3 Validate session
curl -H "Authorization: Bearer TOKEN" \
  http://localhost:8080/api/auth/validate
# Expected: {"valid":true}
```

---

## 2. Logout Button

### GUI Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 2.1 Logout success | 1. While logged in, click logout icon (top right) | Returns to login screen |
| 2.2 Session invalidated | 1. Logout <br> 2. Try to access /api/health with old token | Returns 401 Unauthorized |

### API Tests
```bash
# 2.1 Logout
curl -X POST -H "Authorization: Bearer TOKEN" \
  http://localhost:8080/api/auth/logout
# Expected: {"success":true}
```

---

## 3. Daily Briefings

### GUI Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 3.1 Generate today's briefing | 1. Click "Daily Briefing" <br> 2. Select "Today" <br> 3. Wait for response | Shows schedule, messages summary, action items |
| 3.2 Generate tomorrow's briefing | 1. Click "Daily Briefing" <br> 2. Select "Tomorrow" | Shows tomorrow's schedule |
| 3.3 Custom date briefing | 1. Click "Daily Briefing" <br> 2. Select specific date | Shows briefing for selected date |
| 3.4 Briefing with no meetings | Test on a day with no calendar events | Shows "No meetings scheduled" or similar |
| 3.5 Briefing streaming | Watch response load | Content streams progressively |

### CLI Tests
```bash
# 3.1 Today's briefing
alfred briefing

# 3.2 Tomorrow's briefing
alfred briefing tomorrow

# 3.3 Specific date
alfred briefing 2026-02-01

# 3.4 Relative date
alfred briefing +2

# 3.5 With notification
alfred briefing tomorrow --notify
```

### API Tests
```bash
# 3.1 Get briefing
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/briefing?date=2026-01-31"

# 3.2 Stream briefing
curl -H "Authorization: Bearer TOKEN" \
  -H "Accept: text/event-stream" \
  "http://localhost:8080/api/briefing/stream?date=2026-01-31"
```

---

## 4. Calendar

### GUI Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 4.1 All calendars today | 1. Click "Calendar" <br> 2. Select "All" <br> 3. Select "Today" | Shows events from all calendars |
| 4.2 Personal calendar | 1. Select "Personal" calendar | Shows only personal events |
| 4.3 Work calendar | 1. Select "Work" calendar | Shows only work events |
| 4.4 Tomorrow's calendar | 1. Select "Tomorrow" | Shows tomorrow's events |
| 4.5 Empty day | Test on day with no events | Shows "No events" message |

### CLI Tests
```bash
# 4.1 All calendars
alfred calendar

# 4.2 Personal calendar
alfred calendar personal

# 4.3 Work calendar
alfred calendar work

# 4.4 Tomorrow
alfred calendar tomorrow

# 4.5 Specific date
alfred calendar personal 2026-02-01

# 4.6 All calendars specific date
alfred calendar all +3
```

### API Tests
```bash
# 4.1 All calendars
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/calendar"

# 4.2 Specific calendar and date
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/calendar?calendar=personal&date=2026-02-01"
```

---

## 5. Commitments

### GUI Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 5.1 View all commitments | 1. Click "Commitments" <br> 2. Select "View all" | Lists all tracked commitments |
| 5.2 Filter by "I owe" | Filter to show only outgoing commitments | Shows commitments you made |
| 5.3 Filter by "They owe" | Filter to show incoming commitments | Shows commitments others made to you |
| 5.4 Check specific person | 1. Enter contact name <br> 2. Select timeframe | Shows commitments with that person |
| 5.5 Commitment details | Click on a commitment | Shows full details, context |

### CLI Tests
```bash
# 5.1 Setup (first time)
alfred commitments init

# 5.2 Scan for commitments
alfred commitments scan

# 5.3 Scan specific contact
alfred commitments scan "John Smith" 14d

# 5.4 List all
alfred commitments list

# 5.5 Filter by type
alfred commitments list i_owe
alfred commitments list they_owe

# 5.6 Overdue commitments
alfred commitments overdue
```

### API Tests
```bash
# 5.1 Get all commitments
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/commitments"

# 5.2 Filter by type
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/commitments?type=i_owe"

# 5.3 Get overdue
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/commitments/overdue"

# 5.4 Scan for commitments
curl -X POST -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"contactName":"John","lookbackDays":7}' \
  "http://localhost:8080/api/commitments/scan"
```

---

## 6. Messages & Todo Scanner

### GUI Tests - Messages
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 6.1 WhatsApp messages | 1. Click "Messages" <br> 2. Enter contact name <br> 3. Select WhatsApp, 7d | Shows message summary |
| 6.2 iMessage messages | Select iMessage platform | Shows iMessage summary |
| 6.3 Different timeframes | Test 1d, 3d, 7d, 14d | Shows appropriate time range |
| 6.4 No messages found | Search for non-existent contact | Shows "No messages found" |
| 6.5 Streaming response | Watch message analysis load | Content streams progressively |

### GUI Tests - Todo Scanner
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 6.6 Scan todos 7d | 1. Click "Scan Todos" <br> 2. Select 7d lookback | Shows extracted todos |
| 6.7 Scan todos 1d | Select 1d lookback | Shows recent todos only |
| 6.8 Todo extraction | Verify extraction quality | Todos match WhatsApp messages to self |
| 6.9 Add to Notion | 1. Select todos <br> 2. Click "Add to Notion" | Creates Notion tasks |

### CLI Tests
```bash
# 6.1 All messages summary
alfred messages

# 6.2 Platform specific
alfred messages whatsapp
alfred messages imessage

# 6.3 With timeframe
alfred messages whatsapp 24h
alfred messages imessage 7d

# 6.4 Specific contact
alfred messages whatsapp "Family Group" 7d

# 6.5 Process WhatsApp todos
alfred notion-todos

# 6.6 Test Notion integration
alfred test-notion
```

### API Tests
```bash
# 6.1 Messages summary
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/messages?platform=whatsapp&timeframe=7d"

# 6.2 Message summary for contact
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/messages/summary?contact=John&platform=whatsapp&timeframe=7d"

# 6.3 Scan todos
curl -X POST -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"lookbackDays":7}' \
  "http://localhost:8080/api/todos/scan"

# 6.4 Extract todos
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/extract/todos?lookbackDays=7"
```

---

## 7. Attention Check

### GUI Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 7.1 Generate report | 1. Click "Attention Check" | Shows attention defense report |
| 7.2 Report content | Verify report sections | Has calendar analysis, messaging analysis |
| 7.3 Recommendations | Check for action items | Shows prioritization suggestions |

### CLI Tests
```bash
# 7.1 Default report
alfred attention

# 7.2 Initialize preferences
alfred attention init

# 7.3 Full report
alfred attention report

# 7.4 Calendar only
alfred attention calendar

# 7.5 Messaging only
alfred attention messaging

# 7.6 Specific period
alfred attention report both week
alfred attention report both 14

# 7.7 Generate plan
alfred attention plan 7

# 7.8 Collect priorities
alfred attention priorities

# 7.9 With notification
alfred attention --notify
```

### API Tests
```bash
# 7.1 Attention check
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/attention-check"
```

---

## 8. Work Patterns (and Learning)

### GUI Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 8.1 View stats | 1. Click "Work Patterns" | Shows task completion stats |
| 8.2 Scan for changes | Click "Scan for Changes" | Updates stats, shows "Scanning..." |
| 8.3 Completion rate | Check completion rate stat | Shows percentage |
| 8.4 Overdue rate | Check overdue rate | Shows percentage |
| 8.5 Last scan time | Check "Last scanned" | Shows relative time |
| 8.6 Collaborator insights | View collaborator section | Shows task patterns by person |
| 8.7 Teach Alfred | 1. Enter rule <br> 2. Click submit | Confirms rule added |
| 8.8 View memory | Click "Alfred's Memory" | Shows learned patterns |

### CLI Tests
```bash
# 8.1 View all agents
alfred agents

# 8.2 View agent memory
alfred agents memory communication
alfred agents memory task

# 8.3 View agent skills
alfred agents skills communication

# 8.4 Forget pattern
alfred agents forget communication "some pattern"

# 8.5 Consolidate learnings
alfred agents consolidate

# 8.6 Agent status
alfred agents status

# 8.7 Teach agent
alfred teach communication "Be formal with investors"
alfred teach task "Friday afternoons are for deep work"

# 8.8 Agent digest
alfred digest
```

### API Tests
```bash
# 8.1 Get stats
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/task-lifecycle/stats"

# 8.2 Scan for changes
curl -X POST -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/task-lifecycle/scan"

# 8.3 Get changes
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/task-lifecycle/changes"

# 8.4 Get counterparties
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/task-lifecycle/counterparties"

# 8.5 Record correction (learning)
curl -X POST -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"itemType":"commitment","feedback":"false_positive"}' \
  "http://localhost:8080/api/corrections"
```

---

## 9. Settings

### GUI Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 9.1 Open settings | Click settings icon | Shows settings panel |
| 9.2 Scheduled emails - enable | Toggle briefing email on | Saves preference |
| 9.3 Scheduled emails - time | Set briefing time to 8:00 AM | Saves time |
| 9.4 Scheduled emails - email | Enter email address | Saves email |
| 9.5 Notion config | Enter Notion database ID | Saves and validates |
| 9.6 Change passcode | 1. Enter current <br> 2. Enter new <br> 3. Confirm | Passcode updated |
| 9.7 Invalid passcode change | Enter wrong current passcode | Shows error |
| 9.8 Mismatched passcode | New and confirm don't match | Shows error |
| 9.9 Clear cache | Click "Clear All Cache" | Cache cleared confirmation |

### API Tests
```bash
# 9.1 Get scheduled config
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/config/scheduled"

# 9.2 Update scheduled config
curl -X POST -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"briefing":{"enabled":true,"time":"08:00"},"email":"user@example.com"}' \
  "http://localhost:8080/api/config/scheduled"

# 9.3 Get Notion config
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/config/notion"

# 9.4 Update Notion config
curl -X POST -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"databaseId":"xxx-xxx-xxx"}' \
  "http://localhost:8080/api/config/notion"

# 9.5 Change passcode
curl -X POST -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"newPasscode":"12345678"}' \
  "http://localhost:8080/api/config/passcode"

# 9.6 Clear cache
curl -X POST -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/cache/clear"
```

---

## 10. Recent Activity

### GUI Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 10.1 View activity | Scroll to Recent Activity section | Shows list of recent API calls |
| 10.2 Activity details | Click on an activity | Shows parameters used |
| 10.3 Rerun activity | Click rerun button | Reruns the API call |
| 10.4 Delete activity | Click delete on an item | Removes from list |
| 10.5 Activity persistence | 1. Perform actions <br> 2. Refresh page | Activities still visible |

### API Tests
```bash
# 10.1 Get recent activity
curl -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/recent-activity"

# 10.2 Delete activity
curl -X DELETE -H "Authorization: Bearer TOKEN" \
  "http://localhost:8080/api/recent-activity/delete?id=xxx"
```

---

## 11. Menu Bar App

### Menu Bar Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 11.1 App launches | Run `alfred menubar` | Hat icon appears in menu bar |
| 11.2 Icon color | Server running vs stopped | Gold band when running, darker when stopped |
| 11.3 Menu opens | Click hat icon | Menu dropdown appears |
| 11.4 Status display | View menu | Shows "Server Running" or "Server Stopped" |
| 11.5 Port display | View menu when running | Shows "Port: 8080" |
| 11.6 Start server | Click "Start Server" | Server starts, status updates |
| 11.7 Stop server | Click "Stop Server" | Server stops, status updates |
| 11.8 Open Web UI | Click "Open Web UI" | Browser opens to localhost |
| 11.9 Copy URL | Click "Copy URL" | URL copied to clipboard |
| 11.10 Open Config | Click "Open Config Folder" | Finder opens ~/.config/alfred |
| 11.11 Quit | Click "Quit Alfred" | App exits cleanly |
| 11.12 Keyboard shortcuts | Press ⌘S, ⌘O, ⌘Q etc | Actions trigger correctly |

### CLI Launch Tests
```bash
# 11.1 Start menu bar app
alfred menubar

# 11.2 Start headless server
alfred server

# 11.3 Start with specific port
alfred server --port 8081

# 11.4 Install and restart
alfred install
```

---

## 12. Error Handling & Edge Cases

### Error Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 12.1 Invalid endpoint | Request /api/nonexistent | Returns 404 with error JSON |
| 12.2 Invalid auth | Use expired/invalid token | Returns 401 Unauthorized |
| 12.3 Malformed JSON | POST invalid JSON body | Returns 400 Bad Request |
| 12.4 Missing params | Omit required parameters | Returns descriptive error |
| 12.5 Server unavailable | Stop server, make request | Browser shows connection error |
| 12.6 Long query | Submit very long input | Handles gracefully |
| 12.7 Special characters | Use emojis, unicode | Handles correctly |
| 12.8 Concurrent requests | Fire 10+ parallel requests | All complete without crash |

### Edge Cases
| Test | Steps | Expected Result |
|------|-------|-----------------|
| 12.9 No calendar events | Check day with no events | Graceful "no events" message |
| 12.10 No messages | Search contact with no messages | Graceful "no messages" message |
| 12.11 No commitments | View when no commitments exist | Empty state UI |
| 12.12 Large response | Generate briefing with many events | Handles streaming correctly |
| 12.13 Offline calendar | Disconnect network, check calendar | Appropriate error |
| 12.14 Stale token | Use token after logout | Returns 401 |

---

## 13. Performance Tests

| Test | Steps | Expected Result |
|------|-------|-----------------|
| 13.1 Page load time | Measure time to load main page | < 2 seconds |
| 13.2 API response time | Measure /api/health response | < 100ms |
| 13.3 Briefing generation | Measure full briefing time | < 30 seconds |
| 13.4 Memory usage | Monitor after 1 hour running | Stable, no leaks |
| 13.5 Concurrent load | 50 parallel requests | All succeed, no crash |

---

## 14. Integration Tests

| Test | Steps | Expected Result |
|------|-------|-----------------|
| 14.1 Calendar + Briefing | Generate briefing with calendar events | Events appear in briefing |
| 14.2 Messages + Commitments | Scan commitments from messages | Commitments extracted correctly |
| 14.3 Todos + Notion | Scan todos, add to Notion | Tasks created in Notion |
| 14.4 Learning + Extraction | Teach rule, verify extraction uses it | Rule affects extractions |
| 14.5 Settings + Scheduled | Change time, verify schedule updates | Scheduled tasks use new time |

---

## Test Execution Checklist

### Pre-Test Setup
- [ ] Build latest: `swift build`
- [ ] Start server: `alfred menubar` or `alfred server`
- [ ] Note passcode from config
- [ ] Open browser to http://localhost:8080

### Quick Smoke Test (5 minutes)
- [ ] Login works
- [ ] Daily briefing generates
- [ ] Calendar shows events
- [ ] Logout works
- [ ] Menu bar controls work

### Full Regression (30-60 minutes)
- [ ] All login/logout tests
- [ ] All briefing tests
- [ ] All calendar tests
- [ ] All commitment tests
- [ ] All message tests
- [ ] All attention tests
- [ ] All work patterns tests
- [ ] All settings tests
- [ ] All recent activity tests
- [ ] All menu bar tests
- [ ] Error handling tests

### Weekly Deep Test
- [ ] Performance tests
- [ ] Integration tests
- [ ] Edge case tests
- [ ] Memory leak check

---

## Automated Test Scripts

### Health Check Script
```bash
#!/bin/bash
# health_check.sh - Quick system health check

PASSCODE="YOUR_PASSCODE"
BASE_URL="http://localhost:8080"

# Get token
TOKEN=$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"passcode\":\"$PASSCODE\"}" \
  "$BASE_URL/api/auth/login" | jq -r '.token')

if [ "$TOKEN" == "null" ] || [ -z "$TOKEN" ]; then
  echo "❌ Login failed"
  exit 1
fi
echo "✓ Login successful"

# Test endpoints
for endpoint in "/api/health" "/api/task-lifecycle/stats" "/api/config/scheduled"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE_URL$endpoint")
  if [ "$code" == "200" ]; then
    echo "✓ $endpoint: OK"
  else
    echo "❌ $endpoint: $code"
  fi
done

echo "Health check complete"
```

### Stress Test Script
```bash
#!/bin/bash
# stress_test.sh - Concurrent request stress test

PASSCODE="YOUR_PASSCODE"
BASE_URL="http://localhost:8080"

TOKEN=$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"passcode\":\"$PASSCODE\"}" \
  "$BASE_URL/api/auth/login" | jq -r '.token')

echo "Running 50 concurrent requests..."
for i in {1..50}; do
  curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/health" &
done
wait

if pgrep -f "alfred" > /dev/null; then
  echo "✓ Server survived stress test"
else
  echo "❌ Server crashed"
fi
```

---

## Known Issues & Limitations

1. **Full Disk Access**: iMessage features require manual granting of Full Disk Access
2. **Google Auth**: Calendar requires initial OAuth setup via `alfred auth`
3. **Notion Setup**: Requires API key and database ID configuration
4. **Menu Bar**: Only available on macOS
5. **SSE Streaming**: Some browsers may have connection limits

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-31 | Initial comprehensive test plan |

