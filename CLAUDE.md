# Alfred - Claude Code Project Guide

## Build & Deploy Workflow

**CRITICAL**: Alfred runs as a LaunchAgent on macOS. There is ONE binary, ONE process, ONE port.

### The Golden Path: Build → Install → Restart

```bash
# 1. Build release binary
cd "$(git rev-parse --show-toplevel)"
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
    codesign --force --sign "Alfred Dev (msfoundry)" --identifier com.msfoundry.alfred /Applications/Alfred.app/Contents/MacOS/Alfred
else
    echo "Binary unchanged — skipping codesign (preserves TCC permissions)"
fi

# 4. Install the web pages INTO THE APP BUNDLE (not the hot-reload dir).
#    The app serves app.html; home.html is gone. HotReloadManager reads
#    ~/.config/alfred/web/ FIRST, so a copy left there wins for ever and pins the
#    UI to whatever version was installed first — never put app.html there.
for page in app.html setup.html sw.js manifest.json; do
    cp "Sources/GUI/Resources/$page" /Applications/Alfred.app/Contents/Resources/
done

# 5. Restart via LaunchAgent
launchctl load ~/Library/LaunchAgents/com.msfoundry.alfred.plist

# 6. VERIFY FIRST (see "Post-Deploy Verification Checklist" below).

# 7. SCORE IT — the checklist proves your change works; this proves nothing else broke.
./scripts/eval.sh --gate            # ~5s, 73 invariants, no model calls. Exit 1 = regression.
#    It scores .build/release/alfred, which step 1 just built, against a frozen copy of your
#    data on port 8081 — so it is this binary, and it cannot touch anything real.
#    An UNEXPLAINED regression is a stop: find out why before merging.
#    An EXPLAINED one (you changed that surface on purpose) is accepted deliberately:
#        ./scripts/eval.sh                 # read the full table first
#        ./scripts/eval.sh --save-baseline # then accept the new numbers

# 8. Merge to main. Merging is the last step, never the first: main should only ever contain
#    code that has been run and checked on the live system, not code that merely compiled.
git checkout main
git merge --ff-only <branch>        # a non-fast-forward means main moved — rebase, re-verify
git push origin main                # only once you are done verifying
```

**Always do this after making code changes.** Never leave a debug binary running alongside the release binary.

**On merging**: work done in another session (or on a `claude/*` branch) still has to go through
the whole path — build, deploy, verify, score — *before* it reaches main. A branch that has
never been compiled is not a branch that is ready to merge, whatever its commit messages claim.
Merge only after steps 6-7 pass, and keep the merge a fast-forward so main's history stays
linear and each fix stays individually revertable.

**Note on permissions**: Uses the stable `"Alfred Dev (msfoundry)"` self-signed identity so TCC permissions (FDA, Contacts, Notifications) survive across local rebuilds. The smart-skip still avoids unnecessary re-signing on HTML-only deploys. This identity is for **local dev only** — distribution builds use a real Apple Developer ID Application certificate (see "Distribution Builds" below).

### Distribution Builds (DMG for external users)

For shipping to external users, the local self-signed identity is NOT enough — Gatekeeper will block first launch. Distribution builds need:
1. A real **Developer ID Application** certificate from Apple
2. Hardened runtime + entitlements
3. Apple notarization + ticket stapling

The `scripts/build-dmg.sh` script handles all of this when the right env vars are set:

```bash
# One-time setup: store notarization credentials in keychain
xcrun notarytool store-credentials "alfred-notary" \
  --apple-id <your-apple-id-email> \
  --team-id <TEAMID> \
  --password <app-specific-password-from-appleid.apple.com>

# Build a signed + notarized DMG
DEVELOPER_ID="Developer ID Application: Your Name (YOUR_TEAM_ID)" \
NOTARY_PROFILE="alfred-notary" \
./scripts/build-dmg.sh
```

The script auto-detects mode:
- **DEVELOPER_ID set** → distribution mode (hardened runtime, real signing, notarization, stapling, signed DMG)
- **DEVELOPER_ID unset** → ad-hoc fallback with a loud warning (local testing only)

Outputs `Coach-Alfred-<VERSION>.dmg` ready for `gh release create`.

### Why This Matters

- `/Applications/Alfred.app` is OUR Alfred (bundle ID: `com.msfoundry.alfred`), NOT macOS Alfred/Spotlight
- LaunchAgent at `~/Library/LaunchAgents/com.msfoundry.alfred.plist` has `KeepAlive: true`
- If you `kill` the process, launchd will respawn it immediately
- If you start a debug binary while the release binary is running, the debug binary will FAIL to bind port 8080
- `launchctl unload` does NOT reliably kill the old process — the binary can survive and hold the port. Always follow with `pkill -f` and a sleep to ensure the old process is dead before installing the new binary. Without this, you'll deploy a new binary but the OLD process keeps running, and your changes appear to not work.
- Always use `launchctl unload/load` to stop/start, never just `kill`

## WhatsApp Bridge (whatsmeow) — `tools/wa-bridge`

A separate long-running Go binary (whatsmeow, like the Commit app) that sends AND ingests
WhatsApp over the network protocol — **no Full Disk Access, no WhatsApp Desktop needed**. It's
the path off the FDA-based local-DB reader.

- **HTTP API on `127.0.0.1:8790`**: `GET /status`, `GET /qr` + `GET /qr.png`, `POST /send {jid,message}`,
  `GET /messages?since=&chat=&limit=`, `GET /contacts`. Data in `~/.alfred/{whatsmeow.db,wa-messages.db}`.
- **Build/run**: `./scripts/wa-bridge.sh {build|pair|run|install|status}`. `install` = launchd agent.
- **CRITICAL launchd gotcha**: the binary must run from a **non-TCC** location. Running from
  `~/Documents/...` hangs the agent in dyld (`open_with_subsystem`) forever. `install` stages a
  **signed** copy to `~/.alfred/wa-bridge` (sign with `"Alfred Dev (msfoundry)"`) and points the plist there.
- **One-time pairing**: scan the QR (terminal, or Alfred's masthead "● WA" pill → modal). Session persists.
- **Swift side**: `WhatsAppSource.reader(config:)` picks `messaging.whatsapp.source` = `auto` (default,
  bridge-when-paired-else-local_db) | `bridge` | `local_db`. `WhatsAppBridgeReader` is a drop-in for
  `WhatsAppReader`. Unpaired/absent bridge → auto falls back to local_db, so nothing breaks.

## Port & Server

- **Port**: 8080 (configured in `~/.config/alfred/config.json`)
- **Passcode**: `YOUR_PASSCODE`
- **Health check**: `curl http://localhost:8080/api/health?passcode=YOUR_PASSCODE`
- **Web UI**: `http://localhost:8080/?passcode=YOUR_PASSCODE` (`/home.html` still redirects here for old bookmarks)

## Hot-Reload System

- Alfred reads `~/.config/alfred/web/` FIRST, then the app bundle's `Contents/Resources/`
- Source HTML lives at `Sources/GUI/Resources/app.html` (plus `setup.html`)
- `HotReloadManager.swift` no longer copies anything into the hot-reload dir: a copy of
  `app.html` left there silently pins the UI to that version through every later deploy
- The hot-reload dir is now an **override** for deliberate live editing only. Use it to iterate
  on HTML without a rebuild, then delete the override and install to the bundle (step 4)
- For Swift changes, you MUST rebuild and reinstall the binary

## Key File Locations

| File | Purpose |
|------|---------|
| `~/.config/alfred/config.json` | All runtime configuration |
| `/Applications/Alfred.app/Contents/Resources/app.html` | The HTML the app actually serves |
| `~/.config/alfred/web/` | Optional override dir — wins over the bundle; keep it empty |
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
  api.port: 8080            # what the server actually binds (app.port is legacy, ignored)
  api.passcode: "YOUR_PASSCODE"
  app.port: 8080
  app.passcode: "YOUR_PASSCODE"
  app.briefing_time: "08:15"
  app.attention_alert_time: "15:00"
  notifications.email: { smtp_host, smtp_port, smtp_username, smtp_password, enabled }
  scheduled: { briefing_enabled, attention_enabled, email_to }
  notion.context_databases: [{ id, name }]
  notion.tasks_database_id: "YOUR_TASKS_DATABASE_ID"
```

## Chat Intent System (v2.2.2)

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

All endpoints require `?passcode=YOUR_PASSCODE` query parameter.

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

- Latest release: `v5.2.1` (You-Wiki refreshes on each Notion pull, 4×/day). Prior: `v5.2.0` (Notion diff pull 4×/day + cross-day cadence catch-up), `v5.1.1` (@schedule direct-block fixes), `v5.1.0` (@schedule end-to-end + belief-durability + You-Wiki)
- Version in code: `5.2.1` (in `Sources/App/main.swift` `static let version` — single source of truth; also mirrored in `scripts/build-dmg.sh` `VERSION=`)

## Post-Deploy Verification Checklist

**CRITICAL**: Never say a change is "done" or "fixed" until ALL steps are completed and output shown.

After every Golden Path deploy:

1. **Health check** — `curl -s 'http://127.0.0.1:8080/api/health?passcode=YOUR_PASSCODE'` → confirm `"status":"ok"`
2. **Test the specific change** — curl the exact endpoint or trigger the exact user flow that was modified. Not a generic check — the *actual behavior* that changed.
3. **Show raw output** — paste the curl response, log output, or screenshot. No paraphrasing. Let the evidence speak.
4. **Only then say "done"** — if the output doesn't match expectations, the fix isn't done. Investigate and iterate.
5. **Score it** — `./scripts/eval.sh --gate`. Steps 1-4 prove the thing you changed works; this is the only step that says anything about the fifteen features you didn't touch. Five seconds, no model calls. A regression you can't explain is a stop, not a note for the commit message.
6. **Then merge to main** — `git checkout main && git merge --ff-only <branch>`, and push. Step 8 of the Golden Path. Nothing reaches main until steps 1-5 above have passed on the running system.

For UI/frontend changes, also:
- Load the page and visually verify (screenshot or browser tool)
- Don't assume HTML hot-reload worked — confirm by checking the rendered output
- **Mobile rendering check** — verify layout on iPhone 17 Pro (393×852 viewport) and iPad Pro (1024×1366 viewport) using browser responsive mode or device simulation. Check for overflow, truncation, touch target sizing, and panel/modal usability. Do this on every UI push.

For prompt/LLM behavior changes:
- Trigger the actual user flow (e.g. send a chat message, run a scan)
- Check logs for the LLM's raw response to confirm the behavior changed
- Prompt changes are non-deterministic — a single test may not catch issues, note this caveat

**Never declare victory based on "the code looks right". Always verify the running system.**

## The Scorecard (`./scripts/eval.sh`)

73 deterministic invariants across all 16 features — referential integrity, the gates the
synthesis pass promises to keep, and source-level checks that the four intent files stay in step.
About five seconds, no model calls, no cost. Full detail in `evals/scorecard/README.md`.

```bash
./scripts/eval.sh --gate            # one line, for the Golden Path. Exit 1 = regression.
./scripts/eval.sh                   # the full per-feature table and the delta
./scripts/eval.sh --live            # read-only against the running install on 8080
./scripts/eval.sh --feature claims  # one row, while iterating
./scripts/eval.sh --list            # every invariant, in English
./scripts/eval.sh --save-baseline   # accept the current numbers as the new floor
```

Two things to know before reading a result:

**A violation that predates the baseline is "known", not a failure.** This install carries
fourteen commitments with more than one closure row, all from March and April. They lower the
score honestly but only an *increase* is reported as a regression, because a check that is red
every single run is a check you stop reading.

**The bands are measured, not guessed.** `./scripts/eval.sh --calibrate 3` runs the same build
three times, resetting between runs, and the spread it observes becomes the tolerance. In the
sandbox that spread is zero across all 28 metrics, so the band is tight and a single unexplained
front disappearing gets caught. Live bands need runs spaced over hours (`--interval 900`) — the
runner refuses to write one from a short sitting, because a too-tight live band cries wolf.

## Debugging Tips

- Server logs go to `~/.alfred/alfred.log` (via LaunchAgent stdout/stderr)
- If port 8080 is occupied: `lsof -i:8080` to find the culprit
- If two Alfred processes exist, one is always wrong -- use `launchctl unload/load`
- URL encoding: use `%20` for spaces in contact names, NOT `+`
- Cache TTLs: Briefing 4h, Calendar 10min, Messages 10min, Attention 4h, Todos 10min

## TCC / Permissions Notes

- **Full Disk Access** is required for iMessage (`~/Library/Messages/chat.db`)
- Grant to `/Applications/Alfred.app` in System Settings → Privacy & Security → Full Disk Access
- **CRITICAL**: After copying a new binary, you MUST re-sign with `codesign --force --sign "Alfred Dev (msfoundry)" --identifier com.msfoundry.alfred /Applications/Alfred.app/Contents/MacOS/Alfred`
- The stable `"Alfred Dev (msfoundry)"` identity preserves TCC across rebuilds (vs. ad-hoc `--sign -` which revokes on every build)
- `FileManager.isReadableFile` returns FALSE for TCC-protected files even with FDA granted — always use `sqlite3_open_v2` directly
- The codesign step is included in the Golden Path above (step 3)
