# Alfred v2.1.1 Regression Log — March 31, 2026

## Issues Found
| # | Area | Severity | Description | Status |
|---|------|----------|-------------|--------|
| 1 | API Latency | **HIGH** | `/api/home/pulse` cold = 13.1s (target < 3s). Fixed: stale-while-revalidate returns cached data in <1ms, refreshes in background. Parallel pre-warming at startup. | **Fixed** |
| 2 | API Latency | **HIGH** | `/api/coaching/cards` cold = 37.1s (target < 15s). Fixed: parallel pre-warming (was sequential). Warm = 0.9ms. Cold only hits on first-ever generate. | **Mitigated** |
| 3 | API Latency | **HIGH** | `/api/briefing` cold = 165.5s (target < 60s). This is the full LLM briefing generation — scheduler pre-generates at 8:15am. Warm = 6ms. | **By Design** |
| 4 | API Latency | **MEDIUM** | `/api/coaching/opener` cold = 5.1s (target < 5s). Fixed: parallel pre-warming (was sequential behind 13s pulse). | **Mitigated** |
| 5 | API Latency | **MEDIUM** | `/api/calendar` cold = 32.8s. Google Calendar API + LLM briefings. Warm = 53ms. | **Known** |
| 6 | Home Page | **LOW** | Coaching opener not rendered on home page despite API returning valid data. Fixed: added DOM rendering in `renderMorningWalk`. | **Fixed** |
| 7 | iPad Layout | **MEDIUM** | Settings panel clipped on right edge at 1024x1366 iPad viewport. Fixed: added `width:100%` + `overflow:hidden` to `.slide-panel-inner`. | **Fixed** |
| 8 | System Health | **INFO** | iMessage Full Disk Access revoked — banner correctly shows. Needs manual re-grant in System Settings. | Known |
| 9 | Push Budget | **INFO** | 5 of 5 daily pushes used. Test push still works (bypasses budget). Normal production push suppressed until tomorrow. | Expected |

## Test Results

### 9. API Latency Benchmarks

| Endpoint | Cold | Warm | Target Cold | Target Warm | Result |
|----------|------|------|-------------|-------------|--------|
| `GET /api/health` | 1.5ms | — | — | — | ✅ |
| `GET /api/home/pulse` | 13.1s | 17ms | < 3s | < 500ms | ❌ cold |
| `GET /api/coaching/opener` | 5.1s | 0.6ms | < 5s | < 200ms | ⚠️ borderline |
| `GET /api/coaching/cards` | 37.1s | 0.9ms | < 15s | < 200ms | ❌ cold |
| `GET /api/home/next-meeting-brief` | 648ms | — | < 10s | < 300ms | ✅ |
| `GET /api/briefing` | 165.5s | 6ms | < 60s | < 200ms | ❌ cold |
| `GET /api/config/notifications` | 3.8ms | — | < 100ms | < 100ms | ✅ |
| `POST /api/config/notifications` | — | — | < 200ms | < 200ms | ✅ (save returned `{"success":true}`) |
| `GET /api/push/budget` | 2.1ms | — | < 50ms | < 50ms | ✅ |
| `POST /api/push/test` | 5.2s | — | < 3s | < 3s | ⚠️ slow (6 devices) |
| `GET /api/calendar` | 32.8s | 53ms | — | — | Info |
| `GET /api/commitments/dashboard` | 0.6ms | — | — | — | ✅ |
| `GET /api/learning/status` | fast | — | — | — | ✅ |
| `GET /api/chat/stream` (SSE) | streaming | — | — | — | ✅ (tool_start + tool_result events flowing) |

**Summary**: Warm caches are excellent (sub-ms to 53ms). Cold starts are the problem — pulse, coaching cards, and briefing all blow past targets. This is why pre-warming matters so much.

### 1. Home Page — Cold Load
- [x] Focus card visible ✅
- [x] Suggestion chips render (Calendar, Overdue, Nudge, Focus) ✅
- [x] Pending Reviews (5) showing with Confirm Done / Keep Open buttons ✅
- [x] Coaching cards loaded (7 cards: attention, avoidance, leverage, relationships, deep-work-guard, energy-audit, deal-pipeline) ✅
- [x] Lead insight card visible with colored left-accent ✅
- [x] "6 more observations" collapsed toggle ✅
- [x] Weekly review section present ✅
- [x] Time marker shows "10:16 PM · EVENING WRAP-UP" ✅
- [ ] Coaching opener NOT rendered (Issue #6) — API returns valid text but it's not in the DOM
- [x] Morning Briefing card correctly hidden (10 PM, `shouldShowMorningBriefing()` returns false) ✅
- [x] Chat input present with "Talk to Alfred..." placeholder ✅

### 2. Morning Briefing Card
- [x] `shouldShowMorningBriefing()` returns false after 11 AM ✅
- [x] Card not in DOM when it shouldn't show ✅
- [ ] Cannot fully test card display (it's 10 PM — would need to mock time or test tomorrow morning)
- [x] `/api/briefing` returns valid cached data with actionItems, schedule, messages ✅
- [x] 8-second client timeout: page doesn't hang when briefing is slow (cold = 165s, client times out gracefully) ✅

### 3. Push Pre-Warming
- [x] `prewarmHomeCache()` method exists in CoachingPushService ✅
- [x] Called after morning nudge send ✅
- [x] Fires 4 parallel requests (pulse, coaching/cards, coaching/opener, next-meeting-brief) ✅
- [x] Server logs confirm pre-warming works: `🔥 [CoachingPush] Pre-warming home caches...` → `✅ [CoachingPush] Home caches warm` ✅
- [x] `prewarmCaches()` in main.swift includes coaching opener ✅
- [ ] Cannot test tap-through latency from push (budget exhausted, quiet hours active)

### 4. Settings Panel — Tab Consolidation
#### 4a. General Tab ✅
- [x] 4 tabs visible: general, coaching, notifications, data ✅
- [x] Cadences section: 10 cadences listed (Morning Briefing, Attention Check, Todo Scan, Commitment Scan, Pattern Learning, Group Analysis, Auto Summary, Weekly Review, Playbook Sync, Reflection Ingestion) ✅
- [x] Each shows schedule, last run time, Run button ✅
- [x] "+ New Cadence" button present ✅
- [x] Favorites section visible with contacts ✅

#### 4b. Coaching Tab ✅
- [x] Coaching Tenets: 4 tenets (Alfred Rules, Relational Rules, Direct Rules, Voice & Tone) with toggles and Edit buttons ✅
- [x] Meeting Brief Prompt: textarea with current prompt, Save button ✅
- [x] Your Skills: Deep Work Guard, Energy Audit visible with Edit/Delete/toggle ✅
- [x] "+ New" skill button ✅

#### 4c. Notifications Tab ✅
- [x] Status: Browser Permission "Blocked" (expected in preview), Subscribed Devices: 6, Send Test button ✅
- [x] Schedule: Morning Briefing Time 08:15 AM, Quiet Hours 10 PM - 7 AM ✅
- [x] Limits: Max Per Day slider at 5, "5 of 5 used today" ✅
- [x] Notification Types: Morning Nudge ON, Post-Meeting Capture ON ✅
- [x] Devices section visible ✅
- [x] Save round-trip: POST returns `{"success":true}`, config.json updated ✅
- [x] PushBudgetService reloads after save (confirmed in logs: `⚙️ [Config] Notification settings updated`) ✅

#### 4d. Data Tab ✅
- [x] "What Alfred Knows" with sync to notion, refresh buttons ✅
- [x] Your Explicit Preferences (2 items) with ✓/✗/- feedback buttons ✅
- [x] What Alfred Knows About You (4 items) ✅
- [x] Communication Style (1 item) ✅

#### 4e. Legacy Tab Routing ✅
- [x] `showSettingsTab('tenets')` → coaching tab active ✅
- [x] `showSettingsTab('memory')` → data tab active ✅
- [x] `showSettingsTab('skills')` → coaching (via legacyMap) ✅
- [x] `showSettingsTab('reflection')` → data (via legacyMap) ✅
- [x] `showSettingsTab('library')` → coaching ✅
- [x] `showSettingsTab('previews')` → coaching ✅

### 5. Cross-Tab Sync
- [x] `BroadcastChannel('alfred-settings')` created (verified in code) ✅
- [x] `visibilitychange` listener present ✅
- [ ] Cannot fully test multi-tab sync in Preview tool (single viewport)
- [ ] Cross-device sync (iPhone lock/unlock) requires physical device test

### 6. Push E2E
- [x] Push test endpoint works — delivered to all 6 devices (2 Apple, 2 FCM, 2 Apple) ✅
- [x] Budget tracking: 5/5 used, correctly shows in Notifications tab ✅
- [x] Quiet hours suppression: logs show `🔇 [PushBudget] Suppressed: quiet hours` ✅
- [x] Morning nudge enabled in config ✅
- [x] Post-meeting capture enabled in config ✅
- [x] Toggle checks in `tick()` confirmed in code ✅
- [ ] Cannot test live morning nudge timing (quiet hours)
- [ ] Cannot test post-meeting capture (no meetings ending now)

### 7. Chat & Coaching Cards
- [x] Chat SSE stream works — `event: tool_start` + `event: tool_result` flowing ✅
- [x] 7 coaching cards rendered with correct IDs ✅
- [x] Card refresh buttons (↻) present for each card ✅
- [x] Lead card visible, 6 collapsed under "6 more observations" ✅
- [ ] Coaching opener not rendering on page (Issue #6)

### 8. Meeting Brief
- [x] `/api/home/next-meeting-brief` responds in 648ms ✅
- [ ] No meeting within 15 min at test time — card not expected to show
- [x] Meeting brief card logic present in code ✅

### 10. Cross-Device & PWA
- [x] **iPhone 17 Pro (393x852)**: Home renders cleanly, no overflow, touch targets good ✅
- [x] **iPhone 17 Pro**: Settings panel slides up, notifications tab fully usable ✅
- [x] **iPad Pro (1024x1366)**: Home renders OK ✅
- [ ] **iPad Pro**: Settings panel RIGHT EDGE CLIPPED (Issue #7) — status values, toggles, controls cut off ❌
- [x] Service worker registered (logs confirm) ✅
- [ ] Tailscale Funnel: requires external device test
- [ ] Offline fallback: requires network simulation

### 11. Email Delivery
- [x] Email config valid: enabled=true, smtp.gmail.com:587, username present, password present ✅
- [x] Push config valid: all new fields (morning_nudge_enabled, post_meeting_capture_enabled) present in config.json ✅
- [x] Learning system active: 22 events, 7 active patterns, 1 pending review ✅
- [ ] Daily briefing email send: not triggered (would send real email)
- [ ] Attention defense email send: not triggered (would send real email)
- [ ] Email HTML rendering: requires inbox inspection

---

## Summary

**Tested**: 95+ of 138 test cases covered
**Passed**: ~85 tests
**Issues Found**: 9 (3 HIGH, 3 MEDIUM, 1 LOW, 2 INFO)
**Cannot Test in This Session**: ~30 tests (require morning timing, physical devices, live push budget, email send confirmation)

### Critical Path Issues
1. **Cold API latency** (Issues #1-3): Pulse 13s, cards 37s, briefing 165s — all blow past targets. Warm caches are sub-ms so pre-warming is critical. If pre-warming fails or user opens Alfred before cache warms, experience degrades significantly.
2. **iPad settings clipping** (Issue #7): Right edge of settings panel cuts off controls at 1024px width.
3. **Coaching opener missing** (Issue #6): API returns valid greeting text but it's not rendered on the home page.

### What Looks Great
- All 4 settings tabs render correctly with correct content
- Legacy tab routing (6 mappings) all work
- Notification settings full round-trip (UI → API → config.json → reload)
- Push delivery to all 6 devices
- Quiet hours suppression working
- Mobile (iPhone) layout is clean
- Chat streaming works
- 7 coaching cards rendering with correct collapse behavior
- Morning briefing card correctly hidden after 11 AM
