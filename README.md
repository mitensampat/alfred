# Alfred

**Your AI chief of staff.** An always-on executive assistant that reads your messages, scans your calendar, tracks your commitments, and coaches you like Bill Campbell meets Matt Mochary — so you wake up knowing exactly what matters.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)

---

## The idea

Most productivity tools make you do the organizing. Alfred flips that. It runs silently on your Mac, ingests your real communication and calendar data, and delivers three things:

1. **A morning briefing email** that opens with coaching — not noise
2. **A mobile-first dashboard** you can glance at between meetings
3. **An AI chat** grounded in your actual day — not generic advice

The coaching layer is inspired by two frameworks:
- **Bill Campbell** — the Silicon Valley coach who asked "what's the one thing?" before every meeting
- **Matt Mochary** — the CEO coach who taught leaders to spot avoidance patterns and relationship debt

Alfred generates three coaching cards every morning:

| Card | Question it answers |
|------|-------------------|
| **Leverage** | What's the single highest-impact thing you should do right now? |
| **Relationship** | Who needs your attention — and what does the data say? |
| **Avoidance** | What are you putting off, and why? |

These appear in your email *before* the calendar and messages, so the strategic frame is set before the tactical noise hits.

---

## What it does

### Morning briefing email
Sent automatically at your configured time. Layout:

```
🧭 Your Coach Says
   🎯 Leverage — "Close the Ribbit deck today — it's blocking three downstream decisions."
   👤 Relationship — "You have 4 overdue commitments to Janani. High-trust people notice first."
   🪞 Avoidance — "The compliance audit has been 'Not Started' for 22 days. Spend 15 minutes today."

📅 Today's Schedule
   8 meetings, 5h 10m meeting time, 3h 40m focus time
   + AI-generated prep notes for each external meeting

💬 Messages Summary
   1,290 messages analyzed across WhatsApp, iMessage, Signal
   Critical threads surfaced, suggested responses drafted

✅ Action Items
   Prioritized by urgency, with due dates and context
```

### Mobile dashboard
A PWA that works on any device. Three tabs:

- **Home** — Focus Card (top task + Mark Done), Pulse metrics (tasks/overdue/meetings/reliability), Coaching Cards
- **Tools** — Calendar, Message Tracker, Commitment Scanner, Todo Extractor, Task Stats
- **Chat** — Streaming AI conversation grounded in your real data

### Commitment tracking
Alfred scans your conversations and extracts commitments — things you owe others and things they owe you. These feed into the Relationship coaching card and get stored in Notion for follow-through.

### Attention defense
A 3PM check-in that asks: given what's left today, what must get done and what can wait? Prevents end-of-day panic.

### Agent memory
Alfred learns your preferences over time. Teach it rules ("always be brief with Kunal"), and it remembers across sessions. Memory is stored as transparent, editable files.

---

## Architecture

Alfred is a single Swift binary that runs as a macOS LaunchAgent. One process, one port, always on.

```
┌──────────────────────────────────────────────────────────┐
│                     Alfred v2.0                          │
│                                                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐ │
│  │ Coaching  │  │ Briefing │  │  Agent   │  │  Chat   │ │
│  │  Engine   │  │Orchestr. │  │ Manager  │  │ Engine  │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬────┘ │
│       │              │             │              │      │
│  ┌────▼──────────────▼─────────────▼──────────────▼────┐ │
│  │                  HTTP API Server                    │ │
│  │                   (Port 8080)                       │ │
│  └──────────────────────┬──────────────────────────────┘ │
│                         │                                │
│  ┌──────┬──────┬────────┼────────┬──────┬──────┐        │
│  │Google│iMsg  │WhatsApp│ Notion │Claude│ SMTP │        │
│  │ Cal  │      │Signal  │  API   │  AI  │Email │        │
│  └──────┴──────┴────────┴────────┴──────┴──────┘        │
└──────────────────────────────────────────────────────────┘
```

**Data flow:**
1. Scheduler fires at your configured briefing time
2. Orchestrator fetches messages (iMessage, WhatsApp, Signal), calendar (Google), and tasks (Notion) in parallel
3. Claude AI analyzes conversations, generates meeting prep, extracts commitments
4. Coaching Engine takes the assembled data and generates Leverage/Relationship/Avoidance insights
5. Email is sent with coaching first, schedule second, messages third
6. Same data powers the web dashboard and chat

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

### Access

```
# Web dashboard
http://localhost:8080/index-notion.html?passcode=YOUR_PASSCODE

# Health check
curl "http://localhost:8080/api/health?passcode=YOUR_PASSCODE"
```

---

## CLI

```bash
# Morning briefing (add --notify to send email)
alfred briefing
alfred briefing tomorrow --notify

# Calendar
alfred calendar today
alfred calendar work tomorrow

# Messages
alfred messages all 24h
alfred messages whatsapp "Contact Name" 7d

# Commitments
alfred commitments scan 7d
alfred commitments check "Person Name"

# Attention defense
alfred attention

# Agent memory
alfred teach communication "Always be concise with John"
alfred agents memory communication
alfred agents status
```

---

## Configuration

See [SETUP.md](SETUP.md) for the full guide.

### Required

| Setting | Purpose |
|---------|---------|
| `ai.anthropic_api_key` | Claude AI for analysis and coaching |
| `calendar.google` | Google Calendar OAuth |
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
- [Google Calendar API](https://developers.google.com/calendar) — schedule data
- [Notion API](https://developers.notion.com/) — task and knowledge management

---

*Alfred: because the best chief of staff doesn't just organize your day — they make you think about it differently.*
