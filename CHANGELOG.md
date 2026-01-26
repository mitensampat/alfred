# Changelog

All notable changes to Alfred will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-01-26

### Added
- **Web Interface**: New Notion-inspired web UI accessible from any device
  - 7 quick action buttons with interactive forms
  - Date picker for calendar queries
  - Contact/timeframe selection for messages and commitments
  - Mobile-friendly responsive design
- **HTTP API Server**: Full REST API for all Alfred features
  - `/api/briefing` - Daily briefings
  - `/api/calendar` - Calendar events with date/calendar filtering
  - `/api/messages/summary` - Message summaries by contact
  - `/api/commitments` - Commitment tracking
  - `/api/commitment-check` - Check commitments with specific people
  - `/api/todos/scan` - Extract todos from messages
  - `/api/attention-check` - Focus and attention alerts
- **Query Caching**: SQLite-based caching for API responses
  - Configurable TTL per endpoint
  - Faster repeat queries
  - Cache clear endpoint
- **Intent Recognition**: Natural language query processing
- **Passcode Authentication**: Secure access via URL parameter or header

### Changed
- Improved date parsing to handle multiple formats (ISO8601 full and date-only)
- Better error messages and response formatting
- Updated `config.example.json` with API configuration section

### Fixed
- Calendar date selection bug where future dates showed today's results
- Passcode authentication in API calls

### Removed
- Desktop SwiftUI app (replaced by more flexible web interface)

## [1.2.0] - 2026-01-20

### Added
- **Commitments Tracker**: AI-powered extraction of commitments from messages
  - Scan messages for "I owe" and "They owe me" commitments
  - Store in Notion database
  - Flexible lookback period syntax (7d, 2w, etc.)
- Commitment check by person/group
- Overdue commitments tracking

### Changed
- Enhanced commitment analysis with better AI prompts
- Improved Notion integration for commitment storage

## [1.1.0] - 2026-01-17

### Added
- **Autonomous Agent System**: Specialized agents for different tasks
  - Communication Agent: Generates personalized message drafts
  - Task Agent: Identifies action items and deadlines
  - Calendar Agent: Suggests meeting scheduling
  - Follow-up Agent: Tracks conversations needing follow-up
- **Learning Engine**: Learns from training examples to match your communication style
- Agent decision logging for transparency

### Changed
- Improved briefing generation with agent insights
- Better message analysis with context awareness

## [1.0.0] - 2026-01-15

### Added
- Initial release
- Google Calendar integration (multiple accounts)
- Message reading from iMessage, WhatsApp, Signal
- Daily briefing generation
- Meeting preparation briefs
- Attention defense alerts
- CLI interface
- Notion integration for contacts
- Email notifications
- Slack webhook support

---

## Version History Summary

| Version | Date | Highlights |
|---------|------|------------|
| 1.3.0 | 2026-01-26 | Web interface, HTTP API, query caching |
| 1.2.0 | 2026-01-20 | Commitments tracker with AI extraction |
| 1.1.0 | 2026-01-17 | Autonomous agent system |
| 1.0.0 | 2026-01-15 | Initial release |
