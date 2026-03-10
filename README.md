# Coach Alfred

**An AI coaching platform for leaders.** Alfred runs silently on your Mac, ingests your real communication, calendar, and task data — then coaches you with the instincts of Bill Campbell and the systems of Matt Mochary. You wake up knowing what matters, who needs attention, and what you're avoiding.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)

---

## The idea

Most productivity tools make you do the organizing. Alfred flips that. It's a platform that runs continuously on your Mac — connecting to your messages, calendar, tasks, and notes — then delivers coaching, automation, and intelligence through three surfaces:

1. **A morning briefing email** that opens with coaching — not noise
2. **A mobile-first dashboard** you can glance at between meetings
3. **An AI chat** that reads your data, takes actions, and coaches you in context

The coaching layer is inspired by two frameworks:
- **Bill Campbell** — the Silicon Valley coach who asked "what's the one thing?" before every meeting
- **Matt Mochary** — the CEO coach who taught leaders to spot avoidance patterns and relationship debt

---

## Platform Architecture

Alfred isn't a single-purpose tool — it's a platform with three layers:

### 1. Tools Layer — 12 Configurable Actions

Every automation in Alfred is a **tool** — a self-contained action that can be scheduled, triggered manually, or combined into cadences:

| Tool | Category | What it does |
|------|----------|-------------|
| Morning Briefing | Review | Calendar + messages + coaching → email |
| Attention Check | Review | Mid-day focus defense alert |
| Todo Scan | Communication | Extract action items from WhatsApp/iMessage |
| Commitment Scan | Communication | Track promises made and owed |
| Message Summary | Communication | Summarize a specific contact or group |
| Auto Summary | Communication | Scheduled summaries for selected groups |
| Pattern Learning | Analysis | Learn from your feedback to improve accuracy |
| Group Analysis | Analysis | Identify important threads across groups |
| Weekly Review | Review | Multi-service metrics + narrative reflection |
| Playbook Sync | Sync | Push communication playbooks to Notion |
| Coaching Sync | Sync | Sync coaching insights to Notion |
| Task Lifecycle Scan | Sync | Track task state changes across systems |

### 2. Cadence Layer — Configurable Scheduling

Each tool can be wrapped in a **cadence** — a scheduled automation with its own timing, parameters, and notification preferences:

- **Schedule types**: Daily (at a specific time), Weekly (day + time), or Interval (every N hours within active window)
- **Full CRUD**: Create custom cadences, edit schedules, toggle enable/disable, delete user-created ones
- **Parameters**: Each tool accepts typed parameters (contacts, lookback days, scan modes, group lists)
- **Reliability**: Catch-up windows for missed runs, failure cooldowns with automatic retry, dedup prevention
- **8 built-in cadences** ship out of the box, fully editable. Create unlimited custom ones.

### 3. Coaching Layer — Intent-Aware Intelligence

Alfred's coaching engine doesn't just react to what you ask — it recognizes your **intent** and routes to specialized strategies:

| Intent | Coaching Strategy |
|--------|------------------|
| Task management | Prioritization, delegation, deadline awareness |
| Communication | Relationship dynamics, response patterns, follow-up |
| Reflection | Pattern recognition, avoidance detection, growth |
| Planning | Resource allocation, calendar optimization, energy management |
| Information lookup | Context enrichment, connection to past patterns |

The coaching engine generates three insights every morning, woven into the Today screen's conversation thread:

| Insight | Question it answers |
|---------|-------------------|
| **Leverage** | What's the single highest-impact thing you should do right now? |
| **Relationship** | Who needs your attention — and what does the data say? |
| **Avoidance** | What are you putting off, and why? |

Each insight shows its coaching origin (Bill Campbell, Matt Mochary, or Cal Newport method), when it was generated, and a refresh button to regenerate on demand. These also appear in your morning briefing email *before* the calendar and messages, so the strategic frame is set before the tactical noise hits.

---

## What it does

### Morning briefing email
Sent automatically at your configured time:
- Coaching insights (Leverage, Relationship, Avoidance)
- Today's schedule with AI-generated prep notes for external meetings
- Message analysis across WhatsApp, iMessage, Signal
- Prioritized action items with due dates and context

### Today screen
A conversation-first mobile dashboard (PWA) that reads like a coaching session, not a static dashboard:
- **Morning thread** — Time-stamped narrative with a personalized coach greeting, your top focus task, contextual narrative about your day, and an accountability question
- **Coaching insights** — Leverage, Relationship, and Avoidance cards woven into the thread with skill attribution breadcrumbs (Bill Campbell, Matt Mochary, Cal Newport) and one-tap refresh
- **Inline chat** — Streaming AI chat that reads your data and takes actions; "Talk to Alfred" opens a free-form input with intent-aware routing
- **Quick actions** — Calendar, Todos, Commitments + text input
- **Cadence manager** — View, edit, create, and trigger all your scheduled automations

### Calendar event creation
Create events directly from chat:
- *"Schedule a call with Alice tomorrow at 3pm about the product roadmap"*
- Alfred creates the Google Calendar event, returns a shareable link, and offers a Copy Invite button

### Commitment tracking
Scans conversations for commitments — things you owe others and things they owe you. The tracker is self-improving: auto-closure confidence thresholds adjust over time based on your confirm/reject feedback.

### Attention defense
A 3PM check-in that asks: given what's left today, what must get done and what can wait?

### Agent memory
Alfred learns your preferences over time. Teach it rules ("always be brief with Bob"), and it remembers across sessions. Memory is stored as transparent, editable files.

---

## Architecture

Alfred is a single Swift binary that runs as a macOS LaunchAgent. One process, one port, always on.

```
┌─────────────────────────────────────────────────────────────────┐
│                     Coach Alfred v2.0                            │
│                                                                 │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌────────────┐  │
│  │  Coaching  │  │  Cadence  │  │  Intent   │  │    Chat    │  │
│  │  Engine    │  │  Runner   │  │  Router   │  │   Engine   │  │
│  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘  └─────┬──────┘  │
│        │               │              │               │         │
│  ┌─────▼───────────────▼──────────────▼───────────────▼──────┐  │
│  │                     HTTP API Server                       │  │
│  │                      (Port 8080)                          │  │
│  │    /api/cadences  /api/briefing  /api/chat  /api/memory   │  │
│  └──────────────────────────┬────────────────────────────────┘  │
│                              │                                  │
│  ┌────────┬────────┬─────────┼─────────┬────────┬────────┐     │
│  │ Google │ iMsg   │WhatsApp │ Notion  │ Claude │  SMTP  │     │
│  │  Cal   │        │ Signal  │  API    │   AI   │ Email  │     │
│  └────────┴────────┴─────────┴─────────┴────────┴────────┘     │
└─────────────────────────────────────────────────────────────────┘
```

**Data flow:**
1. Cadence scheduler evaluates all enabled cadences every 60 seconds
2. When a cadence fires, the Runner dispatches to the appropriate tool
3. Tools fetch data from integrations (messages, calendar, tasks) in parallel
4. Claude AI analyzes, coaches, and generates insights
5. Results are delivered via email, notifications, and the web dashboard
6. Chat provides real-time access to the same tools with intent-aware coaching

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

# Configure
cp Config/config.example.json ~/.config/alfred/config.json
# Edit with your API keys, email settings, Notion database IDs

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

### Access

```
# Web dashboard
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
| **Notion** | Task tracking, commitment database, Second Brain context |
| **Gmail** | Email threads in briefings |
| **Slack** | Notification delivery |
| **SMTP** | Morning briefing email |

---

## Cadence API

Alfred exposes a full CRUD API for managing cadences programmatically:

```bash
# List all cadences
curl "http://localhost:8080/api/cadences?passcode=YOUR_PASSCODE"

# View available tools
curl "http://localhost:8080/api/cadences/catalog?passcode=YOUR_PASSCODE"

# Create a custom cadence
curl -X POST "http://localhost:8080/api/cadences?passcode=YOUR_PASSCODE" \
  -H "Content-Type: application/json" \
  -d '{"name":"Evening Digest","action_type":"message_summary",
       "schedule":{"type":"daily","time":"18:00"},
       "params":{"contact":"Team Chat","platform":"whatsapp","timeframe":"24h"}}'

# Trigger a cadence manually
curl -X POST "http://localhost:8080/api/cadences/run?passcode=YOUR_PASSCODE" \
  -H "Content-Type: application/json" \
  -d '{"id":"builtin-commitment-scan"}'
```

---

## Security

- Runs locally on your Mac — your data never leaves your machine except for Claude API calls
- Passcode-protected API and web interface
- Full Disk Access required for iMessage/WhatsApp/Signal reading
- Config file contains credentials and is git-ignored
- Codesign with stable identifier preserves macOS TCC permissions across builds

---

## Built with

- [Swift](https://swift.org/) — single binary, no dependencies beyond Foundation
- [Anthropic Claude](https://www.anthropic.com/) — AI analysis, coaching, and chat
- [Google Calendar API](https://developers.google.com/calendar) — schedule data + event creation
- [Notion API](https://developers.notion.com/) — task and knowledge management

---

*Coach Alfred: because the best coach doesn't just organize your day — they make you think about it differently.*
