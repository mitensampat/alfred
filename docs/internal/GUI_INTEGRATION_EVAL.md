# GUI Integration Evaluation
**Date:** January 22, 2026
**Purpose:** Assess which CLI features should be integrated into the GUI menu bar app

---

## Current GUI Capabilities ✅

The GUI currently supports:
1. **Briefing** - Daily summary with date selection
2. **Calendar** - Meeting schedule with calendar filtering (all/primary/work)
3. **Messages** - Message summaries with platform filtering
4. **Message Detail** - Focused WhatsApp thread analysis
5. **Attention Check** - 3pm attention defense alert
6. **Notion Todos** - Scan WhatsApp messages to yourself for todos

**UI Pattern:** Menu bar popover (340x380 default, 680x760 expanded)

---

## Missing Features Analysis

### 🔴 TIER 1: High Value, Should Add
**Features that significantly enhance the GUI experience**

#### 1. **Commitments Tracker** ⭐⭐⭐⭐⭐
- **What's Missing:**
  - `commitments scan` - Scan messages for commitments
  - `commitments list` - View all commitments (I Owe / They Owe)
  - `commitments overdue` - Show overdue commitments

- **Why Add:**
  - Natural fit for GUI (visual commitment management)
  - High user value - addresses real pain point
  - Already has backend implementation complete
  - Syncs with Notion for persistence

- **UI Proposal:**
  - Add "Commitments" main menu item
  - Sub-view with tabs: "All" / "I Owe" / "They Owe" / "Overdue"
  - Quick scan button with contact picker
  - Badge showing overdue count on main menu

- **Implementation Effort:** Medium (2-3 new views + integration)

---

#### 2. **Agent Drafts** ⭐⭐⭐⭐
- **What's Missing:**
  - `drafts` - View AI-generated message drafts
  - `clear-drafts` - Clear all drafts

- **Why Add:**
  - Core agent capability that's invisible in GUI right now
  - Users need to see what agents are suggesting
  - Quick review/approve workflow fits menu bar UX

- **UI Proposal:**
  - Badge on main menu showing draft count
  - "Drafts" menu item (show when drafts > 0)
  - Draft review view: swipe to dismiss, tap to copy
  - "Clear All" button

- **Implementation Effort:** Small-Medium (1 new view + badge logic)

---

#### 3. **Attention Reports** ⭐⭐⭐⭐
- **What's Missing:**
  - `attention report [scope] [period]` - Detailed analytics
  - `attention calendar [period]` - Calendar-only reports
  - `attention messaging [period]` - Messaging-only reports

- **Why Add:**
  - Extends existing "attention check" to multi-period analysis
  - Valuable insights (weekly/monthly patterns)
  - Complements 3pm alert with historical view

- **UI Proposal:**
  - Expand "Attention Check" to "Attention"
  - Add period selector: Today / This Week / Last Week / Custom
  - Scope selector: Both / Calendar / Messaging
  - Visual charts for breakdown by category

- **Implementation Effort:** Medium (extend existing view + charts)

---

### 🟡 TIER 2: Moderate Value, Consider Later
**Nice-to-have features that aren't critical for GUI**

#### 4. **Gmail/Email Integration** ⭐⭐⭐
- **What's Missing:**
  - Email platform in messages view
  - Gmail authentication flow

- **Why Consider:**
  - Already implemented in backend
  - Natural extension of messages view

- **Why Wait:**
  - Email is lower urgency than chat messages
  - Auth flow is complex for GUI
  - Most users check email elsewhere

- **UI Proposal (if added):**
  - Add "Email" to platform picker in Messages
  - "Authenticate Gmail" button in settings

- **Implementation Effort:** Medium (auth flow + email rendering)

---

#### 5. **Attention Planning** ⭐⭐⭐
- **What's Missing:**
  - `attention plan [days]` - Generate attention plan
  - `attention priorities` - Collect meeting priorities
  - `attention config` - Interactive configuration

- **Why Consider:**
  - Forward-looking planning vs reactive alerts
  - Helps optimize future time allocation

- **Why Wait:**
  - Complex UI for planning interface
  - More suited to desktop/CLI workflows
  - Interactive config better in terminal

- **UI Proposal (if added):**
  - "Plan" tab in Attention view
  - Day range slider
  - Show recommendations as checklist

- **Implementation Effort:** Large (complex planning UI)

---

### 🟢 TIER 3: CLI-Only, Don't Add
**Features that don't make sense for GUI**

#### 6. **Scheduled Mode** ⭐
- `schedule` - Run in scheduled mode
- **Why Skip:** Background daemon, not interactive. Use launchd/cron instead.

---

#### 7. **Authentication Commands** ⭐
- `auth` - Google Calendar authentication
- `auth-gmail` - Gmail authentication
- **Why Skip:** Already handled by GUI auth flows. Terminal-only makes more sense for OAuth callback.

---

#### 8. **Test Commands** ⭐
- `test-notion` - Test Notion integration
- **Why Skip:** Developer/debugging tool, not user-facing.

---

#### 9. **Attention Init** ⭐
- `attention init` - Create preferences file
- **Why Skip:** One-time setup, better in CLI. Most users won't customize.

---

## Recommended Implementation Roadmap

### Phase 1: Quick Wins (1-2 weeks)
**Goal:** Add high-impact features with existing backend**

1. **Agent Drafts** (3-4 days)
   - Add draft count badge to main menu
   - Create DraftsView for review
   - Wire up to existing draft JSON storage
   - Add "Clear All" action

2. **Commitments - List View** (4-5 days)
   - Add "Commitments" main menu item
   - Create CommitmentsListView with tabs
   - Connect to existing Notion integration
   - Badge for overdue count

### Phase 2: Full Commitments Integration (2-3 weeks)
**Goal:** Complete commitments tracker UI**

3. **Commitments - Scan** (5-7 days)
   - Add "Scan" button to commitments view
   - Contact picker UI
   - Lookback period selector (use our new `14d` syntax!)
   - Progress indicator during scan
   - Result summary

4. **Commitments - Detail View** (3-4 days)
   - Tap commitment → detail sheet
   - Show full context, dates, priority
   - Actions: Mark complete, Edit, Delete
   - Follow-up scheduling

### Phase 3: Enhanced Attention (2-3 weeks)
**Goal:** Rich attention analytics**

5. **Attention Reports** (7-10 days)
   - Period/scope selectors
   - Breakdown visualization (charts)
   - Top time consumers list
   - Recommendations display

6. **Attention - Calendar Integration** (3-4 days)
   - Deep link to calendar events
   - Meeting category overrides
   - Focus block highlighting

---

## GUI Design Considerations

### Navigation Pattern
Current: Main Menu → Options → Detail
**Proposed:** Main Menu → Feature Hub → Detail

```
Main Menu
├── Briefing
├── Calendar
├── Messages
├── Commitments (NEW)
│   ├── All
│   ├── I Owe
│   ├── They Owe
│   └── Overdue
├── Attention (ENHANCED)
│   ├── Check (3pm alert)
│   └── Reports (NEW)
├── Drafts (NEW - show when > 0)
└── Todos
```

### Badge System
Show important counts on main menu:
- Messages: Unread count
- Commitments: Overdue count
- Drafts: Draft count
- Attention: Critical tasks (3pm only)

### Popover Size Strategy
- Small (340x380): Main menu, options
- Large (680x760): Lists, details, reports
- Full screen modal (optional): Planning, config

---

## Technical Implementation Notes

### Reusable Components Needed

1. **DatePicker Component**
   - Currently duplicated across calendar/briefing
   - Extract to shared component
   - Add quick picks: Today, Tomorrow, Next Week

2. **PeriodSelector Component**
   - For attention reports
   - Options: Today, This Week, Last Week, Custom
   - Reusable across features

3. **PlatformPicker Component**
   - Currently in messages
   - Extend for commitments (source platform)

4. **LoadingState Component**
   - Spinner + message for long operations
   - Used by scan, reports, etc.

5. **EmptyState Component**
   - "No commitments found"
   - "No drafts available"
   - Reusable pattern

### Backend Integration Points

All features have complete backend implementations:
- `BriefingOrchestrator` - Main service layer
- `CommitmentAnalyzer` - Commitment extraction
- `NotionService` - Persistence
- `MessageDraft` model - Draft storage
- `AttentionReport` models - Attention analytics

**GUI just needs to call existing async functions!**

---

## Priority Matrix

```
High Value │ Commitments │ Drafts │ Att. Reports │
           │      ⭐⭐⭐⭐⭐ │  ⭐⭐⭐⭐ │       ⭐⭐⭐⭐ │
───────────┼─────────────┼────────┼──────────────┤
Moderate   │    Email    │  Plan  │              │
Value      │       ⭐⭐⭐  │    ⭐⭐⭐ │              │
───────────┼─────────────┼────────┼──────────────┤
           │  Low Effort │        │ High Effort  │
```

**Recommendation:** Focus on top-left quadrant (high value, low-medium effort)

---

## Estimated Timeline

**Phase 1 (Drafts + Commitments List):** 1-2 weeks
**Phase 2 (Full Commitments):** 2-3 weeks
**Phase 3 (Attention Reports):** 2-3 weeks

**Total for Tier 1 features:** 5-8 weeks

---

## Success Metrics

How to measure if GUI integration is successful:

1. **Adoption Rate**
   - % of users who open GUI vs CLI daily
   - Target: 70%+ prefer GUI for quick checks

2. **Feature Usage**
   - Most viewed: Commitments > Drafts > Messages
   - Most actioned: Draft review, Commitment scan

3. **Time to Value**
   - Avg time from open → insight: < 10 seconds
   - Faster than CLI for visual browsing

4. **User Feedback**
   - NPS score for GUI vs CLI
   - Feature request trends

---

## Final Recommendation

**Implement Tier 1 in order:**

1. ✅ **Drafts** (Week 1) - Quick win, shows agent value
2. ✅ **Commitments List** (Week 1-2) - Core feature foundation
3. ✅ **Commitments Scan** (Week 2-3) - Complete the workflow
4. ✅ **Attention Reports** (Week 4-5) - Enhanced analytics

**Skip Tier 2 for now** - revisit after user feedback on Tier 1

**Never add Tier 3** - CLI-only by design

---

## Open Questions for User

1. **Priority preferences:** Does this order make sense for your workflow?
2. **UI preferences:** Menu bar app vs separate window for complex features?
3. **Notification strategy:** Push notifications for overdue commitments?
4. **Sync strategy:** Real-time updates vs refresh-on-open?
5. **Theme preferences:** Keep Slack theme or customize for commitments?

---

## Next Steps

If approved:
1. Create detailed mockups for Drafts view
2. Design commitments UI components
3. Set up SwiftUI navigation structure
4. Begin Phase 1 implementation

**Ready to build when you are!** 🚀
