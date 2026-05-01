# Coach Alfred

**Your AI coach for consequential work.** Alfred embeds into the way you operate — your messages, calendar, notes, and commitments — watches patiently with a keen lens of excellence, and pushes you toward the 10x version of yourself. Not a dashboard. Not an assistant. A coach.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![Version](https://img.shields.io/badge/version-2.2.2-green)

---

## The idea

Most productivity tools make you do the organizing. Alfred flips that. It runs continuously on your Mac — embedded in your messages, calendar, tasks, and notes — then coaches you across five surfaces:

1. **A conversation-first chat** you can talk to naturally — it understands every capability and acts on it
2. **A home dashboard** with live coaching cards, your pinned focus, and at-a-glance state
3. **A morning briefing email** from Coach Alfred that opens with coaching — not noise
4. **Push notifications** that nudge you after meetings, flag overdue commitments, and protect your focus time
5. **A reflection layer** that tracks what you're thinking about — not just what you're doing

The coaching voice draws on two complementary methods:
- **Relational** — warm, team-first, asks "what's the one thing?" before every meeting
- **Direct** — ruthlessly tactical, names avoidance patterns and relationship debt out loud

Alfred doesn't just know these methods — it learns *you*. Over weeks and months, it builds a trust relationship, remembers your patterns, and adjusts its coaching voice from gentle observation to direct challenge.

---

## What's new in v2.2.2

### Cadence Control — Full visibility and control over your automation

Alfred's cadence system is the engine that runs your daily briefings, commitment scans, pattern learning, and more. This release gives you complete control over what was previously invisible.

**Grouped layout** — cadences organized by frequency (Daily / Weekly / Recurring) so you can see the shape of your automation at a glance.

**Inline toggles** — pause or resume any cadence with a single tap. No popover needed for the most common operation.

**Parameter editing** — configure tool-specific settings directly in the UI. Add groups to Auto Summary, change lookback days for Todo Scan, set scan modes for Commitment Scan — all from the edit popover instead of hand-editing JSON.

**Active hours** — interval cadences now expose start/end hour controls so you can prevent scans from running at 3am.

**Run output previews** — tap any last-run timestamp to see what the cadence actually produced. Summaries are now persisted and surfaced ("Morning briefing generated with 4 action items", "Todo scan: found 3, created 2, dupes 1").

**Status indicators** — green (success), red (failure), pulsing yellow (cooldown), gray (disabled/never ran). At a glance, you know what's healthy and what needs attention.

**Tool descriptions** — one-line summaries under each cadence name so you know what "Pattern Learning" or "Attention Check" actually does.

**New built-in cadences** — Coaching Sync (weekly Notion sync of coaching context) and Task Lifecycle Scan (daily scan for task state changes) are now visible and configurable.

**Smarter create flow** — selecting a tool auto-fills its description, default schedule, and parameter fields with sensible defaults.

### Previous highlights

**Enhanced Chat Experience (v2.2.1)** — Alfred Chat understands and acts on every capability. 14 new chat capabilities wired: Focus Pins, Reflection Themes, Open Questions, Memory & Learning, Cadences, Favorites, Meeting Briefs, Calendar Availability, Contact Analysis, Conversation History, Active Skills, Todo CRUD, Pending Closures, Forget/Unlearn. Smarter Notion task search with progressive 3-tier strategy. Coaching posture routing keeps coaching on-topic per intent.

**Reflection Mode (v2.1.0)** — Alfred as thinking partner. Ingests Chrome history, YouTube transcripts, Notion Second Brain, Claude exports, and manual captures to build a living map of your intellectual landscape. Extracts active themes, open questions, mental model shifts, and decisions. Themes decay at 5% per day unless reinforced.

**Memory Notion Sync (v2.1.0)** — "What Alfred Knows About You" published as a read-only Notion page, updated during daily pattern computation.

**Unified Memory Index (v2.1.0)** — All of Alfred's knowledge consolidated into a single queryable layer: learned patterns, coaching themes, user rules, and reflection context.

---

## How it works

### Chat-first interface

Alfred's primary surface is a conversation. No dashboards, no tabs — you talk to Alfred and it talks back with full context.

- **Natural language** — Ask anything: "What do I owe Steve?", "Prep me for my 3pm", "What am I avoiding?"
- **Slash commands** — `/calendar`, `/commitments`, `/messages`, `/todos`, `/1on1`, `/roast` with inline parameter forms
- **Suggestion chips** — Contextual prompts that appear based on time of day and state
- **Streaming responses** — SSE-powered real-time chat with tool execution indicators
- **Multi-turn context** — Alfred remembers the last 3 turns per session
- **Focus card** — Your top task pinned at the top with Done/Change affordances

### Coaching Skills library

Alfred's coaching is driven by **skills** — modular coaching programs that each have their own data sources, tenets, and prompts. Skills are Markdown files, fully readable and editable.

**5 built-in skills** ship with Alfred:

| Skill | Frequency | What it surfaces |
|-------|-----------|-----------------|
| **Leverage** | Daily | The single highest-impact action right now |
| **Relationship** | Daily | Who needs your attention — based on message and commitment data |
| **Avoidance** | Daily | What you're putting off, and why it matters |
| **Attention** | Daily | Where your attention is actually going vs. where it should be |
| **Weekly Review** | Weekly | End-of-week assessment with direct-method framing |

**Skill anatomy** (each `.md` file):
```markdown
---
Name: Leverage
Description: Identifies highest-leverage action
Icon: 🎯
Author: Relational Method
Version: 1.0
Frequency: daily
Data Sources: tasks, calendar, commitments
Fallback: Focus on the one thing that makes everything else easier.
---

## Tenets
- Never suggest more than one action
- Weight by deadline proximity and relationship importance

## Prompt
Given the user's active tasks, today's calendar, and open commitments...
```

**Two tiers:**
- **Installed skills** (`~/.alfred/skills/installed/`) — Coach-authored, read-only. Users toggle on/off.
- **User skills** (`~/.alfred/skills/user/`) — Create your own coaching programs with custom data sources and prompts.

Tenet-only skills (frequency: `none`) inject coaching principles into every conversation without generating their own cards.

### Trust progression

Alfred's coaching voice evolves as it learns you:

| Level | Threshold | Coaching style |
|-------|-----------|---------------|
| **New** | < 5 sessions | Observational questions, light suggestions |
| **Developing** | 5+ sessions, 7+ days, 1+ resolved theme | Pattern recognition, specific nudges |
| **Established** | 20+ sessions, 30+ days, 3+ resolved themes | Direct recommendations, calling out avoidance |
| **Deep** | 50+ sessions, 90+ days, 5+ resolved themes | Blunt challenge, high-context accountability |

Trust never demotes — but if you're inactive for 60+ days, it caps at Established until you're back in rhythm.

### Self-improving learning

Alfred gets sharper the longer it watches you. Five learning systems run continuously:

**1. Commitment closure accuracy**
When Alfred detects a commitment was completed, it scores confidence:
- ≥ 0.85 → auto-closes the commitment
- 0.60–0.84 → asks you to confirm
- < 0.60 → ignores

Your confirm/reject feedback trains the model over time.

**2. Thread quality scoring**
Alfred learns which contacts and groups yield high-quality extractions vs. noise. Low-signal threads get scanned less aggressively.

**3. Counterparty reliability**
Tracks who completes commitments on time and who doesn't. This data feeds into relationship coaching.

**4. Workflow patterns**
Computes your most productive days, task completion rates by type, and triage patterns. Injected into coaching prompts so Alfred coaches with *your* data, not generic advice.

**5. Reflection context** *(v2.1.0)*
Builds an evolving understanding of your intellectual landscape — what you're researching, deciding, creating, and monitoring — and weaves it into every coaching interaction. Alfred doesn't just know what's on your calendar; it knows what's on your mind.

All learning is stored in `workflow_learning.db` and `reflection.db`. Computed patterns are refreshed on cadence.

### Morning briefing email

Sent automatically at your configured time from **Coach Alfred**:
- Coaching cards generated by your active skills (Leverage, Relationship, Avoidance)
- Today's schedule with AI-generated prep notes for external meetings
- Message analysis across WhatsApp, iMessage, Signal
- Prioritized action items with due dates and context
- Commitment reminders — what you owe, what's owed to you

### Commitment tracking

Scans your WhatsApp, iMessage, and Signal conversations for commitments — things you've promised ("I'll send that over") and things owed to you ("Let me get back to you"). The system:

- Detects participation level (active vs. observer) to filter noise in group chats
- Tracks both directions: `i_owe` and `they_owe`
- Creates Notion tasks automatically for each commitment
- Runs closure detection against recent messages
- Self-improves confidence thresholds based on your feedback
- Dashboard shows open, pending-closure, and recently-closed commitments by counterparty

### Notion integration

Alfred treats Notion as your operational backbone:

- **Tasks database** — Reads active tasks for briefings, creates new tasks from chat and commitment scans
- **Commitments database** — Auto-created if missing, tracks both directions with source thread, platform, due date, and priority
- **Second Brain** — Pulls context from your notes databases for meeting prep and coaching
- **Coaching sync** — Persistent coaching memory (themes, patterns, follow-ups) syncs to a Notion page
- **Memory sync** — "What Alfred Knows About You" published as a read-only Notion page *(v2.1.0)*
- **Reflections** — Weekly reflection narratives saved to a dedicated Notion database *(v2.1.0)*
- **Playbook sync** — Procedures and playbooks stored in Notion, referenced during coaching

### Intent recognition

When you talk to Alfred, it first recognizes your **intent** using a fast classifier, then routes to the right tool:

| Target | Actions | What Alfred does |
|--------|---------|-----------------|
| `calendar` | list, check, create, update, delete | Fetches schedule, checks availability, manages events |
| `commitments` | list, scan, check | Shows dashboard, scans for specific person, tracks closures |
| `messages` | find, summarize, analyze | Summarizes threads, analyzes groups, extracts action items |
| `thread` | find, analyze | Deep-dives into specific contact conversations |
| `tasks` | list, find, update, create, delete | Full Notion task CRUD — search, status changes, priority |
| `todos` | list, update, delete | Message-extracted todo management |
| `meeting` | generate | AI-powered meeting brief with attendee context |
| `briefing` | generate, summarize | Morning briefing with coaching cards |
| `focus` | list, generate, create, delete | Pin/unpin top goal, suggest focus from active tasks |
| `reflections` | list, analyze, summarize | Themes, open questions, theme deep-dives |
| `memory` | list, create, delete | View learned patterns, teach rules, forget |
| `cadences` | list, scan | Show cadence status, trigger manual runs |
| `favorites` | list, create, delete | Manage favorite contacts and groups |
| `contacts` | analyze | Contact participation analysis |
| `conversations` | list | Recent conversation history |
| `skills` | list | Active coaching skills and their descriptions |
| `attention` | check | Mid-day focus defense with prioritization |
| `drafts` | generate | AI-drafted responses with communication coaching |

The intent router also detects **person mentions** and **commitment keywords** in your messages, automatically injecting the relevant commitment ledger and recent message excerpts into the coaching context. Each intent maps to a **coaching posture** (reflection, prioritization, accountability, planning, deep reflection, or operational) so Alfred's follow-up coaching stays on-topic.

### Attention defense

A 3PM check-in that asks: given what's left today, what must get done and what can wait? Sent via email with coaching framing.

### Agent memory

Alfred maintains three layers of persistent memory:
- **Coaching memory** (`~/.alfred/coaching_context.md`) — Active themes, resolved themes, session log, personality notes, open follow-ups. Compounds across sessions.
- **User-taught rules** — Explicit preferences you teach Alfred ("always be brief with Bob", "don't flag messages from the family group"). Stored as transparent, editable markdown files.
- **Reflection memory** (`~/.alfred/reflection.db`) — Themes, open questions, mental model shifts, and decisions extracted from your browsing, watching, reading, and thinking. Decays and reinforces over time. *(v2.1.0)*

---

## Platform architecture

Alfred is a single Swift binary that runs as a macOS LaunchAgent. One process, one port, always on.

```
┌──────────────────────────────────────────────────────────────────┐
│                      Coach Alfred v2.2.2                         │
│                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ Coaching  │  │  Skills  │  │  Trust   │  │   Learning     │  │
│  │  Engine   │  │  Loader  │  │ Service  │  │    Engine      │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───────┬────────┘  │
│       │              │             │                 │            │
│  ┌────▼──────────────▼─────────────▼─────────────────▼────────┐  │
│  │                    Unified Memory Index                      │  │
│  │  coaching themes + user rules + reflections + patterns      │  │
│  └─────────────────────────┬──────────────────────────────────┘  │
│                             │                                    │
│  ┌──────────────────────────▼─────────────────────────────────┐  │
│  │                    Intent Router + Chat                     │  │
│  │       (recognizes intent → executes tool → overlays coach)  │  │
│  └─────────────────────────┬──────────────────────────────────┘  │
│                             │                                    │
│  ┌──────────────────────────▼─────────────────────────────────┐  │
│  │                     HTTP API Server                         │  │
│  │                      (Port 8080)                            │  │
│  │   /api/chat  /api/briefing  /api/reflect  /api/memory      │  │
│  └──────────────────────────┬─────────────────────────────────┘  │
│                              │                                   │
│  ┌────────┬────────┬─────────┼─────────┬────────┬────────┐      │
│  │ Google │ iMsg   │WhatsApp │ Notion  │ Claude │  SMTP  │      │
│  │  Cal   │        │ Signal  │  API    │   AI   │ Email  │      │
│  └────────┴────────┴─────────┴─────────┴────────┴────────┘      │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Reflection Ingestion (Chrome, YouTube, Notion, imports) │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Cadence Scheduler (60s tick, catch-up, dedup, retry)    │    │
│  └──────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

**Data flow:**
1. Cadence scheduler evaluates all enabled cadences every 60 seconds
2. When a cadence fires, the Runner dispatches to the appropriate tool
3. Tools fetch data from integrations (messages, calendar, tasks) in parallel
4. Reflection ingestion pulls from Chrome, YouTube, Notion, and import folder
5. Skills generate coaching cards using their configured data sources and prompts
6. Claude AI analyzes context — including reflection themes — coaches with trust-calibrated voice, and streams responses
7. Learning engine records feedback, computes accuracy patterns, and updates the Unified Memory Index
8. Results are delivered via email, chat UI, and notifications

**Privacy model:**
- All message processing happens locally on your Mac
- Message databases (iMessage, WhatsApp) are read directly from disk — no cloud sync, no forwarding
- Chrome history and YouTube data are read locally — never uploaded
- Only Claude API calls leave the machine, and only with the context needed for that specific request

---

## Cadences — 13 configurable automations

Every recurring action in Alfred is a **cadence** — a scheduled tool with its own timing, parameters, and notification preferences:

| Cadence | Default | What it does |
|---------|---------|-------------|
| Morning Briefing | 08:15 daily | Coaching cards + calendar + messages → email |
| Attention Check | 15:00 daily | Mid-day focus defense alert |
| Todo Scan | Every 3 hours | Extract action items from messages |
| Commitment Scan | 17:00 daily | Track promises + detect closures |
| Auto Summary | 18:00 daily | Summarize high-volume groups |
| Pattern Learning | Thursday 18:00 | Compute workflow patterns from feedback |
| Reflection Ingestion | Daily | Ingest browsing, videos, notes → reflection themes *(v2.1.0)* |
| Group Analysis | Monday 09:00 | Analyze group chat health |
| Weekly Review | Friday 17:00 | Direct-method weekly assessment |
| Message Summary | On-demand | Per-thread deep summary |
| Playbook Sync | On-demand | Sync playbooks from Notion |
| Coaching Sync | On-demand | Sync coaching context to Notion |
| Task Lifecycle | On-demand | Track task state changes |

All cadences are fully editable. Create unlimited custom ones via the API or Settings UI.

---

## Quick start

### Prerequisites

- macOS 13+ (Ventura or later)
- Xcode Command Line Tools: `xcode-select --install`
- [Anthropic API key](https://console.anthropic.com/)
- [Google Calendar OAuth credentials](https://console.cloud.google.com/)

### Install

```bash
git clone https://github.com/mitensampat/alfred.git
cd alfred

# Build
swift build -c release

# Install
cp .build/release/Alfred /Applications/Alfred.app/Contents/MacOS/Alfred
codesign --force --sign - --identifier com.msfoundry.alfred \
  /Applications/Alfred.app/Contents/MacOS/Alfred

# Start
launchctl load ~/Library/LaunchAgents/com.msfoundry.alfred.plist
```

**Important:** After every build, re-grant Full Disk Access to `/Applications/Alfred.app` in System Settings → Privacy & Security, then restart via `launchctl unload/load`.

### First run

Open `http://localhost:8080` — the FTUE wizard walks you through 8 steps: Claude API → Notion → Google Calendar → Profile → Message Sources → Permissions → Launch. Takes about 5 minutes.

### Access

```
# Chat UI
http://localhost:8080/home.html?passcode=YOUR_PASSCODE

# Health check
curl "http://localhost:8080/api/health?passcode=YOUR_PASSCODE"
```

---

## Configuration

See [SETUP.md](SETUP.md) for the full guide.

### Required

| Setting | Purpose |
|---------|---------|
| `ai.anthropic_api_key` | Claude AI for analysis and coaching |
| `calendar.google` | Google Calendar OAuth (read + write) |
| `app.passcode` | Web access security |
| `user.name` / `user.email` | Your identity |

### Optional integrations

| Integration | What it enables |
|-------------|----------------|
| **Notion** | Tasks, commitments, Second Brain, coaching sync, memory sync, reflections |
| **Gmail** | Email threads in briefings |
| **SMTP** | Morning briefing email from Coach Alfred |
| **Signal** | Signal message scanning |

### Reflection Mode configuration

```json
{
  "reflection": {
    "enabled": true,
    "chromeEnabled": true,
    "notionEnabled": true,
    "youtubeTranscripts": true,
    "importFolderEnabled": true,
    "chromeProfilePath": "Default",
    "noiseDomains": ["google.com", "github.com"],
    "dwellTimeSeconds": 30
  }
}
```

Drop Claude conversation exports, articles, or notes into `~/.alfred/imports/` — Alfred will ingest them automatically.

---

## Security & privacy

- **Privacy-first**: All message processing happens locally — your conversations never leave your Mac
- Message databases (iMessage, WhatsApp, Signal) are read directly from disk — no cloud APIs, no forwarding
- Chrome history and YouTube data are read from local databases — never uploaded to third parties
- Only Claude API calls leave the machine, scoped to the minimum context needed
- Passcode-protected API and web interface
- Full Disk Access required for message database reading (gated by macOS TCC)
- Config file contains credentials and is git-ignored
- Codesign with stable bundle identifier preserves TCC permissions across builds
- Graceful SIGTERM/SIGINT shutdown with startup retry for crash resilience

---

## Built with

- [Swift](https://swift.org/) — single binary, no runtime dependencies
- [Anthropic Claude](https://www.anthropic.com/) — coaching, analysis, intent recognition, and reflection extraction
- [Google Calendar API](https://developers.google.com/calendar) — schedule data + event creation
- [Notion API](https://developers.notion.com/) — tasks, commitments, knowledge management, and reflection storage

---

*Coach Alfred — sharpen your genius.*
