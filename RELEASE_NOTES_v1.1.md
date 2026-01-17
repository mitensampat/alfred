# Alfred v1.1 Release Notes

**Release Date**: January 2026

## 🤖 Major Feature: Autonomous Agent System

Alfred v1.1 introduces an **intelligent multi-agent architecture** that learns your communication style and acts autonomously on your behalf. This is a significant evolution from template-based automation to context-aware, personalized assistance.

### What's New

#### 1. AI-Powered Draft Generation

Alfred now automatically creates personalized message drafts that sound like you:

- **Context-Aware**: Considers message history, calendar context, and tone requirements
- **Training-Based Learning**: Learns from your example responses in `Config/communication_training.json`
- **Quality Improvement**:
  - **Before**: "Thanks for the message! I'll check on this and get back to you."
  - **After**: "Great news on the CRED and Prosus partnership moving forward! Let me know if you need anything from my end to support the launch."

#### 2. Seamless Workflow Integration

Drafts are automatically created when you view messages:

```bash
alfred messages whatsapp 2h    # Agents analyze and create drafts
alfred drafts                  # Review, edit, and approve drafts
```

No extra commands needed - agents work in the background.

#### 3. Multi-Agent Architecture

Four specialized agents work together:

- **CommunicationAgent**: Drafts personalized responses matching your style
- **TaskAgent**: Identifies action items and deadlines
- **CalendarAgent**: Suggests meeting scheduling based on availability
- **FollowupAgent**: Tracks conversations needing follow-up

#### 4. Training & Learning System

Customize agent behavior with simple JSON training examples:

```json
{
  "category": "acknowledgment",
  "incoming_message": "Thanks for the help!",
  "your_typical_response": "Happy to help!",
  "tone": "friendly",
  "context": "general"
}
```

See [Agent Training Guide](docs/guides/AGENT_TRAINING_GUIDE.md) for details.

#### 5. Confidence-Based Execution

- **High confidence (≥65%)**: Drafts ready for immediate approval
- **Low confidence (<65%)**: Flagged for manual review
- **Learning**: System improves with feedback over time

### Architecture Changes

New components in v1.1:

```
Sources/
├── Agents/                      # NEW: Autonomous agent system
│   ├── Core/
│   │   ├── AgentProtocol.swift
│   │   ├── AgentManager.swift
│   │   ├── AgentDecision.swift
│   │   └── ExecutionEngine.swift
│   ├── Specialized/
│   │   ├── CommunicationAgent.swift
│   │   ├── TaskAgent.swift
│   │   ├── CalendarAgent.swift
│   │   └── FollowupAgent.swift
│   └── Learning/
│       └── LearningEngine.swift
├── Models/
│   └── CommunicationTraining.swift  # NEW: Training data models
```

### Configuration Changes

New configuration file for agent training:

- `Config/communication_training.json` - Customize agent communication style

Example training file provided with 10 sample responses.

### Breaking Changes

None - v1.1 is fully backward compatible with v1.0.

### Bug Fixes

- Fixed draft persistence issue where low-confidence drafts weren't being saved
- Fixed draft generation only running during briefing commands
- Improved error handling in agent execution pipeline

### Technical Improvements

- Decoupled draft saving from decision execution
- Added similarity matching for training examples
- Integrated AI generation with ClaudeAIService
- Enhanced context passing between orchestrator and agents
- Added draft workflow to all message viewing commands

### Performance

- Agent evaluation adds ~1-2 seconds per message thread
- Training file loads once on startup
- AI generation uses Claude Sonnet 4.5 Haiku (fast, cost-effective)

### Documentation

New documentation in v1.1:

- [Agent Training Guide](docs/guides/AGENT_TRAINING_GUIDE.md) - Complete customization guide
- [Agent Messaging Overview](docs/guides/AGENT_MESSAGING.md) - System architecture
- Reorganized docs into `docs/guides/`, `docs/reference/`, and `docs/archive/`

### Migration Guide

No migration needed - existing installations work immediately with v1.1.

To customize agent behavior:

1. Copy `Config/communication_training.json` to your preferred location (or edit in place)
2. Add 5-10 examples of your typical message responses
3. Customize `personalization_rules` with phrases to use/avoid
4. Agents automatically load training on startup

### What's Next

Future agent enhancements planned:

- Email draft generation
- Task extraction to Notion
- Meeting scheduling automation
- Multi-turn conversation handling
- Voice-based draft approval

### Credits

Built with:
- **Claude Sonnet 4.5** - Core AI model
- **Swift 5.9** - Implementation language
- **SwiftUI** - GUI framework

---

## Full Changelog

### Added
- Autonomous multi-agent system with specialized agents
- AI-powered draft generation using training examples
- Communication training configuration file
- Draft management CLI command (`alfred drafts`)
- Automatic draft creation from message viewing
- Similarity matching for training examples
- Learning engine with SQLite persistence
- Confidence-based decision execution

### Changed
- Draft workflow now integrated into all message commands
- Agent recommendations shown during briefings
- Documentation reorganized into `docs/` structure
- README updated with agent system highlights

### Fixed
- Draft persistence for low-confidence decisions
- Compilation errors in WhatsAppGUIAutomation.swift
- Package.swift test target warnings
- Optional unwrapping in agent context handling

### Technical
- Added `generateText()` method to ClaudeAIService
- Created `CommunicationTraining.swift` models and loader
- Enhanced `BriefingOrchestrator` with draft generation methods
- Improved `AgentManager` with separate save/execute flow

---

**Download**: See [Installation Instructions](README.md#installation) in main README

**Questions?** File an issue on GitHub or see the [Agent Training Guide](docs/guides/AGENT_TRAINING_GUIDE.md)
