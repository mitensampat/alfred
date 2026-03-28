# Alfred External Deployment Architecture

## Current Architecture (macOS Local)

```
┌─────────────────────────────────────────────────────────────┐
│                    USER'S MAC                                │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              ALFRED BINARY (Swift)                    │   │
│  │                                                       │   │
│  │  ┌─────────┐  ┌──────────┐  ┌────────────────────┐  │   │
│  │  │ HTTP    │  │Scheduler │  │ BriefingOrchestrator│  │   │
│  │  │ Server  │  │(Timer)   │  │                     │  │   │
│  │  │ :8080   │  │ 60s loop │  │  fetch → analyze →  │  │   │
│  │  └────┬────┘  └────┬─────┘  │  coach → deliver    │  │   │
│  │       │            │        └─────────┬───────────┘  │   │
│  │       │            │                  │              │   │
│  │  ┌────┴────────────┴──────────────────┴───────────┐  │   │
│  │  │              SERVICE LAYER                      │  │   │
│  │  │                                                 │  │   │
│  │  │  LOCAL FILE READERS        CLOUD APIs           │  │   │
│  │  │  ├─ iMessage (SQLite)      ├─ Claude API       │  │   │
│  │  │  ├─ WhatsApp (SQLite)      ├─ Google Calendar  │  │   │
│  │  │  ├─ Signal   (SQLite)      ├─ Gmail            │  │   │
│  │  │  └─ Chrome History         ├─ Notion           │  │   │
│  │  │                            └─ SMTP             │  │   │
│  │  └─────────────────────────────────────────────────┘  │   │
│  │                                                       │   │
│  │  STATE: ~/.alfred/  CONFIG: ~/.config/alfred/         │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  Browser → localhost:8080 → Web UI                          │
└─────────────────────────────────────────────────────────────┘
```

**Characteristics:**
- Single binary, single process, single machine
- Zero external dependencies (pure Swift + Foundation)
- Message data never leaves the machine (privacy by architecture)
- Config: one big JSON file, manually edited
- Auth: static passcode, localhost only
- Scheduler: in-process timer
- Deploy: LaunchAgent (macOS only)

---

## Proposed Architecture (External / Hosted)

```
┌──────────────────────────────────────────────────────────────────────┐
│                         CLOUD INFRASTRUCTURE                         │
│                                                                      │
│  ┌────────────────┐    ┌─────────────────────────────────────────┐  │
│  │  LOAD BALANCER │    │          ALFRED API SERVER               │  │
│  │  (HTTPS)       │───▶│          (Node.js / Go / Swift)         │  │
│  │  api.alfred.ai │    │                                          │  │
│  └────────────────┘    │  ┌──────────┐  ┌─────────────────────┐  │  │
│                        │  │ Auth     │  │ BriefingOrchestrator │  │  │
│  ┌────────────────┐    │  │ (JWT +   │  │ (per-user, on-demand │  │  │
│  │  WEB APP       │    │  │  OAuth)  │  │  + scheduled)        │  │  │
│  │  (React/Next)  │    │  └──────────┘  └──────────┬──────────┘  │  │
│  │  app.alfred.ai │    │                           │             │  │
│  └────────────────┘    │  ┌────────────────────────┴──────────┐  │  │
│                        │  │          SERVICE LAYER             │  │  │
│                        │  │                                    │  │  │
│                        │  │  MESSAGE BRIDGES    CLOUD APIs     │  │  │
│                        │  │  ├─ WhatsApp        ├─ Claude API  │  │  │
│                        │  │  │  (Baileys,       ├─ Google Cal  │  │  │
│                        │  │  │   per-user       ├─ Gmail       │  │  │
│                        │  │  │   session)       ├─ Notion      │  │  │
│                        │  │  └─ iMessage*       └─ SMTP        │  │  │
│                        │  │    (future/mac only)               │  │  │
│                        │  └────────────────────────────────────┘  │  │
│                        └──────────────────────────────────────────┘  │
│                                                                      │
│  ┌────────────────┐    ┌──────────────────┐   ┌──────────────────┐  │
│  │  POSTGRES      │    │  REDIS           │   │  TASK QUEUE      │  │
│  │  ├─ users      │    │  ├─ sessions     │   │  (Bull / Celery) │  │
│  │  ├─ messages   │    │  ├─ cache        │   │  ├─ briefings    │  │
│  │  ├─ briefings  │    │  └─ rate limits  │   │  ├─ scans        │  │
│  │  ├─ commitments│    └──────────────────┘   │  └─ digests      │  │
│  │  ├─ patterns   │                           └──────────────────┘  │
│  │  └─ config     │                                                  │
│  └────────────────┘                                                  │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  BAILEYS BRIDGE POOL                                         │   │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐          │   │
│  │  │ User A  │ │ User B  │ │ User C  │ │ User D  │  ...     │   │
│  │  │ WA Sock │ │ WA Sock │ │ WA Sock │ │ WA Sock │          │   │
│  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘          │   │
│  │  - One WebSocket per user                                    │   │
│  │  - Auth state persisted to DB (survives restarts)           │   │
│  │  - Auto-reconnect + health monitoring                        │   │
│  │  - Messages streamed to Postgres in real-time               │   │
│  └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Side-by-Side Comparison

| Dimension | Current (Local macOS) | Proposed (Hosted) |
|-----------|----------------------|-------------------|
| **Language** | Swift | Node.js (Baileys is JS) or hybrid |
| **Deploy target** | macOS LaunchAgent | Docker containers on cloud (AWS/GCP/Fly.io) |
| **Message sources** | Local SQLite files (iMessage, WhatsApp, Signal) | Baileys WebSocket bridge (WhatsApp), Gmail API |
| **Message history** | Full device history (years) | From signup forward (accumulates over time) |
| **Auth** | Static passcode, localhost | JWT + OAuth 2.0, multi-tenant |
| **User isolation** | Single user, single machine | Multi-tenant, per-user data isolation |
| **Config** | One JSON file | DB-stored per user, managed via UI |
| **Scheduler** | In-process Timer (60s loop) | Task queue (Bull/BullMQ) with cron triggers |
| **State** | JSON files + SQLite in ~/.alfred/ | Postgres + Redis |
| **AI costs** | User provides own Anthropic key | Platform pays, baked into subscription |
| **Notion** | User provides API key + DB IDs | Guided OAuth flow, auto-discover databases |
| **Google** | User runs OAuth on localhost | Standard OAuth with cloud redirect URI |
| **Privacy model** | Data never leaves machine | Data on server (encrypted at rest, trust model) |
| **Scaling** | N/A (single user) | Horizontal: API servers, vertical: Baileys pool |
| **Setup time** | 30+ minutes (config, keys, permissions) | < 2 minutes (signup, QR scan, Google OAuth) |

---

## Onboarding Flow (Target: < 2 minutes)

```
STEP 1: SIGN UP                              [30 sec]
  ├─ Email + password (or Google SSO)
  └─ → Account created, JWT issued

STEP 2: CONNECT WHATSAPP                     [15 sec]
  ├─ Show QR code (Baileys pairing)
  ├─ User scans with WhatsApp
  ├─ Connection established
  ├─ Message collection begins immediately
  └─ → "WhatsApp connected ✓" badge

STEP 3: CONNECT GOOGLE                       [30 sec]
  ├─ "Connect Google" button
  ├─ Single OAuth consent (Calendar + Gmail scopes)
  ├─ Token stored server-side per user
  └─ → "Google connected ✓" badge

STEP 4: CONNECT NOTION (OPTIONAL)            [45 sec]
  ├─ "Connect Notion" button
  ├─ Notion OAuth flow (user authorizes Alfred integration)
  ├─ Auto-discover databases user has access to
  ├─ Guided picker: "Which database has your tasks?"
  │   └─ Show database names + sample entries
  ├─ Guided picker: "Which database has your notes?" (optional)
  └─ → "Notion connected ✓" badge

STEP 5: SET PREFERENCES                      [15 sec]
  ├─ Name, timezone (auto-detected)
  ├─ Briefing time (default 8:00am)
  ├─ Work domains (for internal/external classification)
  └─ → "You're all set! First briefing tomorrow at 8am"

DONE → Dashboard with:
  ├─ "Messages collecting... first briefing available in 24h"
  ├─ Calendar for today (already available)
  ├─ Quick actions (chat with Alfred, view tasks)
  └─ Progress indicator showing message accumulation
```

---

## Notion Guided Integration Flow (Detail)

Current Alfred requires users to manually find Notion API keys and database IDs — a
developer-level task that blocks most users. The hosted version should use Notion's
OAuth flow with guided database discovery.

### Flow

```
1. USER CLICKS "CONNECT NOTION"
   └─ Redirect to Notion OAuth consent page
   └─ User selects which pages/databases to share with Alfred

2. ALFRED RECEIVES OAUTH TOKEN
   └─ Call Notion API: POST /v1/search
   └─ Filter for databases the user shared
   └─ Return list of databases with:
      - Database name
      - Properties/columns (title, status, date, etc.)
      - Sample entries (first 3 rows)

3. GUIDED DATABASE PICKER
   ┌──────────────────────────────────────────────────┐
   │  Which database contains your tasks?              │
   │                                                    │
   │  ┌─ ☑ "Task Tracker"                             │
   │  │    Columns: Name, Status, Due Date, Priority   │
   │  │    Sample: "Review Q1 budget", "Ship v2.1"     │
   │  │                                                │
   │  ├─ ☐ "Reading List"                              │
   │  │    Columns: Title, Author, Rating              │
   │  │                                                │
   │  └─ ☐ "Meeting Notes"                             │
   │       Columns: Date, Title, Attendees, Notes      │
   │                                                    │
   │  [Skip for now]              [Confirm Selection]   │
   └──────────────────────────────────────────────────┘

4. PROPERTY MAPPING (auto-detected, user confirms)
   ┌──────────────────────────────────────────────────┐
   │  Alfred detected these columns:                   │
   │                                                    │
   │  Task name:  "Name"       ✓ auto-detected        │
   │  Status:     "Status"     ✓ auto-detected        │
   │  Due date:   "Due Date"   ✓ auto-detected        │
   │  Priority:   "Priority"   ✓ auto-detected        │
   │                                                    │
   │  [Looks good!]            [Let me adjust]         │
   └──────────────────────────────────────────────────┘

5. OPTIONAL: NOTES DATABASE
   └─ Same flow for "Second Brain" / notes database
   └─ Used for briefing context enrichment

6. DONE
   └─ Alfred immediately syncs tasks
   └─ Shows task count on dashboard
   └─ Commitment scanner knows where to write
```

### Why This Matters

Notion integration adds massive value:
- **Commitment tracking** → extracted commitments written to Notion
- **Task lifecycle** → Alfred monitors task status, nudges on stale items
- **Briefing context** → notes database enriches daily briefings
- **Bidirectional sync** → user updates in Notion flow back to Alfred

Making this a 45-second guided flow (vs. current 15-minute manual config) is
the difference between 80% of users connecting Notion vs. 5%.

---

## Key Technical Decisions

### 1. Language Choice for Hosted Version

| Option | Pros | Cons |
|--------|------|------|
| **Node.js (TypeScript)** | Baileys is native JS, huge ecosystem, fast dev | Different codebase from current Swift |
| **Swift (Server-side)** | Reuse existing code, Vapor framework | Baileys requires JS bridge, smaller ecosystem |
| **Go** | Great for concurrent WebSocket management | Rewrite everything, Baileys needs JS bridge |

**Recommendation: Node.js (TypeScript)**
- Baileys runs natively (no bridge overhead)
- Business logic (orchestrator, coaching) is mostly LLM prompt construction — portable
- Mature ecosystem for auth (Passport), queues (BullMQ), ORM (Prisma/Drizzle)
- The Swift code is the prototype; the hosted version is the product

### 2. Baileys Bridge Architecture

Each user needs a persistent WhatsApp WebSocket connection:

```
BAILEYS BRIDGE SERVICE (separate from API server)
│
├─ Connection Manager
│  ├─ Pool of Baileys sockets (one per user)
│  ├─ Auth state stored in Postgres (survives restarts)
│  ├─ Health check: ping every 30s, reconnect on failure
│  └─ Graceful shutdown: close sockets, persist state
│
├─ Message Ingestion Pipeline
│  ├─ on('messages.upsert') → parse → store in Postgres
│  ├─ Batch inserts (100ms debounce) for efficiency
│  ├─ Message types: text, image (OCR?), audio (transcribe?), documents
│  └─ Contact resolution: phone → name mapping
│
├─ Scaling Strategy
│  ├─ ~1000 concurrent connections per node (WebSocket memory)
│  ├─ Horizontal: spin up more bridge nodes
│  ├─ Sticky routing: user → specific bridge node (consistent hashing)
│  └─ Failover: if node dies, connections re-establish on new node
│
└─ Monitoring
   ├─ Per-user connection status (connected/disconnected/reconnecting)
   ├─ Message throughput metrics
   ├─ Reconnection failure alerts
   └─ Dashboard for ops
```

### 3. Data Model (Postgres)

```sql
-- Multi-tenant user model
users (
  id UUID PRIMARY KEY,
  email TEXT UNIQUE,
  name TEXT,
  timezone TEXT,
  briefing_time TIME DEFAULT '08:00',
  company_domains TEXT[],
  created_at TIMESTAMP,
  subscription_tier TEXT  -- 'free', 'pro', 'team'
)

-- OAuth tokens (encrypted at rest)
integrations (
  user_id UUID REFERENCES users,
  provider TEXT,  -- 'whatsapp', 'google', 'notion'
  access_token TEXT ENCRYPTED,
  refresh_token TEXT ENCRYPTED,
  metadata JSONB,  -- provider-specific (e.g., Notion DB IDs)
  connected_at TIMESTAMP,
  status TEXT  -- 'active', 'disconnected', 'expired'
)

-- WhatsApp messages (partitioned by user)
messages (
  id BIGSERIAL,
  user_id UUID REFERENCES users,
  platform TEXT,  -- 'whatsapp', 'gmail'
  contact_name TEXT,
  contact_id TEXT,
  is_group BOOLEAN,
  group_name TEXT,
  content TEXT,
  direction TEXT,  -- 'incoming', 'outgoing'
  timestamp TIMESTAMP,
  metadata JSONB
) PARTITION BY HASH (user_id);

-- Extracted commitments
commitments (
  id UUID PRIMARY KEY,
  user_id UUID REFERENCES users,
  description TEXT,
  source_message_id BIGINT,
  contact_name TEXT,
  direction TEXT,  -- 'i_owe', 'they_owe'
  status TEXT,  -- 'open', 'closed', 'auto_closed'
  confidence FLOAT,
  created_at TIMESTAMP,
  notion_page_id TEXT  -- synced back to user's Notion
)

-- Learned patterns (per user)
learned_patterns (
  id UUID PRIMARY KEY,
  user_id UUID REFERENCES users,
  pattern_type TEXT,
  description TEXT,
  confidence FLOAT,
  status TEXT,  -- 'active', 'stale', 'archived'
  created_at TIMESTAMP,
  last_reinforced_at TIMESTAMP
)

-- Scheduled tasks
scheduled_tasks (
  user_id UUID REFERENCES users,
  task_type TEXT,  -- 'briefing', 'attention', 'commitment_scan'
  cron_expression TEXT,
  last_run_at TIMESTAMP,
  next_run_at TIMESTAMP,
  enabled BOOLEAN
)
```

### 4. Cost Model

Per-user monthly costs (estimated):

| Component | Cost/user/month | Notes |
|-----------|----------------|-------|
| Claude API (Haiku for messages) | ~$2-5 | Depends on message volume |
| Claude API (Sonnet for briefings) | ~$3-8 | 1 briefing/day + coaching |
| Postgres storage | ~$0.50 | ~100MB/user/month messages |
| Baileys bridge compute | ~$1-2 | Shared across ~1000 users/node |
| Google API | Free | Within free tier for individual use |
| Notion API | Free | No per-call cost |
| **Total** | **~$7-16/user/month** | |

**Pricing suggestion:** $15-20/month subscription covers costs with margin.
Free tier: WhatsApp + Calendar only, 1 briefing/day, no coaching.
Pro tier: All integrations, unlimited chat, coaching, Notion sync.

---

## Migration Path (Current → Hosted)

### Phase 1: Core Platform (Week 1-4)
- [ ] Node.js API server with auth (JWT + Google SSO)
- [ ] Postgres schema + migrations
- [ ] Baileys bridge service (connect, ingest, reconnect)
- [ ] WhatsApp QR code onboarding flow
- [ ] Basic web dashboard (port home.html to React)

### Phase 2: Intelligence Layer (Week 5-8)
- [ ] Port BriefingOrchestrator logic to TypeScript
- [ ] Claude API integration (reuse prompt engineering from Swift)
- [ ] Message analysis pipeline (contact summaries, commitments)
- [ ] Scheduled briefing generation via task queue
- [ ] Email/push delivery

### Phase 3: Integrations (Week 9-12)
- [ ] Google OAuth (Calendar + Gmail, single consent)
- [ ] Notion OAuth + guided database picker
- [ ] Notion property auto-detection + mapping
- [ ] Commitment → Notion sync
- [ ] Task lifecycle monitoring

### Phase 4: Coaching & Learning (Week 13-16)
- [ ] Coaching engine port (leverage, relationship, avoidance skills)
- [ ] Learning system (signal collection → pattern computation)
- [ ] Agent chat (conversational interface)
- [ ] Attention defense alerts

### Phase 5: Polish & Launch (Week 17-20)
- [ ] Mobile-responsive PWA
- [ ] Onboarding optimization (< 2 min target)
- [ ] Billing integration (Stripe)
- [ ] Privacy controls (data export, deletion)
- [ ] Landing page + waitlist

---

## What We Keep vs. What Changes

### Keep (the hard-won IP)
- **Prompt engineering** — briefing structure, coaching skills, commitment extraction
- **Orchestration logic** — parallel fetch, analyze, coach, deliver pipeline
- **Learning system** — signal collection, pattern graduation, staleness decay
- **Coaching framework** — 5 skills, card generation, context injection
- **UI/UX design** — Imperial design system, dashboard layout, interaction patterns

### Change (infrastructure)
- Swift → TypeScript (for Baileys compatibility + ecosystem)
- Local SQLite → Postgres (multi-tenant)
- In-process timer → Task queue (BullMQ)
- File-based config → DB-stored per user
- Passcode auth → JWT + OAuth
- LaunchAgent → Docker containers
- localhost → HTTPS with proper domain

### The key insight
The **intelligence** (prompts, orchestration, coaching) is the product.
The **infrastructure** (Swift, SQLite, LaunchAgent) was just the prototype vehicle.
Porting the intelligence to a hosted platform is the right move.
