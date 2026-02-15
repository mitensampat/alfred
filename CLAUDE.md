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

# 4. Sync HTML to hot-reload directory
cp Sources/GUI/Resources/index-notion.html ~/.config/alfred/web/index-notion.html

# 5. Restart via LaunchAgent
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
- `GET /api/playbook/status` - Playbook sync status
- `GET /api/config/notion` - Notion configuration

All endpoints require `?passcode=REDACTED_PASSCODE` query parameter.

## Git State Notes

- Current HEAD: `f706c56` (Revert "v1.6.3.3")
- Working tree has uncommitted changes across ~10 Swift files
- HTML was recovered from a previous Claude session transcript after a power cut
- Version in code: `1.7.0` (in `main.swift`)

## Debugging Tips

- Server logs go to `~/.alfred/alfred.log` (via LaunchAgent stdout/stderr)
- If port 8080 is occupied: `lsof -i:8080` to find the culprit
- If two Alfred processes exist, one is always wrong -- use `launchctl unload/load`
- URL encoding: use `%20` for spaces in contact names, NOT `+`
- Cache TTLs: Briefing 4h, Calendar 10min, Messages 10min, Attention 4h, Todos 10min
