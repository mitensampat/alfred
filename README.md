# Coach Alfred

**One surface for consequential work, and a coach that keeps you honest.** Alfred embeds into the way you operate — your messages, calendar, notes, and commitments — holds the state of everything you're running, and coaches you toward the 10x version of yourself. Not a dashboard. Not an assistant. One to-do list that spans every source you actually work in, and a coach that reads your real state.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![Version](https://img.shields.io/badge/version-6.1.0-green)

---

## The idea

Most productivity tools make you do the organizing. Alfred flips that. It runs continuously on your Mac — embedded in your messages, calendar, tasks, and notes — and gives you two things:

**The app** — one surface that works on phone, iPad and desktop, built around a single to-do list that spans every source Alfred reads. Four views:
- **Now** — one line about what deserves your attention, then your top three as cards you act on in place
- **To-dos** — one list, filterable by front or by person, with everything Alfred extracts held in a suggestion tray until you accept it
- **Fronts** — the handful of things you're actively pushing on, each with its open decision and who's involved
- **People** — who is waiting on you and who has gone quiet

**The Coach** — surfaces the right thing at the right time. Tomorrow's calendar is about to overwhelm you → it tells you tonight, while you can still act. You're losing touch with important work, or a pattern is showing up on a relationship thread → it says so, proactively. Coaching runs on modular **skills** and **analysis lenses** you can turn on, off, and author yourself.

Underneath both sits **the self-model** — a durable, portable portrait of how *you* operate: your fronts, the principles you actually run on, the people in your world, and the patterns Alfred has noticed. It gets sharper the longer Alfred watches, and you can read the whole thing as a living **You-Wiki**.

---

## What's new in 6.1.0

**Your model concludes things now, instead of filing them.**

Until this release the pipeline was extract → store → display. Every belief on the Model page was
one conversation's raw artifact shown verbatim, open questions accumulated and were never closed,
values could only be typed in by hand, and nothing the model held ever reached a prompt. 6.1.0 adds
the missing middle.

- **Claims, not fragments.** A weekly pass reads each workspace's decisions and shifts in thinking
  together and concludes what you believe. A claim needs support from at least two evidence items
  on two different days — one thread never gets to be a belief. Claims are recomputed every run, so
  wording sharpens and dead claims fade. Anything you confirmed, kept or re-worded is left alone.
- **Values Alfred works out for itself.** A value is what you protect when two good things conflict,
  visible in what lost. The pass proposes them from your decision record, marked as Alfred's read
  rather than something you declared.
- **Questions get closed.** Questions now attach to the subject they were asked in, so the pass can
  line them up against the decisions taken afterwards. Ones the evidence settles close silently with
  the answer and its references; near-duplicates fold together; anything with no new evidence in 60
  days ages out. An **Answered** list shows every close, with one click to reopen it.
- **Tensions.** A new block names where the model disagrees with itself — two beliefs that cannot
  both be honoured in one decision, or something you say you value against what your decisions show
  — each with what it costs you.
- **The model is an input.** The curated registers are injected into the chat and coaching prompts,
  so what Alfred understands about you shapes what it says, and wrong claims get corrected in the
  flow of use instead of in a curation session.
- **Confidence means something** — evidence count, independence and recency, instead of a near
  constant that made every ordering arbitrary.

### People

Pin anyone, rescan one person, and dismiss something you are waiting on, with a real undo. Fixes a
silent bug that discarded anyone who only owed *you* something and had been in touch recently: they
matched neither bucket and never appeared.

Nothing to migrate. The first weekly pass does the conversion, and everything it supersedes is
archived rather than deleted.

## What's new in 6.0.0

This is a major version because the surface is consolidated: everything Alfred does is now reached from one app at `/`, including settings, your model, coach notes, the weekly review, the archive and past conversations. The Desk — the previous primary surface — has been removed rather than deprecated, and existing bookmarks and the installed web app open the new app directly.

### One surface, one to-do list

- **Now** opens on a single line about what deserves your attention, then your top three as cards you can act on in place: reply, decide, mark done, defer, pin or open. A to-do you pin outranks Alfred's own suggestion. On a phone the rest of the day folds away. A coaching line appears only when something has earned it.
- **To-dos** is one list. Items Alfred extracts arrive in a suggestion tray and join the list once you accept them. Things other people owe you are held separately as "waiting", and one promise found in several places stays a single to-do with each source linked to it.
- **Fronts** are what you're actively pushing on — up to ten, each with a date, its open decision, next to-dos, who's involved and what's happened so far.
- **People** gathers what you owe each person, what you're waiting on, reply and nudge over WhatsApp, the fronts you share, and scheduling.
- One add box handles a to-do, a question for Alfred, or a meeting to schedule.

### Alfred learns from your choices

The learning is deliberately legible — every rule shows its reasoning. Correct a front or a name and the tagger learns it. A suggestion resembling one you dismissed, or coming from a source you keep dismissing, is hidden with its reason attached and can be restored for fourteen days. The tray puts what you usually accept first.

### Two-way Notion sync

To-dos live in their own Notion database. Alfred pushes every change within a minute and pulls your Notion edits every five minutes. The newest edit wins, and the version that lost is kept in the item's history rather than discarded.

### Scheduling in your own words

Meeting preferences are a paragraph, not a form. Describe your week the way you'd say it out loud — "never before ten", "keep Fridays for thinking" — and Alfred compiles it into how it scores slots, then echoes its reading back in plain sentences. A hard limit is removed from consideration rather than ranked down.

### Decisions you can read and edit

The fixed-menu judgements Alfred makes are Markdown files in `~/.alfred/decisions/`, alongside skills and lenses: the menu, the confidence thresholds, the fallback and the prompt. Every decision returns a confidence, and one rule turns it into a tier — act on it, propose it to you, or fall back. Editing a file changes Alfred's behaviour without touching code.

### Quieter by default

Success notifications are off for every routine, and a routine that fails now tells you. The mid-afternoon email no longer sends and the weekly digest is off by default, leaving one weekly review email.

6.0.0 also fixes a set of things that had been quietly wrong for a long time — message lookbacks silently truncated to about a week, a Notion sync that had never completed a cycle, and a fresh install pointing at a retired model. See [CHANGELOG.md](CHANGELOG.md) for the full list.

### Previous highlights

- **The Desk + Coach (v5.0.0)** — the primary surface rebuilt around the queue, fronts, and the margin, with a self-model that ranks by leverage. Superseded by the app in 6.0.0.
- **Signal, without Full Disk Access (v3.1.0)** — a message source that reads without FDA, plus a WhatsApp network bridge that sends and ingests over the protocol.
- **The Self-Model (v3.0.0)** — facets as callable objects, convergence intelligence, and a portable operating model.

---

## How it works

### The app

One surface, four views, served at `/` and installable to your home screen:

- **Now** — your top three, ranked by leverage and asymmetry (who's blocked, what's time-critical, whose reliability data says this will slip). Every card acts in place, with Undo. Sending stays an explicit confirm.
- **To-dos** — a single list across messages, calendar, commitments, meeting capture and anything you type. Suggestions stay in a tray until accepted; "waiting" items track what others owe you without padding your list.
- **Fronts** — the things you're running, each with owner, date, and the single decision it's waiting on. Mark one done and it moves to an archive.
- **People** — what you owe, what they owe, on-time reliability, a ready-to-send draft, and scheduling.

### The Coach

Coaching is driven by two composable primitives, both plain Markdown and fully editable:

- **Skills** — modular coaching programs with their own data sources, tenets, and prompts. Ship enabled or author your own. Tenet-only skills inject principles into every conversation without generating their own cards.
- **Analysis lenses** — passive detectors that run over your data and emit signals (meeting overload, relationship debt, avoidance, attention drain, leverage, calendar pressure, energy pattern). Their recurring signals feed the Coach surface and the You-Wiki.
- **Decisions** — the fixed-menu judgements Alfred makes (belief durability, meeting category), each a Markdown file in `~/.alfred/decisions/` with its options, confidence thresholds, fallback, and prompt. Every decision returns a confidence that maps to act / propose / ask.

The Coach shows up in three places: as a coaching line on Now, as an evening push when tomorrow is heavy, and in the one morning email.

### The self-model

A durable, portable model of how you operate, stored locally in `self_model.db`:

- **Facets** — themes (your fronts), beliefs (how you operate), questions (what you're holding open), and decisions (dated judgements).
- **Belief durability** — every belief is tagged `durable | tactical | fact | action`. Durable principles and live theses stay; bare facts and action items are archived out, so the model retains the right set over time.
- **Convergence** — related facets merge; stray items in the wrong workspace get flagged for a one-tap move (nothing re-files silently).

### @schedule

A consent-based scheduling state machine (resolving → slots proposed → awaiting reply → reply surfaced → held → booked). It proposes times, sends the ask, watches the thread, and books on a firm yes — driven identically from the app, the add box, or your WhatsApp self-chat. A direct-block path books a specific slot and sends the invite in one instruction. Your preferences are written as prose and compiled into how slots are scored.

### Self-improving learning

Alfred gets sharper the longer it watches you. Learning runs continuously:

- **What you accept and dismiss** — dismissals, title edits, and front/person corrections feed straight back into the extractors, and suggestions like the ones you keep dismissing are hidden with their reason attached.
- **Commitment closure accuracy** — when Alfred detects a commitment was completed, it scores confidence (≥0.85 auto-closes, 0.60–0.84 asks, <0.60 ignores). Your confirm/reject feedback trains it.
- **Thread quality** — learns which contacts and groups yield signal vs. noise, and scans low-signal threads less aggressively.
- **Counterparty reliability** — tracks who completes commitments on time; this feeds ranking and relationship coaching.
- **Workflow + communication patterns** — computes your productive days, completion rates, and communication style, and injects them into coaching so Alfred coaches with *your* data.

Direct instructions ("always do X", "never do Y") become permanent immediately; softer signals graduate into patterns over time.

### Commitment tracking

Scans your WhatsApp, iMessage, and Signal conversations for commitments — things you've promised and things owed to you:

- Detects participation level (active vs. observer) to filter group-chat noise
- Tracks both directions: `i_owe` and `they_owe`
- Feeds the one to-do list, deduplicated when the same promise shows up in several places
- Runs closure detection against recent messages and syncs bidirectionally with Notion
- Open, pending-closure, and recently-closed items are visible by counterparty on People

### Notion integration (optional)

Notion is a first-class backbone but genuinely optional — Alfred runs without it:

- **To-dos** — a dedicated database, synced both ways: Alfred pushes within a minute, pulls your edits every five, newest edit wins, and the losing version is kept in the item's history
- **Commitments** — tracked in both directions with source thread, platform, due date, and priority
- **Second Brain** — pulls context from your notes for meeting prep and coaching
- **Coaching + reflection sync** — coaching memory and weekly reflections persist to Notion pages

### Message sources

- **WhatsApp** — via a network bridge (send + ingest over the protocol, no Full Disk Access needed once paired) with a local-DB fallback
- **Signal** — read without Full Disk Access via an isolated decrypt helper
- **iMessage** — read directly from the local database (requires Full Disk Access)

### Capture and channels

- A post-meeting sheet splits your notes into follow-ups, tags them with the people from the meeting, and sends them to the suggestion tray
- The morning email is the Now view in words, built from the same ranking
- A push arrives ten minutes before a meeting and opens its prep
- In the WhatsApp self-chat, `todo …` adds an item, `done …` closes the best match, and `now` returns your top three
- Persistent, transparent memory: coaching memory, user-taught rules (editable Markdown), and the reflection/self-model layer — all compounding across sessions

---

## Platform architecture

Alfred is a single Swift binary that runs as a macOS LaunchAgent. One process, one port, always on.

```
┌──────────────────────────────────────────────────────────────────┐
│                      Coach Alfred 6.0.0                           │
│                                                                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐    │
│  │   Todo    │  │  Coach   │  │  Self-   │  │   Learning     │    │
│  │  Service  │  │ (skills+ │  │  Model   │  │    Engine      │    │
│  │ + Fronts  │  │  lenses) │  │  Store   │  │                │    │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───────┬────────┘    │
│       │              │             │                 │             │
│  ┌────▼──────────────▼─────────────▼─────────────────▼────────┐   │
│  │              Unified Memory + Self-Model Index               │  │
│  │   facets (themes/beliefs/questions/decisions) + patterns    │  │
│  └─────────────────────────┬───────────────────────────────────┘  │
│                             │                                      │
│  ┌──────────────────────────▼──────────────────────────────────┐  │
│  │       Intent Router + Chat + @schedule + Decisions           │  │
│  │      (recognizes intent → executes tool → overlays coach)    │  │
│  └─────────────────────────┬───────────────────────────────────┘  │
│                             │                                      │
│  ┌──────────────────────────▼──────────────────────────────────┐  │
│  │                     HTTP API Server (Port 8080)              │  │
│  │  /api/v2/now  /todos  /fronts  /people  /capture  /api/chat  │  │
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

Open `http://localhost:8080` — the setup wizard walks you through Claude API → Google Calendar → Profile → Message Sources → Permissions → Launch in about five minutes. Notion is optional and can be added later. WhatsApp pairs by scanning a QR from the app.

### Access

```
# The app
http://localhost:8080/?passcode=YOUR_PASSCODE

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
| **Notion** | Two-way to-do sync, commitments, Second Brain, coaching + reflection sync |
| **SMTP** | The one morning email and the weekly review |
| **Web Push (VAPID)** | Coaching nudges and meeting prep delivered as browser push |
| **Signal** | Signal message scanning (no Full Disk Access) |

---

## Security & privacy

- **Privacy-first**: message processing happens locally — your conversations never leave your Mac
- WhatsApp (bridge), Signal, and iMessage are read on-device; no cloud APIs, no forwarding
- Only Claude API calls (plus any email/push you enable) leave the machine, scoped to the minimum context needed
- Passcode-protected API and web interface; only the app shell is served without a passcode, and changing your passcode requires the current one
- Config holds credentials and is git-ignored
- Codesign with a stable bundle identifier preserves TCC permissions across builds
- Graceful SIGTERM/SIGINT shutdown with startup retry for crash resilience

---

## Built with

- [Swift](https://swift.org/) — single binary, no runtime dependencies
- [Anthropic Claude](https://www.anthropic.com/) — coaching, analysis, intent recognition, and self-model synthesis
- [Google Calendar API](https://developers.google.com/calendar) — schedule data + event creation
- [Notion API](https://developers.notion.com/) — two-way to-do sync, commitments, and knowledge management
- [whatsmeow](https://github.com/tulir/whatsmeow) — the WhatsApp network bridge

---

*Coach Alfred — sharpen your genius.*
