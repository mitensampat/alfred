# Commitment Lifecycle & Self-Improving Auto-Closure System

**Date:** February 2026
**Status:** Production — actively learning from user feedback
**Related:** `FULL_COMMITMENTS_IMPLEMENTATION.md` (extraction), `INTENT_RECOGNITION.md` (chat routing)

---

## Overview

Alfred doesn't just extract commitments — it closes them automatically by reading follow-up conversations, and it gets smarter at this over time. Every time the user confirms or rejects an auto-closure suggestion, Alfred records the feedback and adjusts its confidence calibration for future decisions.

This document covers the **closure detection → auto-close → user feedback → learning loop** that makes the system self-improving.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   COMMITMENT LIFECYCLE                    │
│                                                          │
│  EXTRACT ──→ OPEN ──→ CLOSURE DETECTED ──→ CLOSED       │
│                            │                             │
│                    ┌───────┴───────┐                     │
│                    │               │                     │
│              confidence ≥ 0.85  0.6 - 0.84              │
│                    │               │                     │
│              AUTO-CLOSE      PENDING CONFIRMATION        │
│                    │               │                     │
│                    │        ┌──────┴──────┐              │
│                    │        │             │              │
│                    │     CONFIRM       REJECT            │
│                    │        │             │              │
│                    │     CLOSED     STAYS OPEN           │
│                    │        │             │              │
│                    └────────┴─────────────┘              │
│                             │                            │
│                    FEEDBACK RECORDED                     │
│                             │                            │
│                    PATTERNS COMPUTED                     │
│                             │                            │
│                    FUTURE PROMPTS IMPROVED               │
└─────────────────────────────────────────────────────────┘
```

---

## 1. Closure Detection

**File:** `Sources/Services/CommitmentAnalyzer.swift` (lines 568-708)

When Alfred scans a thread that has open commitments, it sends the recent messages + the open commitment text to Claude and asks: "Has this commitment been fulfilled?"

### Closure Signals (What Claude Looks For)

| Signal Type | Examples | Typical Confidence |
|------------|---------|-------------------|
| **Direct completion** | "Done", "Sent", "Here's the..." | 0.85 - 0.95 |
| **Recipient acknowledgment** | "Thanks!", "Got it", "Received" | 0.75 - 0.90 |
| **Context completion** | Discussion moved past the topic | 0.65 - 0.80 |
| **Time-based staleness** | No mention in >14 days | 0.50 - 0.60 |

### Confidence Thresholds

```
≥ 0.85  →  Auto-close immediately (no user input needed)
0.6-0.84 →  Queue as "Pending Confirmation" (user reviews)
< 0.6   →  Ignore (not enough evidence)
```

### What Gets Sent to Claude

The prompt includes:
1. The open commitment text and metadata
2. Recent messages from the thread (last 14 days)
3. **Learned patterns from user feedback** (this is the key — see Section 4)

---

## 2. Auto-Close Flow

**File:** `Sources/Services/AlfredService.swift` (lines 392-453)

When confidence ≥ 0.85, the system:

1. Marks `was_closed = 1` in `commitment_extractions` table (SQLite)
2. Sets `closed_at = NOW()`
3. Updates the Notion Task status to "Done"
4. Records a `closure_detection` entry with the signal and confidence
5. Records a `commitment_completed` event in WorkflowLearning

**Storage:** `~/.alfred/commitment_scan.db`

```sql
-- Closure detection record
INSERT INTO closure_detections (
    commitment_hash, closure_signal, confidence,
    auto_closed, detected_at
) VALUES (?, ?, 0.91, 1, datetime('now'));
```

---

## 3. Pending Confirmation Flow

**File:** `Sources/Services/HTTPServer.swift` (lines 4985-5027)

When confidence is 0.6-0.84, the closure is queued for user review.

### User Sees (in Tracker Stats UI)

```
🔔 Pending Confirmations

"Send report to Kunal" — auto-detected as complete
Signal: Kunal replied "Got it, thanks!"
Confidence: 0.78

  [✓ Confirm]  [✗ Reject]
```

### On Confirm

```
POST /api/commitment-tracker/confirm-closure?hash=abc123&passcode=REDACTED_PASSCODE
```

1. Marks commitment as closed (same as auto-close)
2. Records feedback: `userAccepted = true`
3. Updates Notion Task to "Done"

### On Reject

```
POST /api/commitment-tracker/reject-closure?hash=abc123&passcode=REDACTED_PASSCODE
```

1. Commitment **stays open** — re-analyzable in next scan
2. Records feedback: `userAccepted = false`
3. Sets `user_confirmed = 0` in `closure_detections` table

---

## 4. The Learning Loop (How It Gets Smarter)

**File:** `Sources/Agents/Learning/WorkflowLearningService.swift`

This is the core of the self-improving system. Three layers work together:

### Layer A: Feedback Recording (lines 307-343)

Every confirm/reject is stored:

```swift
func recordClosureDetectionFeedback(
    commitmentHash: String,
    commitmentTitle: String,
    signal: String,          // e.g. "Got it", "Thanks!", "Done"
    aiConfidence: Double,    // what Claude scored it
    userAccepted: Bool       // did the user agree?
)
```

**Storage:** `~/.alfred/workflow_learning.db`, table `closure_detection_feedback`

### Layer B: Pattern Computation (lines 541-584)

Periodically, Alfred computes accuracy statistics per signal type:

```sql
SELECT signal,
       COUNT(*) as total_samples,
       SUM(CASE WHEN user_accepted = 1 THEN 1 ELSE 0 END) as accepted,
       ROUND(100.0 * SUM(...) / COUNT(*), 1) as accuracy_pct,
       AVG(ai_confidence) as avg_ai_confidence
FROM closure_detection_feedback
WHERE timestamp > datetime('now', '-60 days')
GROUP BY signal
```

This produces patterns like:
- `"Got it" closure signal: 92% accurate (15 samples)`
- `"Thanks!" closure signal: 87% accurate (23 samples)`
- `"Topic moved on" closure signal: 54% accurate (8 samples)`

These are stored in the `computed_patterns` table with:
- `pattern_type = 'closure_accuracy'`
- `pattern_category = 'AI Accuracy'`
- Confidence level derived from sample count + accuracy

### Layer C: Prompt Injection (lines 774-812)

When Claude is next asked to detect closures, the prompt includes:

```
## Learned User Patterns (from your previous feedback)

### Closure Signal Accuracy:
- "Got it" closure signal: 92% accurate
- "Thanks!" closure signal: 87% accurate
- "Topic moved on" closure signal: 54% accurate
```

**Effect:** Claude now knows which signals are reliable for this specific user and weights them accordingly. A signal the user consistently rejects will naturally get lower confidence in future detections.

### The Compounding Effect

```
Month 1:  "Got it" detected at confidence 0.72 → Pending → User confirms
Month 2:  Pattern shows "Got it" = 85% accurate → Claude scores 0.78
Month 3:  Pattern shows "Got it" = 92% accurate → Claude scores 0.87
Month 4:  "Got it" now auto-closes (≥ 0.85) — no user input needed
```

Conversely:
```
Month 1:  "Topic moved on" at confidence 0.68 → Pending → User rejects
Month 2:  Pattern shows accuracy 60% → Claude scores 0.55
Month 3:  Below 0.6 threshold → not even shown to user anymore
```

---

## 5. Commitment Lifecycle Tracking

**File:** `Sources/Agents/Learning/WorkflowLearningService.swift` (lines 188-305)

Beyond closure signals, Alfred tracks the full lifecycle per counterparty:

```swift
recordCommitmentCompleted(
    hash: String,
    counterparty: String,
    commitmentType: String,    // "i_owe" or "they_owe"
    daysOpen: Int,             // how long it took
    wasOverdue: Bool,
    closureMethod: String      // "auto-close" or "manual"
)
```

This enables patterns like:
- "Commitments from Aakrit Vaish: 0% completion rate (0/4)"
- "Your commitments to Kunal: 50% completion, avg 3 days"

These appear in the **Alfred Learning Digest** email and in the Patterns & Memory → Insights tab.

---

## 6. Data Storage Map

| Database | Location | Purpose |
|----------|----------|---------|
| `commitment_scan.db` | `~/.alfred/` | Threads, extracted commitments, closure detections, pending confirmations |
| `workflow_learning.db` | `~/.alfred/` | User feedback on closures, computed signal accuracy patterns, counterparty reliability |
| `contacts.json` | `~/.config/alfred/memory/` | Thread classification (observe/minimal/active), extraction acceptance rates |
| Notion Tasks DB | Cloud (Notion API) | Canonical commitment records with status |

---

## 7. Key Files Reference

| File | What It Does |
|------|-------------|
| `Sources/Services/CommitmentAnalyzer.swift` | Claude API calls for extraction + closure detection. Builds prompts with learned patterns. |
| `Sources/Core/CommitmentScanTracker.swift` | SQLite persistence — open commitments, closure detections, pending confirmations, thread history |
| `Sources/Services/AlfredService.swift` | Orchestration — when scanning threads, calls closure detection for open commitments |
| `Sources/Agents/Learning/WorkflowLearningService.swift` | Feedback recording, pattern computation, AI context generation |
| `Sources/Services/HTTPServer.swift` | API endpoints: `/api/commitment-tracker/stats`, `/confirm-closure`, `/reject-closure`, `/pending-closures` |
| `Sources/Services/IntentExecutor.swift` | Chat-based closure detection (alternative path via natural language) |

---

## 8. API Endpoints

### Stats & Data
```
GET /api/commitment-tracker/stats
  → { openCommitments, closedCount, autoClosedCount, pendingCount, totalExtracted, ... }

GET /api/commitment-tracker/pending-closures
  → [{ hash, title, signal, confidence, detectedAt }]
```

### User Actions
```
POST /api/commitment-tracker/confirm-closure?hash=<hash>
  → Records positive feedback, closes commitment, updates Notion

POST /api/commitment-tracker/reject-closure?hash=<hash>
  → Records negative feedback, commitment stays open
```

### Learning & Patterns
```
GET /api/workflow-patterns
  → Includes closure_accuracy patterns computed from user feedback

POST /api/workflow-patterns/compute
  → Forces recomputation of all patterns including closure accuracy

GET /api/workflow-patterns/digest
  → Generates email-ready digest including commitment lifecycle stats
```

---

## 9. How to Verify the Learning Loop

### Check recorded feedback
```bash
sqlite3 ~/.alfred/workflow_learning.db \
  "SELECT signal, ai_confidence, user_accepted, timestamp FROM closure_detection_feedback ORDER BY timestamp DESC LIMIT 10;"
```

### Check computed patterns
```bash
sqlite3 ~/.alfred/workflow_learning.db \
  "SELECT title, confidence, sample_count FROM computed_patterns WHERE pattern_type = 'closure_accuracy';"
```

### Check what Claude sees in prompts
```bash
curl "http://localhost:8080/api/workflow-patterns?passcode=REDACTED_PASSCODE" | jq '.patterns[] | select(.category == "AI Accuracy")'
```

### Check commitment states
```bash
sqlite3 ~/.alfred/commitment_scan.db \
  "SELECT commitment_hash, was_closed, closed_at FROM commitment_extractions WHERE was_closed = 1 ORDER BY closed_at DESC LIMIT 10;"
```

---

## 10. Design Decisions

### Why "Learned Pattern Injection" Instead of ML Training?

1. **No training data needed** — works from day one with reasonable defaults
2. **Transparent** — user can see exactly what patterns Alfred learned (Insights tab)
3. **Immediate feedback** — one confirm/reject changes the next detection run
4. **No model drift** — Claude's base reasoning stays stable; only the context changes
5. **Debuggable** — patterns are plain text in SQLite, easy to inspect and override

### Why Two Confidence Thresholds (0.85 / 0.6)?

- **0.85+ auto-close**: High bar prevents false positives that would erode trust
- **0.6-0.84 pending**: Engages the user for borderline cases, generating training signal
- **< 0.6 ignored**: Avoids spamming the user with low-confidence noise
- Over time, the pending band naturally shrinks as patterns become more accurate

### Why 60-Day Window for Pattern Computation?

- Long enough to accumulate meaningful sample sizes (10+ per signal)
- Short enough to adapt to changing communication styles
- Prevents stale patterns from dominating (e.g., if a contact changes their acknowledgment style)
