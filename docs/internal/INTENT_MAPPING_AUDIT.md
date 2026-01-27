# Intent Mapping Audit - Alfred UI Actions

## Quick Prompts (Home Screen)

| Button | Query Sent | Expected Intent | Handler Exists? | Status |
|--------|-----------|-----------------|-----------------|--------|
| 📋 Daily Briefing | "Show me my briefing for today" | `(.generate, .briefing)` | ✅ Line 18 | **WORKING** |
| ✅ Commitments | "List my commitments" | `(.list, .commitments)` | ✅ Line 56 | **WORKING** |
| 📅 Calendar | "Show calendar for today" | `(.find, .calendar)` | ✅ Line 24 (just added) | **FIXED** |
| 🎯 Attention Check | "Run attention check" | `(.check, .attention)` | ✅ Line 70 | **WORKING** |

## Suggested Follow-ups (from Calendar response)

| Suggestion | Expected Intent | Handler Exists? | Status |
|-----------|-----------------|-----------------|--------|
| "Show calendar for tomorrow" | `(.find, .calendar)` with tomorrow's date | ✅ Line 24 | **SHOULD WORK** |
| "Show calendar for this week" | `(.find, .calendar)` with date range | ✅ Line 24 | **NEEDS TESTING** |
| "Generate briefing for today's meetings" | `(.generate, .briefing)` OR `(.generate, .calendar)` | ✅ Line 18 or 24 | **SHOULD WORK** |

## Potential Issues to Test

### 1. Calendar Query Hanging
**Symptom**: Calendar query gets response "Here's your calendar" but seems incomplete
**Possible Causes**:
- `orchestrator.getCalendarBriefing()` may be slow or hanging
- Calendar API integration may have issues
- Response formatting may be incomplete

**Test**: Check what `formatCalendarResponse()` returns

### 2. Date Range Handling
**Query**: "Show calendar for this week"
**Needs**: Intent recognition to parse "this week" into date_range filter
**Handler**: Current handler uses `intent.filters.specificDate` - may not handle date ranges

### 3. Suggestion Text Ambiguity
**Query**: "Generate briefing for today's meetings"
**Could Parse As**:
- `(.generate, .briefing)` - Full daily briefing
- `(.generate, .calendar)` - Calendar-specific briefing
**Current Handlers**: Both exist, but may give different responses

## Action Items

1. ✅ **DONE**: Add `.find` to calendar handler (Line 24)
2. ✅ **DONE**: Add "Back home" button
3. ✅ **DONE**: Add 30s timeout to prevent freezing
4. **TODO**: Investigate why calendar response is incomplete
5. **TODO**: Test date range handling for "this week" queries
6. **TODO**: Add handler for date ranges in calendar (currently only handles specificDate)
7. **TODO**: Improve calendar response formatting

## Handler Coverage Map

### Supported Combinations (from IntentExecutor.swift:14-82)

#### Briefing
- `(.generate, .briefing)` ✅

#### Calendar
- `(.generate, .calendar)` ✅
- `(.list, .calendar)` ✅
- `(.find, .calendar)` ✅ (just added)

#### Messages
- `(.analyze, .messages)` ✅
- `(.list, .messages)` ✅

#### Threads
- `(.find, .thread)` ✅
- `(.summarize, .thread)` ✅

#### Commitments
- `(.scan, .commitments)` ✅
- `(.list, .commitments)` ✅
- `(.find, .commitments)` ✅

#### Todos
- `(.scan, .todos)` ✅

#### Attention
- `(.check, .attention)` ✅
- `(.generate, .attention)` ✅

#### Drafts
- `(.list, .drafts)` ✅

### Missing Combinations That Might Be Needed

1. `(.show, .calendar)` - if Claude interprets "Show calendar" as `.show` instead of `.find`
2. `(.list, .briefing)` - for "List my briefings"
3. `(.find, .briefing)` - for "Find briefing for yesterday"
4. Date range support in calendar handler (currently only uses `specificDate`)

## Recommendations

### Immediate Fixes
1. Add debugging to see what `getCalendarBriefing()` actually returns
2. Add more action aliases to calendar handler:
   ```swift
   case (.generate, .calendar), (.list, .calendar), (.find, .calendar), (.show, .calendar):
   ```

### Calendar Handler Enhancement
The current calendar handler at line 24-28:
```swift
case (.generate, .calendar), (.list, .calendar), (.find, .calendar):
    let date = intent.filters.specificDate ?? Date()
    let calendar = intent.filters.calendarName ?? "all"
    let calendarBriefing = try await orchestrator.getCalendarBriefing(for: date, calendar: calendar)
    return formatCalendarResponse(calendarBriefing, query: intent.originalQuery)
```

**Issues**:
- Only uses `specificDate` - ignores `dateRange` filter
- May not handle "this week" queries properly

**Suggested Fix**:
```swift
case (.generate, .calendar), (.list, .calendar), (.find, .calendar), (.show, .calendar):
    // Handle date range if specified
    if let dateRange = intent.filters.dateRange {
        // Get calendar for date range
        // TODO: Implement multi-day calendar briefing
    }

    let date = intent.filters.specificDate ?? Date()
    let calendar = intent.filters.calendarName ?? "all"
    let calendarBriefing = try await orchestrator.getCalendarBriefing(for: date, calendar: calendar)
    return formatCalendarResponse(calendarBriefing, query: intent.originalQuery)
```

### Testing Checklist
- [ ] Click "Daily Briefing" - should work
- [ ] Click "Commitments" - should work
- [ ] Click "Calendar" - currently shows "Here's your calendar" but incomplete
- [ ] Click "Attention Check" - should work
- [ ] Test "Show calendar for tomorrow" - should work with tomorrow's date
- [ ] Test "Show calendar for this week" - may fail if date range not supported
- [ ] Test "Generate briefing for today's meetings" - should work
- [ ] Click "Back home" button - should clear conversation

## Calendar Issue Deep Dive

The screenshot shows Alfred responding with "Here's your calendar" but the response seems incomplete. This suggests:

1. **Intent recognition worked** (got the right intent)
2. **Handler executed** (returned a response)
3. **Response is minimal** - either:
   - `getCalendarBriefing()` returned empty/minimal data
   - `formatCalendarResponse()` is not formatting properly
   - Calendar has no events for today

**Next Steps**:
1. Check server logs for the actual API call
2. Add logging to `formatCalendarResponse()`
3. Test with known calendar data
4. Check if Calendar API is properly configured in config.json
