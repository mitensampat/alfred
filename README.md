# Coach Alfred

**Your Desk and your Coach for consequential work.** Alfred embeds into the way you operate — your messages, calendar, notes, and commitments — holds the state of everything you're running, and coaches you toward the 10x version of yourself. Not a dashboard. Not an assistant. A desk that keeps the work, and a coach that keeps you honest.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![Version](https://img.shields.io/badge/version-5.1.0-green)

---

## The idea

Most productivity tools make you do the organizing. Alfred flips that. It runs continuously on your Mac — embedded in your messages, calendar, tasks, and notes — and gives you two things:

**The Desk** — your primary surface. The unit isn't a thought, it's *a person with a clock* and *a front that's moving*. Three objects hold the screen:
- **The queue** — who is blocked on you, ranked by leverage, not by age
- **Fronts** — what you're actually running (a deal, a raise, a hire, a launch), each with its owner, stage, and the one decision it's waiting on
- **The margin** — relationships going cold, and your week, honestly

**The Coach** — surfaces the right thing at the right time. Tomorrow's calendar is about to overwhelm you → it tells you tonight, while you can still act. You're losing touch with important work, or a pattern is showing up on a relationship thread → it says so, proactively. Coaching runs on modular **skills** and **analysis lenses** you can turn on, off, and author yourself.

Underneath both sits **the self-model** — a durable, portable portrait of how *you* operate: your fronts, the principles you actually run on, the people in your world, and the patterns Alfred has noticed. It gets sharper the longer Alfred watches, and you can read the whole thing as a living **You-Wiki**.

---

## What's new in v5.1.0

### @schedule — the full booking flow, in Alfred or from WhatsApp

Scheduling now runs end-to-end without leaving the Desk:
- **Propose → send → book** — Alfred finds times, drafts the ask, sends it, watches the counterpart's thread for a reply, and books on a firm yes. Every step is a one-tap action in the People rail with a plain-English stage label ("waiting on them", "they replied — confirm to book").
- **Direct block** — say `block 30m with X at 4pm tomorrow topic Sync x@email` to create the event and send the invite in one shot, with a video link attached.
- **Parity everywhere** — the exact same flow works from the command palette, from `⌘K`, and from your WhatsApp self-chat. The rail auto-refreshes so replies surface on their own.

### The self-model keeps the right set

Alfred's belief set used to silt up with situational reads and stray facts. Now every belief is classified by **durability** — durable principles vs. current theses vs. bare facts vs. action items — and the model keeps only what belongs. Facts and one-off actions are archived out automatically; principles and live theses stay.

### The You-Wiki — a living portrait you can read

Alfred writes a nightly markdown compendium of what's most alive with you: the fronts you're running, what you believe (durable principles only), your working theses, the people in your world, and the recurring signals its coaching lenses have noticed. Open it as a clean rendered page at **`/wiki`**, or read the raw markdown in any editor.

### Coaching, reconnected

- **The one email** — a single, tight, plain-text morning note written like a high-quality CEO memo, not a wall of cards.
- **Evening nudge** — if tomorrow is heavy, Alfred tells you the night before.
- **Skills & lenses, fully editable** — create, toggle, and tune coaching skills and analysis lenses from the interface.
- **Insight → Model** — when you act on a coaching insight, it can persist into your self-model (and coaching *actions* are kept out of your beliefs, where they don't belong).

### Previous highlights

- **The Desk + Coach (v5.0.0)** — the primary surface rebuilt around the queue, fronts, and the margin, with a self-model that ranks by leverage.
- **Signal, without Full Disk Access (v3.1.0)** — a message source that reads without FDA, plus a WhatsApp network bridge that sends and ingests over the protocol.
- **The Self-Model (v3.0.0)** — Now / You / Model surfaces, facets as callable objects, convergence intelligence, and a portable operating model.

---

## How it works

### The Desk

The Desk is the home surface. It reads your real state and lays it out as work, not data:

- **Queue** — open commitments where the ball is in your court, ranked by leverage and asymmetry (who's blocked, what's time-critical, whose reliability data says this will slip). Clearing a row closes the commitment and stages a reply draft, with Undo. Sending stays an explicit confirm.
- **Fronts** — the things you're running, each as a card with owner, stage, and the single decision it's waiting on. Mark a front done and it moves to an archive. Fronts running without you are flagged.
- **People** — the people in your world as cards, not lines: what you owe, what they owe, on-time reliability, and a ready-to-send draft.
- **Command palette** — a `+` on the masthead (and `⌘K`) to log a thought, start a schedule, or ask Alfred — from anywhere on the Desk.

### The Coach

Coaching is driven by two composable primitives, both plain Markdown and fully editable:

- **Skills** — modular coaching programs with their own data sources, tenets, and prompts. Ship enabled or author your own. Tenet-only skills inject principles into every conversation without generating their own cards.
- **Analysis lenses** — passive detectors that run over your data and emit signals (meeting overload, relationship debt, avoidance, attention drain, leverage, calendar pressure, energy pattern). Their recurring signals feed the Coach surface and the You-Wiki.

The Coach shows up in three places: on the Desk as a "Coach moment", as an evening push when tomorrow is heavy, and in the one morning email.

### The self-model

A durable, portable model of how you operate, stored locally in `self_model.db`:

- **Facets** — themes (your fronts), beliefs (how you operate), questions (what you're holding open), and decisions (dated judgements).
- **Belief durability** — every belief is tagged `durable | tactical | fact | action`. Durable principles and live theses stay; bare facts and action items are archived out, so the model retains the right set over time.
- **Convergence** — related facets merge; stray items in the wrong workspace get flagged for a one-tap move (nothing re-files silently).

### @schedule

A consent-based scheduling state machine (resolving → slots proposed → awaiting reply → reply surfaced → held → booked). It proposes times, sends the ask, watches the thread, and books on a firm yes — driven identically from the Desk rail, the command palette, or your WhatsApp self-chat. A direct-block path books a specific slot and sends the invite in one instruction.

### Self-improving learning

Alfred gets sharper the longer it watches you. Learning runs continuously:

- **Commitment closure accuracy** — when Alfred detects a commitment was completed, it scores confidence (≥0.85 auto-closes, 0.60–0.84 asks, <0.60 ignores). Your confirm/reject feedback trains it.
- **Thread quality** — learns which contacts and groups yield signal vs. noise, and scans low-signal threads less aggressively.
- **Counterparty reliability** — tracks who completes commitments on time; this feeds the Desk ranking and relationship coaching.
- **Workflow + communication patterns** — computes your productive days, completion rates, and communication style, and injects them into coaching so Alfred coaches with *your* data.

Direct instructions ("always do X", "never do Y") become permanent immediately; softer signals graduate into patterns over time.

### Commitment tracking

Scans your WhatsApp, iMessage, and Signal conversations for commitments — things you've promised and things owed to you:

- Detects participation level (active vs. observer) to filter group-chat noise
- Tracks both directions: `i_owe` and `they_owe`
- Creates Notion tasks on demand, with a due date on every task
- Runs closure detection against recent messages and syncs bidirectionally with Notion
- Dashboard shows open, pending-closure, and recently-closed commitments by counterparty

### Notion integration (optional)

Notion is a first-class backbone but genuinely optional — Alfred runs without it:

- **Tasks** — reads active tasks for the Desk and briefings; streams new tasks on demand into a dedicated "Alfred tasks" database (never automated — you choose what goes in)
- **Commitments** — auto-created, tracks both directions with source thread, platform, due date, and priority
- **Second Brain** — pulls context from your notes for meeting prep and coaching
- **Coaching + reflection sync** — coaching memory and weekly reflections persist to Notion pages

### Message sources

- **WhatsApp** — via a network bridge (send + ingest over the protocol, no Full Disk Access needed once paired) with a local-DB fallback
- **Signal** — read without Full Disk Access via an isolated decrypt helper
- **iMessage** — read directly from the local database (requires Full Disk Access)

### Attention defense & agent memory

- A mid-day check-in that asks: given what's left today, what must get done and what can wait?
- Persistent, transparent memory: coaching memory (themes, patterns, follow-ups), user-taught rules (editable markdown), and the reflection/self-model layer — all compounding across sessions.

---

## Platform architecture

Alfred is a single Swift binary that runs as a macOS LaunchAgent. One process, one port, always on.

```
┌──────────────────────────────────────────────────────────────────┐
│                      Coach Alfred v5.1.0                          │
│                                                                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐    │
│  │   Desk    │  │  Coach   │  │  Self-   │  │   Learning     │    │
│  │  Service  │  │ (skills+ │  │  Model   │  │    Engine      │    │
│  │           │  │  lenses) │  │  Store   │  │                │    │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───────┬────────┘    │
│       │              │             │                 │             │
│  ┌────▼──────────────▼─────────────▼─────────────────▼────────┐   │
│  │              Unified Memory + Self-Model Index               │  │
│  │   facets (themes/beliefs/questions/decisions) + patterns    │  │
│  └─────────────────────────┬───────────────────────────────────┘  │
│                             │                                      │
│  ┌──────────────────────────▼──────────────────────────────────┐  │
│  │            Intent Router + Chat + @schedule                  │  │
│  │      (recognizes intent → executes tool → overlays coach)    │  │
│  └─────────────────────────┬───────────────────────────────────┘  │
│                             │                                      │
│  ┌──────────────────────────▼──────────────────────────────────┐  │
│  │                     HTTP API Server (Port 8080)              │  │
│  │   /api/desk  /api/schedule  /api/wiki  /api/model  /api/chat │  │
│  └──────────────────────────┬───────────────────────────────────┘  │
│                              │                                     │
│  ┌────────┬────────┬─────────┼─────────┬────────┬────────┐        │
│  │ Google │ iMsg   │WhatsApp │ Notion  │ Claude │  SMTP  │        │
│  │  Cal   │        │ Signal  │  API    │   AI   │ + Push │        │
│  └────────┴────────┴─────────┴─────────┴────────┴────────┘        │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │  Cadence Scheduler (60s tick, catch-up, dedup, retry)     │     │
│  └──────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────┘
```

**Privacy model:**
- All message processing happens locally on your Mac — no cloud sync, no forwarding
- WhatsApp/Signal/iMessage are read on-device; Signal and the WhatsApp bridge need no Full Disk Access
- Only Claude API calls (and any email/push you enable) leave the machine, scoped to the minimum context per request

---

## Quick start

### Prerequisites

- macOS 13+ (Ventura or later)
- Xcode Command Line Tools: `xcode-select --install`
- [Anthropic API key](https://console.anthropic.com/)
- [Google Calendar OAuth credentials](https://console.cloud.google.com/)

### Install

The easiest path is the signed, notarized DMG from [Releases](https://github.com/mitensampat/alfred/releases) — drag to Applications and launch.

To build from source:

```bash
git clone https://github.com/mitensampat/alfred.git
cd alfred

# Build
swift build -c release

# Install
cp .build/release/alfred /Applications/Alfred.app/Contents/MacOS/Alfred
codesign --force --sign - --identifier com.msfoundry.alfred \
  /Applications/Alfred.app/Contents/MacOS/Alfred

# Start
launchctl load ~/Library/LaunchAgents/com.msfoundry.alfred.plist
```

### First run

Open `http://localhost:8080` — the setup wizard walks you through Claude API → Google Calendar → Profile → Message Sources → Permissions → Launch in about five minutes. Notion is optional and can be added later. WhatsApp pairs by scanning a QR from the masthead.

### Access

```
# Desk + Coach UI
http://localhost:8080/home.html?passcode=YOUR_PASSCODE

# Your You-Wiki
http://localhost:8080/wiki?passcode=YOUR_PASSCODE

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
| **Notion** | Tasks, commitments, Second Brain, coaching + reflection sync |
| **SMTP** | The one morning email from Coach Alfred |
| **Web Push (VAPID)** | Coaching nudges delivered as browser push |
| **Signal** | Signal message scanning (no Full Disk Access) |

---

## Security & privacy

- **Privacy-first**: message processing happens locally — your conversations never leave your Mac
- WhatsApp (bridge), Signal, and iMessage are read on-device; no cloud APIs, no forwarding
- Only Claude API calls (plus any email/push you enable) leave the machine, scoped to the minimum context needed
- Passcode-protected API and web interface; config holds credentials and is git-ignored
- Codesign with a stable bundle identifier preserves TCC permissions across builds
- Graceful SIGTERM/SIGINT shutdown with startup retry for crash resilience

---

## Built with

- [Swift](https://swift.org/) — single binary, no runtime dependencies
- [Anthropic Claude](https://www.anthropic.com/) — coaching, analysis, intent recognition, and self-model synthesis
- [Google Calendar API](https://developers.google.com/calendar) — schedule data + event creation
- [Notion API](https://developers.notion.com/) — tasks, commitments, and knowledge management
- [whatsmeow](https://github.com/tulir/whatsmeow) — the WhatsApp network bridge

---

*Coach Alfred — sharpen your genius.*
