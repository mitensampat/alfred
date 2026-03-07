# Alfred - Claude Code Project Guide

## Build & Deploy Workflow

**CRITICAL**: Alfred runs as a LaunchAgent on macOS. There is ONE binary, ONE process, ONE port.

### The Golden Path: Build → Install → Restart

```bash
# 1. Build release binary
cd "/Users/mitensampat/Documents/Claude apps/Alfred"
swift build -c release

# 2. Stop the running instance
launchctl unload ~/Library/LaunchAgents/com.msfoundry.alfred.plist

# 3. Install new binary
cp .build/release/Alfred /Applications/Alfred.app/Contents/MacOS/Alfred

# 4. Re-sign with stable bundle identifier (CRITICAL for Full Disk Access / TCC permissions)
codesign --force --sign - --identifier com.msfoundry.alfred /Applications/Alfred.app/Contents/MacOS/Alfred

# 5. Sync HTML to hot-reload directory
cp Sources/GUI/Resources/index-notion.html ~/.config/alfred/web/index-notion.html

# 6. Restart via LaunchAgent
launchctl load ~/Library/LaunchAgents/com.msfoundry.alfred.plist
```

**Always do this after making code changes.** Never leave a debug binary running alongside the release binary.

### Why This Matters

- `/Applications/Alfred.app` is OUR Alfred (bundle ID: `com.msfoundry.alfred`), NOT macOS Alfred/Spotlight
- LaunchAgent at `~/Library/LaunchAgents/com.msfoundry.alfred.plist` has `KeepAlive: true`
- If you `kill` the process, launchd will respawn it immediately
- If you start a debug binary while the release binary is running, the debug binary will FAIL to bind port 8080
- Always use `launchctl unload/load` to stop/start, never just `kill`

## Port & Server

- **Port**: 8080 (configured in `~/.config/alfred/config.json`)
- **Passcode**: `REDACTED_PASSCODE`
- **Health check**: `curl http://localhost:8080/api/health?passcode=REDACTED_PASSCODE`
- **Web UI**: `http://localhost:8080/index-notion.html?passcode=REDACTED_PASSCODE`

## Hot-Reload System

- Alfred serves HTML from `~/.config/alfred/web/` (reads fresh from disk each request)
- Source HTML lives at `Sources/GUI/Resources/index-notion.html`
- `HotReloadManager.swift` copies source → hot-reload dir only if target doesn't exist
- For HTML-only changes, just edit the hot-reload file directly (no rebuild needed)
- For Swift changes, you MUST rebuild and reinstall the binary

## Key File Locations

| File | Purpose |
|------|---------|
| `~/.config/alfred/config.json` | All runtime configuration |
| `~/.config/alfred/web/index-notion.html` | Live HTML served by the server (hot-reload) |
| `~/.alfred/scheduler_state.json` | Tracks last briefing/attention run dates |
| `~/.alfred/agents/` | Agent memory files |
| `~/.alfred/commitment_scan.db` | Commitment extractions, closure detections, pending confirmations |
| `~/.alfred/workflow_learning.db` | User feedback on closures, computed signal accuracy patterns |
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

All endpoints require `?passcode=REDACTED_PASSCODE` query parameter.

## Learning System

Alfred's commitment tracker is self-improving. See `docs/internal/COMMITMENT_LIFECYCLE_LEARNING.md` for the full architecture. Key points:
- Auto-closure uses confidence thresholds: ≥0.85 auto-closes, 0.6-0.84 asks user, <0.6 ignored
- User confirm/reject actions are stored in `workflow_learning.db` as training signal
- Signal accuracy patterns (e.g. "Got it" = 92% reliable) are computed from feedback
- These patterns are injected into Claude's prompts on future closure detection runs
- Over time, reliable signals graduate from "pending" to "auto-close" automatically

## Git State Notes

- Latest release: `v2.0.4` (tag pushed to GitHub with release)
- Version in code: `2.0.4` (in `main.swift` line 17 — single source of truth)

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
