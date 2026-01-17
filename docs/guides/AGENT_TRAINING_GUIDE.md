# Agent Training & Customization Guide

## Why Drafts Are Basic Right Now

The current drafts use **hardcoded templates** instead of AI-generated responses:

```swift
// Current approach (CommunicationAgent.swift line 183):
case .casual:
    return "Got it, thanks!"
case .friendly:
    return "Thanks for letting me know! I've got it noted down."
case .professional:
    return "Thank you for the update. I've noted this..."
```

This is why all drafts sound generic and don't reflect:
- ❌ Your personal communication style
- ❌ The specific message content
- ❌ Your relationship with the sender
- ❌ Context from your calendar/tasks

## Solution: Three Ways to Improve Drafts

### Option 1: Add User Profile (Quick - 5 minutes) ⭐ EASIEST

Add your communication preferences to `Config/config.json`:

```json
{
  "user": {
    "name": "Miten Sampat",
    "email": "your@email.com",
    "timezone": "Asia/Kolkata",

    "communication_style": {
      "default_tone": "professional-friendly",
      "writing_style": "concise and action-oriented",
      "signature_phrases": [
        "Let me know if you need anything else",
        "Happy to help",
        "Will keep you posted"
      ],
      "avoid_phrases": [
        "as per my last email",
        "touching base",
        "circling back"
      ],
      "response_patterns": {
        "acknowledgment": "Noted, thanks!",
        "confirmation": "Confirmed - I'll {action}",
        "question": "Good question. Let me {action} and get back to you",
        "task_assignment": "On it! I'll have this done by {timeframe}"
      }
    },

    "contact_preferences": {
      "work_contacts": {
        "tone": "professional",
        "response_time": "within 2 hours",
        "examples": ["CEO", "clients", "investors"]
      },
      "personal_contacts": {
        "tone": "casual",
        "response_time": "within 24 hours",
        "examples": ["family", "friends"]
      }
    }
  }
}
```

### Option 2: Use AI for Draft Generation (Better - 30 minutes) ⭐⭐ RECOMMENDED

Modify `CommunicationAgent.swift` to use Claude AI instead of templates.

**Current code** (line 168-192):
```swift
private func generateDraftContent(
    summary: String,
    tone: MessageDraft.MessageTone,
    context: AgentContext
) async throws -> String {
    // Hardcoded templates
    if detectSimpleAcknowledgment(summary: summary) {
        switch tone {
        case .casual:
            return "Got it, thanks!"
        // ... more hardcoded responses
        }
    }
}
```

**Replace with AI-powered generation:**
```swift
private func generateDraftContent(
    summary: String,
    tone: MessageDraft.MessageTone,
    messageSummary: MessageSummary,
    context: AgentContext
) async throws -> String {
    // Get user's communication style from config
    let userStyle = appConfig.user.communicationStyle ?? "professional and concise"

    // Get recent messages for context
    let recentMessages = messageSummary.thread.messages
        .suffix(3)
        .map { "\($0.direction == .incoming ? "Them" : "You"): \($0.content)" }
        .joined(separator: "\n")

    // Build AI prompt
    let prompt = """
    You are drafting a reply on behalf of the user.

    USER'S COMMUNICATION STYLE:
    - Tone: \(tone.rawValue)
    - Style: \(userStyle)
    - Signature phrases: \(appConfig.user.signaturePhrases.joined(separator: ", "))

    CONVERSATION CONTEXT:
    Recent messages:
    \(recentMessages)

    MESSAGE SUMMARY:
    \(summary)

    URGENCY: \(messageSummary.urgency.rawValue)

    INSTRUCTIONS:
    - Write a \(tone.rawValue) response in the user's style
    - Keep it concise (1-3 sentences)
    - Match their usual tone and phrasing
    - Don't use phrases they avoid: \(appConfig.user.avoidPhrases.joined(separator: ", "))
    - If acknowledging, use their style: "\(appConfig.user.responsePatterns["acknowledgment"] ?? "Noted")"

    Draft response:
    """

    // Call Claude AI
    let aiService = ClaudeAIService(config: appConfig.ai)
    let response = try await aiService.generateText(prompt: prompt)

    return response.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

### Option 3: Train with Examples (Best - ongoing) ⭐⭐⭐ BEST LONG-TERM

Create a training file with your actual message patterns.

**Create:** `Config/communication_training.json`
```json
{
  "training_examples": [
    {
      "incoming_message": "Can you review the proposal?",
      "your_typical_response": "Will review by end of day and share feedback",
      "tone": "professional",
      "context": "work colleague"
    },
    {
      "incoming_message": "Thanks for the help!",
      "your_typical_response": "Happy to help! Let me know if you need anything else",
      "tone": "friendly",
      "context": "client"
    },
    {
      "incoming_message": "Are you free for coffee tomorrow?",
      "your_typical_response": "Would love to! What time works for you?",
      "tone": "casual",
      "context": "friend"
    },
    {
      "incoming_message": "Following up on the invoice",
      "your_typical_response": "Processed yesterday - you should receive it today. Let me know if you don't see it",
      "tone": "professional",
      "context": "client"
    },
    {
      "incoming_message": "Can we reschedule our 3pm?",
      "your_typical_response": "Of course! Does 4pm work instead?",
      "tone": "professional-friendly",
      "context": "colleague"
    }
  ],

  "response_templates": {
    "acknowledgment": {
      "casual": "Noted, thanks! {emoji}",
      "friendly": "Got it, thanks! {action_if_needed}",
      "professional": "Thank you for the update. {action_statement}"
    },
    "confirmation": {
      "casual": "Confirmed! {details}",
      "friendly": "Sounds good! I'll {action}",
      "professional": "Confirmed. I will {action} by {timeframe}"
    },
    "question_response": {
      "casual": "Good question - {quick_answer}",
      "friendly": "Let me check on that and get back to you",
      "professional": "Thank you for raising this. I'll {action} and respond by {timeframe}"
    },
    "task_assignment": {
      "casual": "On it! 👍",
      "friendly": "Will take care of this today",
      "professional": "Understood. I'll complete this by {deadline}"
    },
    "meeting_request": {
      "casual": "Works for me! {time_suggestion}",
      "friendly": "Sounds good! I'm free {availability}",
      "professional": "I'm available {timeframe}. Does {specific_time} work for you?"
    }
  }
}
```

## Implementation Instructions

### Quick Win: Option 1 (User Profile)

1. **Edit your config:**
```bash
nano /Users/mitensampat/Documents/Claude\ apps/Alfred/Config/config.json
```

2. **Add communication_style section** under "user"

3. **Test immediately:**
```bash
alfred messages whatsapp 2h
alfred drafts
# Should see slightly better drafts
```

### Better Solution: Option 2 (AI-Powered)

I can implement this for you! Would you like me to:
1. Modify `CommunicationAgent.swift` to use AI
2. Add context-aware prompt building
3. Include conversation history in prompts
4. Match your actual writing style

Say "yes" and I'll implement it now.

### Best Long-term: Option 3 (Training Examples)

1. **Create training file** (I can help with this)
2. **Add 10-20 examples** of your actual responses
3. **Agent learns your patterns** over time
4. **Continuously improves** as you approve/reject drafts

## How to Train Agents Right Now

Even without code changes, you can train agents by:

### Method 1: Approve Good Drafts, Reject Bad Ones
```bash
alfred briefing              # Generates drafts
alfred drafts                # Review them
alfred send-draft 1          # ✅ Approve good ones
# Don't send bad ones - they'll learn
```

The learning engine tracks:
- Which drafts you approved → increases confidence
- Which drafts you skipped → decreases confidence
- Patterns in your approvals → adjusts future drafts

### Method 2: Explicit Feedback (Future Feature)
```bash
alfred feedback <decision-id> "too formal"
alfred feedback <decision-id> "perfect, more like this"
```

This isn't implemented yet, but the infrastructure exists.

### Method 3: Edit the Learning Database
```bash
# View current patterns
sqlite3 ~/.alfred/learning.db "SELECT * FROM patterns"

# Manually adjust confidence
sqlite3 ~/.alfred/learning.db "UPDATE patterns SET confidence = 0.9 WHERE context LIKE '%Nikhil%'"
```

## Understanding Current Draft Quality

### Why They're Generic

**Current flow:**
```
Message received → Agent checks summary
→ Hardcoded template: "Thanks for the message!"
→ No personalization
```

**What's missing:**
1. ❌ Your actual writing style
2. ❌ Message content analysis
3. ❌ Relationship context
4. ❌ Conversation history
5. ❌ Your calendar/task context

### What Good Drafts Would Look Like

**Generic (current):**
```
"Thanks for the message! I'll check on this and get back to you."
```

**Personalized (with AI + context):**
```
"Will review the proposal and share feedback by EOD.
Let me know if you need it sooner!"
```

**Context-aware (with calendar + tasks):**
```
"Can we push to 4pm? Have back-to-back until 3:30.
Happy to do coffee instead if that works better."
```

## My Recommendation

**Phase 1 (Now):** Let me implement AI-powered draft generation
- Uses Claude API to generate context-aware responses
- Analyzes actual message content
- Matches tone based on contact relationship
- **Time: 30 minutes to implement**

**Phase 2 (This week):** Add user profile to config
- Define your communication style
- Add signature phrases
- Set tone preferences per contact type
- **Time: 5 minutes to configure**

**Phase 3 (Ongoing):** Train with approvals
- Approve good drafts → confidence increases
- Skip bad drafts → confidence decreases
- System learns your preferences
- **Time: Happens automatically**

## Quick Start: Improve Drafts NOW

**1. Add to config.json:**
```json
{
  "user": {
    "communication_style": {
      "default_tone": "professional-friendly",
      "writing_style": "concise, action-oriented, uses emojis occasionally",
      "signature_phrases": ["Let me know", "Happy to help", "Will keep you posted"]
    }
  }
}
```

**2. Ask me to implement AI generation:**
Just say: **"Implement AI-powered draft generation"**

I'll:
- ✅ Modify CommunicationAgent to use Claude AI
- ✅ Add context-aware prompts
- ✅ Include conversation history
- ✅ Match your writing style from config
- ✅ Test and show you examples

**3. Start using and training:**
```bash
alfred messages whatsapp 2h    # Generate with new AI system
alfred drafts                  # Review quality improvement
alfred send-draft 1            # Approve good ones to train
```

## Want Better Drafts?

**Tell me:**
1. Your typical communication style (e.g., "concise and direct", "friendly but professional")
2. Any phrases you commonly use
3. Any phrases you never use
4. Should I implement AI generation now?

I can have significantly better drafts working in 30 minutes!
