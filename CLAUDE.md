# Alfred - Claude Code Project Guide

## Build & Deploy Workflow

**CRITICAL**: Alfred runs as a LaunchAgent on macOS. There is ONE binary, ONE process, ONE port.

### The Golden Path: Build → Install → Restart

```bash
# 1. Build release binary
cd "/Users/mitensampat/Documents/Claude apps/Alfred"
swift build -c release

# 2. Stop the running instance AND force-kill the old process
#    (launchctl unload alone does NOT reliably kill the process)
launchctl unload ~/Library/LaunchAgents/com.msfoundry.alfred.plist
sleep 1
pkill -f "Alfred.app/Contents/MacOS/Alfred"
sleep 2

# 3. Smart install: only copy + re-sign if binary actually changed
#    Re-signing revokes ALL macOS TCC permissions (FDA, Contacts, Notifications)
#    so we skip it when the binary is identical (e.g., HTML-only changes)
OLD_HASH=$(md5 -q /Applications/Alfred.app/Contents/MacOS/Alfred 2>/dev/null || echo "none")
NEW_HASH=$(md5 -q .build/release/alfred 2>/dev/null || echo "new")
if [ "$OLD_HASH" != "$NEW_HASH" ]; then
    echo "Binary changed — installing + re-signing"
    cp .build/release/alfred /Applications/Alfred.app/Contents/MacOS/Alfred
    codesign --force --sign - --identifier com.msfoundry.alfred /Applications/Alfred.app/Contents/MacOS/Alfred
else
    echo "Binary unchanged — skipping codesign (preserves TCC permissions)"
fi

# 4. Sync HTML to hot-reload directory
cp Sources/GUI/Resources/home.html ~/.config/alfred/web/home.html

# 5. Restart via LaunchAgent
launchctl load ~/Library/LaunchAgents/com.msfoundry.alfred.plist
```

**Always do this after making code changes.** Never leave a debug binary running alongside the release binary.

**Note on permissions**: `codesign --force --sign -` uses ad-hoc signing which generates a new identity each time, causing macOS to revoke FDA, Contacts, and Notification permissions. The smart-skip above avoids this on HTML-only deploys. For a permanent fix, use a stable Apple Developer identity (see High Priority To-Do in MEMORY.md).

### Why This Matters

- `/Applications/Alfred.app` is OUR Alfred (bundle ID: `com.msfoundry.alfred`), NOT macOS Alfred/Spotlight
- LaunchAgent at `~/Library/LaunchAgents/com.msfoundry.alfred.plist` has `KeepAlive: true`
- If you `kill` the process, launchd will respawn it immediately
- If you start a debug binary while the release binary is running, the debug binary will FAIL to bind port 8080
- `launchctl unload` does NOT reliably kill the old process — the binary can survive and hold the port. Always follow with `pkill -f` and a sleep to ensure the old process is dead before installing the new binary. Without this, you'll deploy a new binary but the OLD process keeps running, and your changes appear to not work.
- Always use `launchctl unload/load` to stop/start, never just `kill`

## Port & Server

- **Port**: 8080 (configured in `~/.config/alfred/config.json`)
- **Passcode**: `REDACTED_PASSCODE`
- **Health check**: `curl http://localhost:8080/api/health?passcode=REDACTED_PASSCODE`
- **Web UI**: `http://localhost:8080/home.html?passcode=REDACTED_PASSCODE`

## Hot-Reload System

- Alfred serves HTML from `~/.config/alfred/web/` (reads fresh from disk each request)
- Source HTML lives at `Sources/GUI/Resources/home.html`
- `HotReloadManager.swift` copies source → hot-reload dir only if target doesn't exist
- For HTML-only changes, just edit the hot-reload file directly (no rebuild needed)
- For Swift changes, you MUST rebuild and reinstall the binary

## Key File Locations

| File | Purpose |
|------|---------|
| `~/.config/alfred/config.json` | All runtime configuration |
| `~/.config/alfred/web/home.html` | Live HTML served by the server (hot-reload) |
| `~/.alfred/scheduler_state.json` | Tracks last briefing/attention run dates |
| `~/.alfred/agents/` | Agent memory files |
| `~/.alfred/commitment_scan.db` | Commitment extractions, closure detections, pending confirmations |
| `~/.alfred/workflow_learning.db` | Learning System v2: events, patterns, reviews + v1 workflow patterns |
| `~/.config/alfred/memory/contacts.json` | Thread classification, extraction acceptance rates |
| `~/Library/LaunchAgents/com.msfoundry.alfred.plist` | LaunchAgent (auto-start, keep-alive) |
| `/Applications/Alfred.app/Contents/MacOS/Alfred` | The production binary |

## Config Structure (key sections)

```
config.json:
  app.port: 8080
  app.passcode: "REDACTED_PASSCODE"
  app.briefing_time: "08:15"
  app.attention_alert_time: "15:00"
  notifications.email: { smtp_host, smtp_port, smtp_username, smtp_password, enabled }
  scheduled: { briefing_enabled, attention_enabled, email_to }
  notion.context_databases: [{ id, name }]  -- "Second Brain" + "Granola Notes"
  notion.tasks_database_id: "REDACTED_ID..."
```

## Chat Intent System (v2.2.1)

The chat pipeline: **User message → IntentRecognitionService → IntentExecutor → coaching overlay → SSE stream**

### Adding a new chat capability

1. **`Sources/Models/Intent.swift`** — Add new `Target` enum case + any new `IntentFilters` fields. Update `CodingKeys`, decoder, and both inits. Mirror in `Sources/GUI/Models/Intent.swift`.
2. **`Sources/Services/IntentRecognitionService.swift`** — Add prompt rules to `getSystemPrompt()` so Claude knows how to classify the new intent. Update the TARGET list and add example mappings. Mirror in GUI path.
3. **`Sources/Services/IntentExecutor.swift`** — Add `case (.action, .target):` in the main switch before `(.chat, _)`. Implement the handler method. Mirror in GUI path (can be stub pointing to web UI).
4. **`Sources/Services/IntentCoachingRouter.swift`** — Map the new target to a `CoachingPosture` in `posture(for:target:)` and optionally add to `relevantSkillIds(for:)`.

### Key services used by handlers

| Service | Access | Notes |
|---------|--------|-------|
| `ReflectionStore.shared` | Direct | `getThemesWithState`, `getOpenQuestions`, `getThemeDetail(theme:)` |
| `AgentMemoryService.shared` | Direct | `getMemory(for: .communication)` returns `AgentMemory` with `.content`/`.sections`. `teach(agentType:rule:)` throws. `forget(agentType:pattern:)` returns Bool. |
| `WorkflowLearningService.shared` | Direct | `getLearnedPatterns()` returns named tuples. `getContextForEndpoint("chat")` for injection. |
| `CadenceService.shared` | Direct | `getAll()`, `markManualRunSuccess(id:timestamp:)` |
| `FavoritesService.shared` | Direct | `getFavorites()`, `addContact()` throws, `removeContact(name:)` throws |
| `ConversationHistoryService.shared` | Direct | `getConversations(limit:)` returns `[[String: Any]]` with dict keys |
| `SkillLoader.shared` | Direct | `getEnabledSkills()` returns `[SkillDefinition]`, `.description` is non-optional |
| `CommitmentScanTracker.shared` | Direct | `getPendingClosureConfirmations()` returns named tuples (`.title`, `.signal`, `.confidence`) |

### Coaching postures

Each intent target maps to a coaching posture via `IntentCoachingRouter`. The posture determines which skill tenets are injected and how follow-up coaching is framed:

- **reflection** — thread/messages/contacts/drafts
- **prioritization** — tasks/todos/attention/focus
- **accountability** — commitments
- **planning** — calendar/meeting
- **deepReflection** — reflections
- **operational** — create/update/delete actions, favorites/cadences/conversations (skip coaching)
- **general** — memory/skills/preferences

### Notion task search

`findTasksByFuzzyTitle()` uses progressive 3-tier search: exact phrase → all-words AND → longest-word fallback. This is in both `Sources/Services/NotionService+Tasks.swift` and GUI path.

## Scheduler

- Runs inside the main process (not a separate daemon)
- Checks every 60 seconds against `briefing_time` and `attention_alert_time`
- Has a 3-hour catch-up window for missed tasks on startup
- Tracks state in `~/.alfred/scheduler_state.json` to prevent double-runs
- Commitment reminders run at `briefing_time` AND at 15:00

## Key API Endpoints

- `GET /api/briefing?date=YYYY-MM-DD` - Daily briefing (SSE streaming)
- `GET /api/calendar?date=YYYY-MM-DD&filter=all|work|personal` - Calendar
- `GET /api/messages/summary?platform=whatsapp&contact=Name&days=7` - Messages
- `GET /api/attention-check` - Attention defense alert
- `GET /api/commitments/dashboard` - Commitment dashboard
- `POST /api/commitments/scan?contact=Name` - Scan for commitments
- `GET /api/extract/todos?days=7` - Extract todos
- `POST /api/todos/scan` - Formatted todo scan
- `GET /api/memory/unified` - All memory (rules + patterns)
- `GET /api/favorites` - Favorite contacts/groups
- `POST /api/favorites/contacts` - Add favorite contact
- `DELETE /api/favorites/contacts?name=X` - Remove favorite
- `GET /api/workflow-patterns` - Computed workflow patterns
- `POST /api/workflow-patterns/compute` - Recompute patterns
- `GET /api/workflow-patterns/digest` - Generate digest
- `POST /api/workflow-patterns/send-digest` - Email digest
- `GET /api/task-lifecycle/stats` - Task lifecycle statistics
- `GET /api/commitment-tracker/stats` - Tracker stats (open/closed/auto-closed/pending)
- `GET /api/commitment-tracker/pending-closures` - Pending auto-closure confirmations
- `POST /api/commitment-tracker/confirm-closure?hash=X` - Confirm an auto-closure
- `POST /api/commitment-tracker/reject-closure?hash=X` - Reject an auto-closure
- `GET /api/playbook/status` - Playbook sync status
- `GET /api/config/notion` - Notion configuration
- `GET /api/learning/status` - Learning v2 stats (events, patterns, reviews)
- `POST /api/learning/compute` - Trigger pattern computation
- `GET /api/learning/patterns` - Active learned patterns
- `POST /api/learning/review?id=X&action=confirmed|corrected|dismissed` - Resolve pattern review
- `POST /api/commitment-tracker/cleanup-orphans` - Clean orphaned closure detections
- `POST /api/commitment-tracker/sync-from-notion` - Bidirectional sync (Notion→local)

All endpoints require `?passcode=REDACTED_PASSCODE` query parameter.

## Learning System v2

Alfred's learning system has 3 layers:

### Layer 1: Signal Collection (passive, always-on)
- Records corrections, explicit preferences, extraction feedback, closure feedback from every chat
- Stored in `workflow_learning.db` → `learning_events` table
- Direct instructions ("always do X", "never do Y") bypass graduation — permanent immediately
- Keyword detection in `detectAndRecordCorrections()` wired into both chat paths

### Layer 2: Pattern Computation (daily + on-demand)
- Runs via `computeLearnedPatterns()` — called from pattern learning cadence + `/api/learning/compute`
- Communication style patterns: Haiku extracts patterns from corrections
- Direct instructions: processed into `learned_patterns` with confidence=1.0
- Staleness: 30 days → stale flag, 90 days → archived
- Conflict resolution: contradictions decay confidence by 30%
- New patterns queued for Coach review in `pending_pattern_reviews`

### Layer 3: Knowledge Application (per-request)
- `getContextForEndpoint("chat"|"briefing"|"commitment_scan"|"extraction")` returns tailored pattern injection
- Injected into `CoachingPromptBuilder.build()` as "What Alfred Has Learned About You"
- Pending pattern reviews surfaced to Coach for natural verification in conversation
- Max 500 tokens per injection

### v1 (still active)
- Auto-closure confidence thresholds: ≥0.85 auto-closes, 0.6-0.84 asks user, <0.6 ignored
- Signal accuracy patterns injected via `getPatternContextForAI()`
- 164 computed patterns from workflow data

## Git State Notes

- Latest release: `v2.2.1` (Enhanced Chat Experience — Full Intent Wiring)
- Version in code: `2.2.1` (in `main.swift` line 17 — single source of truth)

## Post-Deploy Verification Checklist

**CRITICAL**: Never say a change is "done" or "fixed" until ALL steps are completed and output shown.

After every Golden Path deploy:

1. **Health check** — `curl -s 'http://127.0.0.1:8080/api/health?passcode=REDACTED_PASSCODE'` → confirm `"status":"ok"`
2. **Test the specific change** — curl the exact endpoint or trigger the exact user flow that was modified. Not a generic check — the *actual behavior* that changed.
3. **Show raw output** — paste the curl response, log output, or screenshot. No paraphrasing. Let the evidence speak.
4. **Only then say "done"** — if the output doesn't match expectations, the fix isn't done. Investigate and iterate.

For UI/frontend changes, also:
- Load the page and visually verify (screenshot or browser tool)
- Don't assume HTML hot-reload worked — confirm by checking the rendered output
- **Mobile rendering check** — verify layout on iPhone 17 Pro (393×852 viewport) and iPad Pro (1024×1366 viewport) using browser responsive mode or device simulation. Check for overflow, truncation, touch target sizing, and panel/modal usability. Do this on every UI push.

For prompt/LLM behavior changes:
- Trigger the actual user flow (e.g. send a chat message, run a scan)
- Check logs for the LLM's raw response to confirm the behavior changed
- Prompt changes are non-deterministic — a single test may not catch issues, note this caveat

**Never declare victory based on "the code looks right". Always verify the running system.**

## Debugging Tips

- Server logs go to `~/.alfred/alfred.log` (via LaunchAgent stdout/stderr)
- If port 8080 is occupied: `lsof -i:8080` to find the culprit
- If two Alfred processes exist, one is always wrong -- use `launchctl unload/load`
- URL encoding: use `%20` for spaces in contact names, NOT `+`
- Cache TTLs: Briefing 4h, Calendar 10min, Messages 10min, Attention 4h, Todos 10min

## TCC / Permissions Notes

- **Full Disk Access** is required for iMessage (`~/Library/Messages/chat.db`)
- Grant to `/Applications/Alfred.app` in System Settings → Privacy & Security → Full Disk Access
- **CRITICAL**: After copying a new binary, you MUST re-sign with `codesign --force --sign - --identifier com.msfoundry.alfred /Applications/Alfred.app/Contents/MacOS/Alfred`
- Without re-signing, the ad-hoc signature changes on every build, and macOS TCC revokes Full Disk Access
- `FileManager.isReadableFile` returns FALSE for TCC-protected files even with FDA granted — always use `sqlite3_open_v2` directly
- The codesign step is included in the Golden Path above (step 4)
