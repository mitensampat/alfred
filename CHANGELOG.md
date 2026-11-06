# Changelog

All notable changes to Alfred will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [6.0.0] - 2026-11-05

A new app replaces the Desk, and one to-do list replaces the scattered ones. This is a major
version because the old primary surface is gone: `home.html` has been removed and everything it
did now lives in the new app at `/`. Old bookmarks and the installed PWA redirect there.

### Added

- **The new Alfred app** — one page for phone, iPad and desktop, reading only `/api/v2`:
  - **Now** — the up-next line (a to-do you pin always wins), the top 3 as cards you can reply to,
    decide, finish, defer or open, the rest of today folded away on the phone, and one coach line
    when a trigger has earned it.
  - **To-dos** — filter by front or person; a suggestion tray you accept or dismiss; today,
    upcoming and someday; an edit sheet for any item.
  - **Fronts** — up to ten confirmed fronts, each with a date; a front page holding its one open
    decision, next to-dos, who is involved, what others owe and what has happened.
  - **People** — who is waiting on you and who has gone quiet; per person, what you owe, what you
    are waiting on (reply or nudge over WhatsApp), shared fronts and scheduling.
  - One add box for everything (to-do, a question for Alfred, `@schedule`), a You menu whose status
    dot appears only when something needs you, and light and dark themes.
  - Phone layout with bottom tabs, a floating add button and bottom sheets; iPad and desktop get a
    left rail, a centre column and a right column for today's agenda and fronts at a glance.
- **One to-do list over every source** (`~/.alfred/todos.db`) — extracted items arrive as
  suggestions and join the list only once accepted; what others owe you is held separately as
  "waiting" rather than cluttering your own list; one promise found in several places stays one
  to-do with each source linked.
- **Two-way Notion mirror** — a dedicated "Alfred to-dos" database. Alfred pushes every change
  within a minute and pulls Notion edits every five minutes; the newest edit wins and the losing
  version is kept in the item's history. Open tasks in previously configured databases are
  imported once.
- **Alfred learns from your choices** — plain rules that always show their reason: correcting a
  front or a person teaches the tagger; a suggestion resembling one you dismissed, or coming from
  a source you keep dismissing, is hidden with its reason and restorable for fourteen days; the
  tray puts what you usually accept first; your dismissals and title edits feed the extractors.
- **Post-meeting capture** — a sheet (opened by a push, or when you next open the app) that splits
  your notes into follow-ups, tags them with the people from the meeting, and sends them to the
  suggestion tray.
- **Meeting preferences written as prose** — describe your week in a paragraph ("never before ten",
  "keep Fridays for thinking") and Alfred compiles it into slot scoring, always echoing its reading
  back in plain sentences so a misreading is corrected in seconds. Hard windows are removed from
  consideration rather than ranked down; a long free run is protected but never vetoed; slots too
  soon to be useful are dropped.
- **Decisions as editable definitions** — the fixed-menu judgements Alfred makes (belief
  durability, meeting category) now live as Markdown files in `~/.alfred/decisions/` alongside
  skills and lenses: the menu, the confidence thresholds, the fallback and the prompt. User files
  override the installed defaults; built-in menus stay fixed because code maps them onto enums.
- **One confidence policy** — every decision returns a confidence, and one rule turns it into a
  tier: `act` (apply on its own), `propose` (surface it for you), or `ask` (too unsure — fall back).
- **Tasks close themselves after 30 days** — a task nobody has touched in a month is closed
  automatically, for both tracked tasks and Alfred's own commitments, so the queue reflects live
  work instead of accumulating.
- **A failing routine now tells you** — a macOS banner on failure, which never existed before.
- **Setup is its own page** (`setup.html`) — the same first-run wizard, restyled.

### Changed

- **The old desk is gone.** Settings, your model, coach notes, the weekly review, the archive, past
  conversations, live scheduling sessions and closure confirmations all moved into the new app.
- **Every channel points at the new app** — the morning email is the Now tab in words, built from
  the same ranking; the morning push leads with your first to-do; a new push arrives ten minutes
  before a meeting and opens its prep; the evening push opens the app. Notifications route to the
  page they name.
- **WhatsApp self-chat commands** — `todo …` adds a to-do, `done …` closes the best match (and
  refuses to guess between two equally good ones), `now` replies with your top 3.
- **Quieter by default** — success banners are off for every routine, the mid-afternoon attention
  email no longer sends, and the weekly learning digest is off by default, leaving the Sunday
  review as the one weekly email. Existing installs are moved to these defaults once; changes you
  make afterwards stick.
- **Typed decision output** — decisions use structured outputs, so the reply always validates
  against a schema whose item ids and labels are enums. No more JSON extraction or repair, and an
  answer can no longer shift onto the wrong item when the model drops one.
- **Belief durability archives only when confident** — a statement is archived as a fact or an
  action only at the `act` tier; a hedged call stays a belief.
- **Meeting categories** — a low-confidence call lands as Uncategorized instead of a guess.

### Fixed

- **WhatsApp history was being silently truncated.** Every lookback was cut to roughly one week, so
  a scan asked for five weeks, reported success, and had actually read a fifth of the window. This,
  more than any outage, is what made Alfred's reading of your data feel stale.
- **The Notion to-do mirror never ran a single cycle.** The app's menu-bar loop was started from
  inside a main-queue block that never returns, which starved the serial queue: every background
  task waiting on the main actor suspended for ever. It had also silently swallowed 143 task
  scans — started, none finished, none reported as failed. The run loop now drives that callout,
  so the queue stays free.
- **A mirror failure no longer jams the queue.** Each row is pushed on its own: a deleted Notion
  page is forgotten and recreated, a permanent rejection stops retrying every minute and is
  recorded in the item's history, and rate limits and outages stay queued to retry.
- **The status endpoint used to stay silent when nothing worked.** It now says when the mirror has
  no database, has never pushed, or has fallen behind — the silence is what hid the bug above.
- **Decisions no longer throw away correct answers.** A returned label whose capitalization differed
  from the menu was discarded and the item fell to its fallback.
- **The `Fallback` in a decision file now does something.** It was advertised and documented as
  tunable, but no caller read it.
- **A brand-new install pointed at a retired model**, so every request failed with nothing in the
  interface to explain why. The bundled example config named a model that never existed.
- **Notion status fields are read before being refused**, and status *writes* are schema-aware too,
  so a newly added option works immediately and a failed cancellation no longer reports success.
- **Learning v2 recovered from a self-deadlock** that had stopped it outright and was making
  routines disappear.
- **The WhatsApp bridge** reports connection failures instead of swallowing them, allows re-pairing,
  logs every pairing outcome rather than only successes, no longer drops session writes under lock
  contention, and no longer pins reads to a bridge that has died.
- **Scheduling reads availability from every calendar**, not just the first, and says why a command
  did nothing instead of failing silently. The self-chat watcher starts on the path the service
  actually takes and finds the self-chat whatever form its id is stored in.
- **Improving the preference compiler now reaches people who already saved preferences** — compiled
  settings used to be cached on the prose alone and stayed frozen at whatever the compiler
  understood that day.
- **Commitments store the model's real confidence** instead of a hard-coded 0.8, and a second
  closing pass no longer records a duplicate completion.
- **Changing your passcode now verifies the current one** and requires at least eight characters;
  neither was checked before.
- **Health reporting shows staleness** where it can actually be seen, rather than reporting "ok"
  over data hours out of date.
- **Web files are no longer copied into the override directory**, where one copy silently pinned
  the interface to its first installed version through every later update.
- **Non-app pages were served without a passcode.** Only the app shell is public now.

## [5.2.1] - 2026-08-15

### Changed
- **The You-Wiki refreshes 4× a day** — it's now regenerated at the end of each Notion pull
  (08:00 / 13:00 / 20:00 / 01:00), a cheap deterministic write, so the portrait stays current
  through the day instead of only at the nightly convergence.

## [5.2.0] - 2026-08-15

### Added
- **Notion context, 4× a day** — a diff-only pull of the Notion Second Brain at 08:00 / 13:00 /
  20:00 / 01:00. Each run ingests only pages edited since the last pull (shared watermark), so
  the self-model stays current through the day instead of only at the nightly ingestion.

### Fixed
- **Daily cadences now catch up after downtime** — a daily run whose scheduled time passed while
  the Mac was asleep (or the app was down) now fires on the next wake, against the most recent
  scheduled occurrence, instead of being silently skipped for the day. No double-runs — the
  persisted last-run guards it. This makes night-time cadences (evening/overnight pulls, the
  nightly self-model convergence + You-Wiki refresh) reliable.

## [5.1.1] - 2026-08-14

### Fixed
- **@schedule direct-block titles** — a `block …` command with no explicit topic no longer
  echoes the raw command as the event title; it uses the stated topic, or falls back to a
  clean `Person <> You` default.
- **Location capture** — direct-block now parses a `location` (`location`/`in`/`@ <place>`,
  and won't mistake a clock time for a place) and writes it onto the calendar event.
- **Inline booking confirmation** — booking from the command palette now returns and shows the
  actual outcome (title · time · location · invite sent), or a clear error, instead of going
  silent.

## [5.1.0] - 2026-08-13

### Added
- **@schedule, end-to-end** — propose → send → watch the thread → book on a firm yes,
  each step a one-tap action in the People rail with plain-English stage labels. Works
  identically from the command palette, `⌘K`, and the WhatsApp self-chat; the rail
  auto-refreshes so replies surface on their own.
- **Direct block** — `block 30m with X at 4pm tomorrow topic Sync x@email` creates the
  event and sends the invite in one instruction, video link attached.
- **The You-Wiki, rendered** — a Slate-styled reader at `/wiki` for the nightly portrait
  (fronts, durable beliefs, working theses, people, coaching signals).

### Changed
- **Belief durability** — every self-model belief is classified `durable | tactical |
  fact | action`. Facts and one-off actions are archived out of the active set; durable
  principles and live theses stay, so the model keeps the right set over time.
- **Insight → Model** no longer promotes coaching *actions* into beliefs.
- **You-Wiki curation** — "What you believe" holds durable principles only; a new
  "Working theses" section holds tactical reads; coaching observations are curated
  recurring lens signals rather than a raw context dump.
- README rewritten to the current product (Desk + Coach, self-model, @schedule, You-Wiki).

## [5.0.0] - 2026-08-12

### Added
- **The Desk + Coach** — the primary surface rebuilt around three objects: the queue
  (who is blocked on you, ranked by leverage), Fronts (what you're running, each with
  owner/stage/one-decision), and the margin (relationships going cold + your week).
- **Coaching, reconnected** — skills, tenets, and analysis lenses are createable,
  toggleable, and editable from the interface; the Coach shows up on the Desk, as an
  evening nudge, and in a single tight morning email.
- **Alfred tasks** — an on-demand Notion task database; tasks stream in when you choose,
  each with a due date.
- **Web push (VAPID)** — coaching nudges delivered as browser push.

### Changed
- Removed the "$ at stake" front metric; tightened related-concept modeling.

## [3.1.0] - 2026-07-27

### Added
- **Signal, without Full Disk Access** — a message source read via an isolated decrypt
  helper, no FDA required.
- **WhatsApp network bridge** — sends and ingests over the protocol (no WhatsApp Desktop,
  no FDA once paired), with a local-DB fallback.

## [3.0.0] - 2026-07-26

### Added
- **The Self-Model** — Now / You / Model surfaces; facets (themes, beliefs, questions,
  decisions) as callable objects; convergence intelligence (frequency → importance,
  attach-at-source); a portable operating model. Refined in 3.0.1 (convergence) and
  3.0.2 (easier setup).

## [2.3.1] - 2026-05-16

### Changed
- **FTUE wizard re-sequenced**: permissions (Full Disk Access) now comes
  before messaging, since reading iMessage/WhatsApp requires FDA first.
  New order: welcome → API key → permissions → messaging → calendar →
  Notion → profile → complete.
- All four connections (Anthropic, Messages, Calendar, Notion) are now
  **required** to finish setup — Skip buttons removed.

### Added
- **Verify-then-advance**: each connection step verifies it actually works
  before advancing (API key live-tested, FDA must be granted, Google/Notion
  must be connected). Styled inline errors replace alert() popups.
- **Resume-from-step**: the wizard resumes after the last completed step
  if setup is interrupted.
- **FTUE instrumentation**: per-step view timestamps; furthest-step-reached
  is observable for support.

### Companion
- Public self-serve onboarding web guide at `/onboarding/` (download →
  Anthropic key with real screenshots → install with drag animation).

## [2.3.0] - 2026-05-06

### Added
- **Distribution build pipeline** (`scripts/build-dmg.sh`): hardened-runtime
  signing with a real Developer ID, notarization via `notarytool`, ticket
  stapling for both the app bundle and the DMG. Auto-detects distribution
  vs ad-hoc fallback based on `DEVELOPER_ID` env var.
- **Hardened-runtime entitlements** (`Config/Alfred.entitlements`): minimal
  set (`allow-jit`, `disable-library-validation`) for Swift + system libs.
- **`NSContactsUsageDescription`** in Info.plist (required for notarization
  since the app calls `CNContactStore`).
- **Public landing page** at `landing/` — late-night dark palette, synthetic
  device mocks, Formspree-backed access form. Served via GitHub Pages.

### Fixed
- Meeting brief was misclassifying external attendees as internal.
- Token utilisation tightened across briefing + commitment scan paths.

### Changed
- Dropped public Bill Campbell / Matt Mochary attribution references.

## [1.5.4] - 2026-01-31

### Added
- **Hot-Reload System**: Edit web UI, prompts, and config without server restart
  - Web UI served from `~/.config/alfred/web/` - edit and refresh browser
  - AI prompts externalized to `~/.config/alfred/prompts/` - changes apply on next API call
  - New endpoints: `GET /api/hot-reload/status`, `POST /api/reload-config`
  - Auto-copies default files on first run
- **HotReloadManager**: Central manager for hot-reloadable resources
  - Handles web file serving, prompt loading, and config reloading
  - Variable substitution in externalized prompts (e.g., `{{USER_NAME}}`, `{{COUNTERPARTY_NAME}}`)

### Fixed
- **Commitment counterparty names**: Now shows contact names (e.g., "Alex Johnson") instead of raw WhatsApp IDs
  - Added `threadName` to `CommitmentExtractionRequest` struct
  - Updated AI prompt to use human-readable names for `committedBy`/`committedTo` fields
- **Correction tracker date parsing**: Fixed ISO8601 date decoding for stored corrections

### Changed
- Web files now served from disk (hot-reloadable) instead of embedded in binary
- Prompts can be customized without recompiling

### Technical
- New file: `Sources/Core/HotReloadManager.swift`
- Default prompt files: `commitment-extraction.prompt`, `todo-extraction.prompt`, `message-analysis.prompt`

---

## [1.5.3] - 2026-01-30

### Added
- **Tweet-Card Style Approval UI**: Compact, scannable cards for extracted items
  - Colored left border indicating type (red=I Owe, teal=Owed to Me, gray=Todo, purple=Follow-up)
  - Grouped sections: "What I Owe", "What's Owed to Me", "Todos", "Follow-ups"
  - Hidden checkbox appears on hover/selection for cleaner visual
  - Direction arrows (→/←) with counterparty names for commitments
  - Truncated descriptions with source metadata tags
- **Arrow Format in Notion Task Titles**: Commitments now show direction at a glance
  - Format: `→ John: Review proposal` (I Owe) or `← Sarah: Send budget` (Owed to Me)
  - Visible in Notion database list view without opening the task
  - Simplified description with arrow header and truncated context
- **User Correction Tracking**: Learning from deselections
  - Tracks false positives when users deselect extracted items
  - API endpoint `POST /api/corrections` for correction logging
  - Foundation for AI prompt improvements based on user feedback

### Changed
- Email notifications now use clean HTML formatting matching web UI
  - Stat cards with big numbers and labels
  - Color-coded priority items with left borders
  - Calendar events with blue left border
  - External meeting tags
- CLI help text fixed: `--notify` flag (was incorrectly documented as `--email`)

### Technical
- New CSS classes: `.approval-card`, `.approval-card-body`, `.approval-card-direction`, `.approval-card-checkbox`, `.approval-section-header`
- Indicator classes: `.iowe` (red), `.theyowe` (teal), `.todo` (gray), `.followup` (purple)
- `renderApprovalCard()` helper for tweet-style card rendering
- `toggleApprovalCard()` with correction tracking on deselection
- `recordCorrection()` async function for API logging

---

## [1.5.0] - 2026-01-29

### Added
- **Real-Time Progress Tracking**: SSE (Server-Sent Events) streaming for long-running operations
  - New streaming endpoints: `/api/stream/briefing`, `/api/stream/messages`, `/api/stream/calendar`
  - Live progress updates with step-by-step status messages
  - Progress percentage display during API operations
- **Horizontal Compact Progress UI**: Notion-inspired loading indicator
  - Single-line layout: `[spinner] [5 dots] [status text] [percentage]`
  - Fixed 5-dot progress indicator (gray → blue active → green complete)
  - Smooth CSS transitions for state changes
  - Matches user message bubble height for visual consistency
- **Frontend Streaming Support**
  - New `streamRequest()` function for SSE handling with fetch API
  - `updateProgress()` function to manage dot states and status text
  - `progressStepCounters` tracking per loading instance

### Changed
- Progress UI redesigned from vertical timeline to horizontal compact single-line
- Loading message bubbles now match user message bubble sizing (`padding: 12px 16px`)
- Removed redundant progress bar (dots + percentage sufficient)
- Consolidated progress elements into single flex row

### Fixed
- **localStorage key mismatch**: Fixed `alfredSessionToken` vs `alfred_auth_token` inconsistency
- **Config loading priority**: Passcode no longer reverts unexpectedly
- **CSS specificity**: Added `!important` to ensure loading state styles override assistant styles

### Technical
- New CSS classes: `.progress-container`, `.progress-steps-row`, `.progress-step`, `.progress-step-dot`, `.progress-step-line`, `.progress-status-text`, `.progress-status-percent`, `.progress-mini-spinner`
- State classes: `.active` (blue with glow), `.complete` (green)
- SSE response parsing with `text/event-stream` content type
- Step counter management for multi-step progress tracking

---

## [1.4.2] - 2026-01-27

### Added
- **Smart Notes Retrieval**: Intelligent context-aware notes for briefings and meetings
  - Extracts keywords from attendee names, companies, and email domains
  - Uses Notion Search API for keyword-based note discovery
  - Fetches note content (first 1000 chars) for relevance scoring
  - Ranks notes by relevance (title match: 10pts, content match: 5pts, recency boost)
  - Falls back to recent notes when no keywords available

### Fixed
- **Notion "Due Date" property error**: Fixed sort property mismatch
  - Changed from "Due" to "Due Date" to match unified Tasks database schema
  - Fixed in both CLI and GUI NotionService implementations
- **Config priority for Tasks database**: Top-level `notion.tasks_database_id` now takes priority
  - Checks `notion.tasks_database_id` first
  - Falls back to `notion.briefing_sources.tasks_database_id`
  - Consistent behavior across CLI, GUI, and API

### Changed
- `queryRelevantNotes()` now uses smart search instead of date-only filtering
- `generateBriefingContext()` includes attendee names and emails for better note matching
- `generateCalendarContext()` includes attendee info for meeting prep notes

### Technical
- New NotionService methods:
  - `extractSearchKeywords(from:)` - Regex extraction of names/companies
  - `searchNotesWithKeyword(_:databaseId:)` - Notion Search API integration
  - `fetchNoteContent(pageId:)` - Block children API for content retrieval
  - `queryRecentNotes(databaseId:limit:)` - Fallback for no keywords
  - `rankNotesByRelevance(notes:keywords:)` - Scoring and sorting
- Updated config loading in NotionService.init, HTTPServer, BriefingOrchestrator

## [1.4.1] - 2026-01-27

### Added
- **Interactive Task Approval**: Y/N/S prompts before adding items to Notion
  - Commitment scanning (`alfred commitments scan`) now prompts for approval
  - Todo scanning (`alfred notion-todos`) now prompts for approval
  - Focused thread analysis (`alfred messages whatsapp "Name"`) extracts commitments + actions
  - Select mode allows choosing individual items to add
- **ExtractedItem Model**: Unified model for commitments, todos, and follow-ups
  - Standardized format for displaying extracted items
  - Conversion to TaskItem for Notion storage
  - Factory methods from Commitment, TodoItem, and FollowupReminder
- **BriefingOrchestrator Enhancements**
  - `extractWhatsAppTodosForReview()` - Extract todos without auto-saving
  - `saveExtractedItems()` - Batch save approved items to Notion
- **Web UI Interactive Approval**
  - New "Scan Todos" button with lookback period selection and approval UI
  - New "Analyze Thread" button to extract actions from specific conversations
  - Visual item approval with checkboxes for selecting which items to add
  - Select/deselect all functionality with item count display
  - Type and priority indicators for each extracted item
- **Extraction API Endpoints**
  - `POST /api/extract/todos` - Extract todos for review without auto-saving
  - `POST /api/extract/thread` - Extract items from specific thread
  - `POST /api/extract/approve` - Save approved items to Notion

### Changed
- Commitment scan now collects items first, then prompts for approval
- Todo scan now collects items first, then prompts for approval
- Focused WhatsApp thread analysis includes commitment extraction
- All extraction commands provide consistent Y/N/S interactive prompts
- Web UI "Scan Todos" now shows approval UI instead of auto-adding items
- **Unified Tasks Database**: Consolidated all storage to single Notion database
  - Commitments, Todos, and Follow-ups now all stored in `tasksDatabaseId`
  - Legacy `commitments.notionDatabaseId` config no longer required
  - Simplified configuration: just set `notion.tasks_database_id`
  - All extraction and query operations use unified Tasks database

### Technical
- New `ExtractedItem.swift` model with `ItemType`, `ItemPriority`, `ItemSource`
- Interactive prompt helper: `parseTimeframeToHours()`
- Deduplication checks during extraction phase
- AlfredService extraction methods for GUI support
- HTTPServer handlers for extraction and approval endpoints
- New CSS styles for approval item list with checkboxes
- NotionService+Tasks compatibility methods:
  - `queryActiveCommitmentsFromTasks()` - Query commitments from unified DB
  - `queryOverdueCommitmentsFromTasks()` - Query overdue commitments
  - `queryUpcomingCommitmentsFromTasks()` - Query upcoming commitments
  - `findCommitmentByHashInTasks()` - Deduplication check
  - `createCommitmentInTasks()` - Create commitment in unified DB
- Removed dependency on legacy `commitments.notionDatabaseId` across all services

## [1.4.0] - 2026-01-26

### Added
- **Proactive Agent Insights**: Agents now surface insights without being asked
  - Daily briefings include agent observations, commitment reminders, and cross-agent suggestions
  - New `AgentInsights` section in briefings with proactive notices
  - Communication + Calendar coordination suggestions
- **Unified Commitments & Follow-ups**: Single view for all commitments
  - "I Owe" - commitments you made
  - "They Owe Me" - commitments others made
  - "Follow-ups" - reminders to check on things
  - Overdue indicators and due dates
- **Daily Agent Digest**: End-of-day summary of agent activity
  - CLI: `alfred digest` to generate and optionally email digest
  - API: `GET /api/agent-digest`
  - Web UI: New "Agent Digest" quick action button
  - Summary of decisions, learnings, and recommendations
- **Cross-Agent Coordination**: Agents now share context and work together
  - `SharedContextService` for inter-agent communication
  - Agents can raise alerts for other agents
  - Cross-agent suggestions (e.g., "wait until after meeting to message")
  - Activity tracking across all agents
- **Follow-up Task Type**: Unified Tasks database now supports Follow-ups
  - TaskItem model extended with `.followup` type
  - Follow-ups stored in Notion alongside Todos and Commitments
  - Automatic deduplication using hash
- **Web UI Improvements**
  - Updated Commitments button shows unified view (I Owe, They Owe Me, Follow-ups)
  - New Agent Digest quick action button
  - Better commitment formatting with overdue indicators

### Changed
- DecisionLog now uses singleton pattern for consistent tracking
- AgentManager integrates SharedContextService for cross-agent awareness
- BriefingOrchestrator includes `generateAgentDigest()` method
- NotionService+Tasks supports Follow-up type in schema

### Technical
- New `SharedContextService` for agent coordination
- Extended `AgentProtocol` with optional cross-agent methods
- `AgentDigest` and related models for daily summaries
- 1 new API endpoint: `/api/agent-digest`

## [1.3.1] - 2026-01-26

### Added
- **Agent Memory System**: Persistent, transparent learning for all agents
  - Markdown-based memory files (`~/.alfred/agents/[agent]/memory.md`)
  - Skills documentation (`~/.alfred/agents/[agent]/skills.md`)
  - User-taught rules with highest priority in AI prompts
  - Contact-specific patterns and learned preferences
- **Teach Mode**: Train agents with explicit rules
  - CLI: `alfred teach [agent] "rule"`
  - Web UI: Agents panel with teach form
  - API: `POST /api/agents/teach`
- **Memory Viewing**: Full transparency into what agents know
  - CLI: `alfred agents memory [agent]` and `alfred agents skills [agent]`
  - Web UI: Click any agent to view memory, rules, and skills
  - API: `GET /api/agents/memory` and `GET /api/agents/skills`
- **Learning Consolidation**: Automatic pattern extraction from usage
  - High-confidence patterns from `learning.db` consolidated to memory files
  - CLI: `alfred agents consolidate` and `alfred agents status`
  - API: `POST /api/agents/consolidate` and `GET /api/agents/status`
- **Web UI Agents Panel**: New 🧠 Agents quick action
  - View all 4 agents with memory stats
  - Detailed view with rules, patterns, and skills
  - Teach form with agent selector and context field
  - Delete rules with one click

### Changed
- All agents now use memory context in AI prompts (CommunicationAgent, TaskAgent, CalendarAgent, FollowupAgent)
- CommunicationAgent includes user-taught rules, style preferences, and contact patterns in drafts
- TaskAgent uses memory when categorizing meetings
- Improved agent initialization with shared AgentMemoryService

### Technical
- New `AgentMemoryService` singleton for memory/skills management
- SQLite integration for learning.db queries during consolidation
- 7 new API endpoints for agent management

## [1.3.0] - 2026-01-26

### Added
- **Web Interface**: New Notion-inspired web UI accessible from any device
  - 7 quick action buttons with interactive forms
  - Date picker for calendar queries
  - Contact/timeframe selection for messages and commitments
  - Mobile-friendly responsive design
- **HTTP API Server**: Full REST API for all Alfred features
  - `/api/briefing` - Daily briefings
  - `/api/calendar` - Calendar events with date/calendar filtering
  - `/api/messages/summary` - Message summaries by contact
  - `/api/commitments` - Commitment tracking
  - `/api/commitment-check` - Check commitments with specific people
  - `/api/todos/scan` - Extract todos from messages
  - `/api/attention-check` - Focus and attention alerts
- **Query Caching**: SQLite-based caching for API responses
  - Configurable TTL per endpoint
  - Faster repeat queries
  - Cache clear endpoint
- **Intent Recognition**: Natural language query processing
- **Passcode Authentication**: Secure access via URL parameter or header

### Changed
- Improved date parsing to handle multiple formats (ISO8601 full and date-only)
- Better error messages and response formatting
- Updated `config.example.json` with API configuration section

### Fixed
- Calendar date selection bug where future dates showed today's results
- Passcode authentication in API calls

### Removed
- Desktop SwiftUI app (replaced by more flexible web interface)

## [1.2.0] - 2026-01-20

### Added
- **Commitments Tracker**: AI-powered extraction of commitments from messages
  - Scan messages for "I owe" and "They owe me" commitments
  - Store in Notion database
  - Flexible lookback period syntax (7d, 2w, etc.)
- Commitment check by person/group
- Overdue commitments tracking

### Changed
- Enhanced commitment analysis with better AI prompts
- Improved Notion integration for commitment storage

## [1.1.0] - 2026-01-17

### Added
- **Autonomous Agent System**: Specialized agents for different tasks
  - Communication Agent: Generates personalized message drafts
  - Task Agent: Identifies action items and deadlines
  - Calendar Agent: Suggests meeting scheduling
  - Follow-up Agent: Tracks conversations needing follow-up
- **Learning Engine**: Learns from training examples to match your communication style
- Agent decision logging for transparency

### Changed
- Improved briefing generation with agent insights
- Better message analysis with context awareness

## [1.0.0] - 2026-01-15

### Added
- Initial release
- Google Calendar integration (multiple accounts)
- Message reading from iMessage, WhatsApp, Signal
- Daily briefing generation
- Meeting preparation briefs
- Attention defense alerts
- CLI interface
- Notion integration for contacts
- Email notifications
- Slack webhook support

---

## Version History Summary

| Version | Date | Highlights |
|---------|------|------------|
| 1.5.3 | 2026-01-30 | Tweet-card approval UI, arrow format in Notion titles, email formatting |
| 1.5.0 | 2026-01-29 | Real-time SSE progress streaming, horizontal compact progress UI |
| 1.4.2 | 2026-01-27 | Smart notes retrieval, Due Date fix, config priority |
| 1.4.1 | 2026-01-27 | Interactive task approval with Y/N/S prompts |
| 1.4.0 | 2026-01-26 | Proactive insights, unified commitments, agent digest, cross-agent coordination |
| 1.3.1 | 2026-01-26 | Agent memory system, teach mode, learning consolidation |
| 1.3.0 | 2026-01-26 | Web interface, HTTP API, query caching |
| 1.2.0 | 2026-01-20 | Commitments tracker with AI extraction |
| 1.1.0 | 2026-01-17 | Autonomous agent system |
| 1.0.0 | 2026-01-15 | Initial release |
