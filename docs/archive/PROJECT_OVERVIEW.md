# Alfred - Project Overview

## What This App Does

Your Alfred is an AI-powered productivity tool that functions as your personal executive assistant. It helps you stay on top of communications, prepare for meetings, and protect your attention.

### Core Capabilities

1. **Message Intelligence** (WhatsApp, iMessage, Signal)
   - Analyzes messages from the last 24 hours
   - Identifies key interactions requiring attention
   - Determines who needs responses
   - Extracts action items from conversations
   - Assesses urgency and sentiment

2. **Calendar Intelligence** (Google Calendar)
   - Provides daily schedule overview
   - Identifies external vs internal meetings
   - Calculates focus time availability
   - Generates strategic recommendations

3. **Meeting Preparation** (External Meetings Only)
   - 45-60 second executive briefings
   - Research on external attendees from:
     - LinkedIn profiles
     - Previous message history
     - Web search for recent news
     - Your Notion contact notes
   - Meeting context and preparation points
   - Suggested discussion topics

4. **Attention Defense** (3pm Daily Alert)
   - AI-powered task prioritization
   - Identifies what must be done before EOD
   - Suggests what can safely be pushed to tomorrow
   - Analyzes time available vs required
   - Provides strategic recommendations

## Technical Architecture

### Tech Stack
- **Language**: Swift 5.9
- **Platform**: macOS 13.0+
- **AI**: Anthropic Claude API (Sonnet 4.5)
- **Calendar**: Google Calendar API
- **Notes**: Notion API
- **Notifications**: Email (SMTP), Push (UserNotifications), Slack (Webhooks)

### Data Flow

```
┌─────────────────────┐
│   Message Sources   │
│  (iMessage, WA,     │
│   Signal)           │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Message Readers    │
│  (SQLite queries)   │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐       ┌──────────────────┐
│  Claude AI          │◄──────┤  Google Calendar │
│  Analysis Engine    │       │  Integration     │
└──────────┬──────────┘       └────────┬─────────┘
           │                           │
           ▼                           ▼
┌─────────────────────────────────────────┐
│      Briefing Orchestrator              │
│  (Coordinates all services)             │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│     Notification Service                │
│  (Email, Push, Slack, Dashboard)        │
└─────────────────────────────────────────┘
```

### Key Components

#### 1. Message Readers
- `iMessageReader.swift` - Reads from iMessage SQLite database
- `WhatsAppReader.swift` - Reads from WhatsApp Desktop database
- `SignalReader.swift` - Reads from Signal Desktop database

Each reader:
- Connects to the respective SQLite database
- Queries messages from specified time range
- Groups messages into conversation threads
- Tracks read/unread status

#### 2. Calendar Integration
- `GoogleCalendarService.swift` - OAuth2 authentication and API calls
- Fetches events for specified dates
- Identifies external vs internal attendees (by email domain)
- Calculates free slots and focus time

#### 3. AI Analysis Engine
- `ClaudeAIService.swift` - Anthropic API integration
- **Message Analysis**: Summarizes threads, assesses urgency, extracts actions
- **Meeting Briefings**: Generates executive summaries for meetings
- **Attention Defense**: Analyzes tasks and provides prioritization

#### 4. Research Service
- `ResearchService.swift` - Multi-source research
- Notion API for contact notes
- Message history search
- LinkedIn profile lookup (placeholder)
- Web search for recent news (placeholder)

#### 5. Notification Service
- `NotificationService.swift` - Multi-channel delivery
- Email (SMTP)
- macOS push notifications
- Slack webhooks
- Formats briefings for each channel

#### 6. Orchestrator
- `BriefingOrchestrator.swift` - Coordinates all services
- Morning briefing workflow
- Attention defense workflow
- Action item extraction
- Schedule analysis

### Data Models

#### Message Models
- `Message` - Individual message with metadata
- `MessageThread` - Grouped conversation
- `MessageSummary` - AI-analyzed thread summary

#### Calendar Models
- `CalendarEvent` - Meeting details
- `Attendee` - Participant information
- `DailySchedule` - Full day overview
- `MeetingBriefing` - Executive briefing for a meeting
- `AttendeeBriefing` - Research on an attendee

#### Briefing Models
- `DailyBriefing` - Complete morning briefing
- `MessagingSummary` - Message analysis results
- `CalendarBriefing` - Calendar + meeting briefings
- `ActionItem` - Extracted to-do item
- `AttentionDefenseReport` - 3pm prioritization report

## Privacy & Security

### Data Access
- **Local Only**: All message databases are read locally
- **No Storage**: Messages are not stored, only analyzed
- **API Communication**: Only summaries sent to Claude API
- **Credentials**: All stored locally in config.json

### Permissions Required
- Full Disk Access (for message databases)
- Notification permissions
- Google Calendar OAuth access

### Security Best Practices
1. Keep config.json secure (never commit to git)
2. Use app-specific passwords for email
3. Set API spending limits
4. Review API permissions regularly
5. Consider dedicated API keys per environment

## Extensibility

### Adding New Message Platforms

1. Create new reader in `Sources/Services/MessageReaders/`
2. Implement interface:
   ```swift
   func connect() throws
   func disconnect()
   func fetchMessages(since: Date) throws -> [Message]
   func fetchThreads(since: Date) throws -> [MessageThread]
   ```
3. Add config in `Config.swift`
4. Integrate in `BriefingOrchestrator.swift`

### Adding New Research Sources

1. Extend `ResearchService.swift`
2. Add API integration
3. Update `AttendeeBriefing` model
4. Configure in config.json

### Customizing AI Prompts

Edit prompts in `ClaudeAIService.swift`:
- `analyzeThread()` - Message analysis style
- `generateMeetingBriefing()` - Briefing format
- `generateAttentionDefenseReport()` - Prioritization logic

### Adding New Notification Channels

1. Add channel config to `NotificationConfig`
2. Implement sender in `NotificationService.swift`
3. Add formatting logic
4. Enable in config.json

## Performance Considerations

### Database Queries
- Message readers use indexed queries on timestamps
- Limit query results to relevant time ranges
- Close connections after use

### API Rate Limits
- Claude API: Monitor token usage
- Google Calendar: Cache results when possible
- Batch operations where feasible

### Scheduling
- Runs at specified times (7am, 3pm by default)
- Checks every minute for scheduled tasks
- Lightweight background process

## Future Enhancements

### Short Term
- [ ] Web dashboard for viewing briefings
- [ ] Native menu bar UI
- [ ] Email inbox integration
- [ ] Task management integration (Todoist, Things)

### Medium Term
- [ ] More messaging platforms (Telegram, Slack DMs)
- [ ] Meeting transcription integration
- [ ] Voice briefings
- [ ] Custom recurring reports

### Long Term
- [ ] iOS mobile app
- [ ] Natural language scheduling
- [ ] Predictive task management
- [ ] Team collaboration features

## Development

### Project Structure
```
Alfred/
├── Package.swift              # Swift package manifest
├── Config/
│   └── config.example.json    # Configuration template
├── Sources/
│   ├── App/                   # Entry point
│   ├── Core/                  # Business logic
│   ├── Models/                # Data structures
│   ├── Services/              # External integrations
│   └── Utils/                 # Helpers
├── Tests/                     # Unit tests
├── README.md                  # Full documentation
├── QUICKSTART.md              # Getting started guide
└── setup.sh                   # Setup automation
```

### Building
```bash
swift build -c release
```

### Testing
```bash
swift test
```

### Running
```bash
swift run Alfred <command>
```

## Cost Estimation

### API Costs (Monthly, Estimated)

**Claude API** (Primary Cost):
- Morning briefing: ~50K tokens/day = ~$0.50/day
- Attention defense: ~20K tokens/day = ~$0.20/day
- **Monthly**: ~$21

**Google Calendar API**:
- Free tier: 1M requests/day
- **Cost**: $0

**Notion API** (Optional):
- Free tier: sufficient for personal use
- **Cost**: $0

**Total Estimated**: ~$21/month

Actual costs depend on:
- Number of messages analyzed
- Number of external meetings
- Length of conversations
- Frequency of use

### Optimization Tips
- Use Haiku model for simple tasks (cheaper)
- Cache meeting briefings when possible
- Limit message history to 24 hours
- Batch API requests

## Troubleshooting

### Common Issues

1. **Database Access Errors**
   - Solution: Grant Full Disk Access
   - Location: System Settings > Privacy & Security

2. **API Authentication Failures**
   - Solution: Verify credentials in config.json
   - Check API quotas and limits

3. **Empty Briefings**
   - Check database paths are correct
   - Ensure messages exist in time range
   - Verify calendar has events

4. **Missing Notifications**
   - Check notification permissions
   - Verify SMTP settings for email
   - Test Slack webhook URL

### Debug Mode

Enable detailed logging:
```bash
swift run Alfred briefing 2>&1 | tee debug.log
```

## Contributing

This is a personal productivity tool. Feel free to:
- Fork for your own use
- Customize for your workflow
- Share improvements

## License

MIT License - See LICENSE file

## Credits

Built with:
- Swift and SwiftUI
- Anthropic Claude API
- Google Calendar API
- Notion API

---

**Status**: Production Ready ✅
**Version**: 1.0.0
**Last Updated**: January 2026
