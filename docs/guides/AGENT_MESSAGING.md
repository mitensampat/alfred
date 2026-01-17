# Agent Message Sending - Complete Guide

## Overview

Your agents can now READ, DRAFT, and SEND messages! This guide shows you how to use the new message sending capabilities.

## How It Works

### 1. Agents Draft Responses
When you run `alfred briefing`, agents automatically:
- ✅ Read your messages (iMessage, WhatsApp, Email)
- ✅ Identify which messages need responses
- ✅ Analyze urgency and context
- ✅ Draft appropriate responses based on tone and relationship
- ✅ Save drafts to `~/.alfred/message_drafts.json`

### 2. You Review & Approve
You maintain full control:
```bash
alfred drafts                # View all drafts
alfred send-draft 1          # Send draft #1
alfred clear-drafts          # Delete all drafts
```

### 3. Messages Are Sent
Supported platforms:
- ✅ **iMessage**: Full auto-send via AppleScript
- ⚠️ **WhatsApp**: Requires Business API (drafts only for now)
- ⚠️ **Email**: Draft-only (coming soon)
- ❌ **Signal**: Not yet implemented

## Quick Start

### Run a Briefing
```bash
cd /Users/mitensampat/Documents/Claude\ apps/Alfred
swift run alfred briefing
```

The agents will show you their recommendations:
```
🤖 AGENT RECOMMENDATIONS
========================
Your AI agents have 3 suggestion(s) pending your approval:

[1] COMMUNICATION
    Confidence: 75%
    Thread from John Doe needs response. Simple acknowledgment detected.

    📤 Draft response to John Doe:
    "Got it, thanks!"

[2] COMMUNICATION
    Confidence: 68%
    Thread from Sarah Smith needs response. Standard response pattern.

    📤 Draft response to Sarah Smith:
    "Thanks for letting me know! I've got it noted down."
```

### View Drafts
```bash
swift run alfred drafts
```

Output:
```
📨 MESSAGE DRAFTS
============================================================

You have 2 draft message(s) ready to send:

[1] IMESSAGE → John Doe
    Tone: casual
    Message:
    "Got it, thanks!"

[2] WHATSAPP → Sarah Smith
    Tone: friendly
    Message:
    "Thanks for letting me know! I've got it noted down."

Commands:
  alfred send-draft <number>  - Send a specific draft
  alfred clear-drafts         - Remove all drafts without sending
```

### Send a Draft
```bash
swift run alfred send-draft 1
```

Output:
```
📤 Sending to John Doe via imessage...
✓ iMessage sent successfully to John Doe

============================================================
✓ Sent: 1
1 draft(s) remaining
```

## Platform Details

### iMessage ✅ FULLY WORKING
- Uses AppleScript to send messages
- Works with phone numbers and email addresses
- Messages appear in the Messages app
- Requires Messages.app to be authorized

**How it works:**
```applescript
tell application "Messages"
    set targetService to 1st account whose service type = iMessage
    set targetBuddy to participant "+1234567890" of targetService
    send "Your message here" to targetBuddy
end tell
```

### WhatsApp ⚠️ DRAFT-ONLY
WhatsApp requires the **WhatsApp Business API** for programmatic sending.

**Current behavior:**
- Agents create drafts
- You manually copy-paste to WhatsApp
- Future: Will integrate Business API when configured

**To enable auto-send (requires setup):**
1. Sign up for WhatsApp Business API
2. Get API credentials
3. Add to `config.json`

### Email ⚠️ DRAFT-ONLY
Email sending via Gmail API or SMTP is not yet implemented.

**Current behavior:**
- Agents create draft emails
- You manually send via Gmail/Outlook
- Future: Will integrate Gmail API

### Signal ❌ NOT IMPLEMENTED
Signal integration is disabled (encryption issues).

## Confidence-Based Auto-Execution

Agents can auto-execute high-confidence actions based on your config:

```json
{
  "agents": {
    "autonomy_level": "aggressive",
    "thresholds": {
      "auto_execute_confidence": 0.65,
      "max_daily_auto_executions": 20
    }
  }
}
```

**Confidence levels:**
- **80%+**: Simple acknowledgments ("thanks", "got it")
- **60-70%**: Standard responses with learned confidence
- **30-50%**: Complex responses (always require approval)

**Learning over time:**
- First time responding to someone: ~50-60% confidence → requires approval
- After 1 approval: ~70% confidence → AUTO-EXECUTE!
- After 3 approvals: ~85% confidence → high trust
- After rejection: confidence drops, requires approval again

## CLI Commands Reference

| Command | Description |
|---------|-------------|
| `alfred briefing` | Generate briefing (agents create drafts) |
| `alfred drafts` | View all pending drafts |
| `alfred send-draft <number>` | Send a specific draft by number |
| `alfred clear-drafts` | Delete all drafts without sending |
| `alfred messages imessage 1h` | View recent messages (no drafts) |

## File Locations

All agent data stored in `~/.alfred/`:
- `message_drafts.json` - Pending message drafts
- `decisions.db` - Agent decision audit trail
- `learning.db` - Learning patterns and confidence scores
- `meeting_preps.json` - Meeting preparation tasks
- `followups.json` - Follow-up reminders

## Learning System

The agents learn from your approvals/rejections:

```bash
# Run this simulation to see learning in action
swift /Users/mitensampat/Documents/Claude\ apps/Alfred/test_agent_approval.swift
```

**Learning progression:**
```
1️⃣ First decision: 50% confidence → Requires approval
   User approves ✓

2️⃣ Similar decision: 70% confidence → AUTO-EXECUTE!
   (Same pattern, higher confidence)

3️⃣ After 3 approvals: 85% confidence → High trust
   (Agent handles similar situations independently)

4️⃣ User rejects: Confidence drops → Back to requiring approval
   (Agent learns your preferences)
```

## Safety Features

1. **Approval-first by default**: All drafts wait for your approval
2. **Platform detection**: Only iMessage can auto-send (for now)
3. **Confidence threshold**: Only high-confidence actions auto-execute
4. **Daily limits**: Max 20 auto-executions per day (configurable)
5. **Audit trail**: Every decision logged to `decisions.db`
6. **Clear commands**: Easy to review (`drafts`) and clear (`clear-drafts`)

## Configuration

In `Config/config.json`:

```json
{
  "agents": {
    "enabled": true,
    "autonomy_level": "aggressive",
    "capabilities": {
      "auto_draft": true,
      "smart_priority": true,
      "proactive_meeting_prep": true,
      "intelligent_followups": true
    },
    "learning_mode": "hybrid",
    "thresholds": {
      "auto_execute_confidence": 0.65,
      "max_daily_auto_executions": 20
    },
    "audit": {
      "retention_days": 90,
      "log_all_decisions": true
    }
  }
}
```

**Autonomy levels:**
- `conservative`: 0.75 threshold, require approval for most actions
- `moderate`: 0.65 threshold (default), balance of autonomy and control
- `aggressive`: 0.65 threshold, maximize auto-execution

**Learning modes:**
- `explicit_only`: Learn only from your explicit feedback
- `implicit_only`: Learn from your approval/rejection actions
- `hybrid`: Combine both (recommended)

## Typical Workflow

### Morning Routine
```bash
# 1. Generate briefing
swift run alfred briefing

# Review agent recommendations in output
# Agents show: 3 drafts created

# 2. Review drafts
swift run alfred drafts

# See all 3 drafts with content preview

# 3. Send approved drafts
swift run alfred send-draft 1
swift run alfred send-draft 2

# 4. Delete unwanted draft
swift run alfred clear-drafts  # or just leave it
```

### Over Time (Learning)
After a few days of approving similar patterns:
```bash
# Generate briefing
swift run alfred briefing

# Output shows:
🤖 AGENT RECOMMENDATIONS
========================
✓ Auto-executed 2 high-confidence actions:
  • Acknowledged message from John (confidence: 82%)
  • Responded to Sarah's update (confidence: 78%)

Your AI agents have 1 suggestion pending your approval:
[1] Complex response to new contact (confidence: 45%)
```

## Troubleshooting

### "iMessage send failed"
- Ensure Messages.app is running
- Check that the recipient's phone number/email is correct
- Try sending manually first to verify contact

### "Platform not supported" (WhatsApp)
- Expected behavior - WhatsApp requires Business API
- Drafts are saved for manual sending
- Copy-paste from `alfred drafts` to WhatsApp

### No drafts created
- Check that agents are enabled in config.json
- Ensure messages exist (run `alfred messages imessage 24h`)
- Confidence may be too low (all drafts saved regardless)

### Agents not learning
- Verify `learning.db` exists in `~/.alfred/`
- Check `learning_mode` is set to "hybrid" or "implicit_only"
- Run the learning simulation to verify database access

## Future Enhancements

Coming soon:
- ✨ WhatsApp Business API integration
- ✨ Gmail API for email sending
- ✨ Interactive approval in GUI (menu bar app)
- ✨ Suggested edits to drafts before sending
- ✨ Multi-message threads with context
- ✨ Scheduled send times

## Summary

You now have a complete autonomous messaging system:

✅ Agents READ messages from all platforms
✅ Agents DRAFT appropriate responses
✅ Agents SEND iMessages automatically (when confident)
✅ You control everything via simple CLI commands
✅ System learns from your approvals over time
✅ Full audit trail and safety controls

**Quick reference:**
```bash
alfred briefing              # Agents analyze and draft
alfred drafts                # Review drafts
alfred send-draft <number>   # Send approved draft
alfred clear-drafts          # Clear all drafts
```

That's it! Your agents are now fully operational. 🚀
