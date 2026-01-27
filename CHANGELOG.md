# Changelog

All notable changes to Alfred will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.2] - 2026-01-27

### Added
- **Smart Notes Retrieval**: Intelligent context-aware notes for briefings and meetings
  - Extracts keywords from attendee names, companies, and email domains
  - Uses Notion Search API for keyword-based note discovery
  - Fetches note content (first 1000 chars) for relevance scoring
  - Ranks notes by relevance (title match: 10pts, content match: 5pts, recency boost)
  - Falls back to recent notes when no keywords available

### Fixed
- **Notion "Due Date" property error**: Fixed sort property mismatch
  - Changed from "Due" to "Due Date" to match unified Tasks database schema
  - Fixed in both CLI and GUI NotionService implementations
- **Config priority for Tasks database**: Top-level `notion.tasks_database_id` now takes priority
  - Checks `notion.tasks_database_id` first
  - Falls back to `notion.briefing_sources.tasks_database_id`
  - Consistent behavior across CLI, GUI, and API

### Changed
- `queryRelevantNotes()` now uses smart search instead of date-only filtering
- `generateBriefingContext()` includes attendee names and emails for better note matching
- `generateCalendarContext()` includes attendee info for meeting prep notes

### Technical
- New NotionService methods:
  - `extractSearchKeywords(from:)` - Regex extraction of names/companies
  - `searchNotesWithKeyword(_:databaseId:)` - Notion Search API integration
  - `fetchNoteContent(pageId:)` - Block children API for content retrieval
  - `queryRecentNotes(databaseId:limit:)` - Fallback for no keywords
  - `rankNotesByRelevance(notes:keywords:)` - Scoring and sorting
- Updated config loading in NotionService.init, HTTPServer, BriefingOrchestrator

## [1.4.1] - 2026-01-27

### Added
- **Interactive Task Approval**: Y/N/S prompts before adding items to Notion
  - Commitment scanning (`alfred commitments scan`) now prompts for approval
  - Todo scanning (`alfred notion-todos`) now prompts for approval
  - Focused thread analysis (`alfred messages whatsapp "Name"`) extracts commitments + actions
  - Select mode allows choosing individual items to add
- **ExtractedItem Model**: Unified model for commitments, todos, and follow-ups
  - Standardized format for displaying extracted items
  - Conversion to TaskItem for Notion storage
  - Factory methods from Commitment, TodoItem, and FollowupReminder
- **BriefingOrchestrator Enhancements**
  - `extractWhatsAppTodosForReview()` - Extract todos without auto-saving
  - `saveExtractedItems()` - Batch save approved items to Notion
- **Web UI Interactive Approval**
  - New "Scan Todos" button with lookback period selection and approval UI
  - New "Analyze Thread" button to extract actions from specific conversations
  - Visual item approval with checkboxes for selecting which items to add
  - Select/deselect all functionality with item count display
  - Type and priority indicators for each extracted item
- **Extraction API Endpoints**
  - `POST /api/extract/todos` - Extract todos for review without auto-saving
  - `POST /api/extract/thread` - Extract items from specific thread
  - `POST /api/extract/approve` - Save approved items to Notion

### Changed
- Commitment scan now collects items first, then prompts for approval
- Todo scan now collects items first, then prompts for approval
- Focused WhatsApp thread analysis includes commitment extraction
- All extraction commands provide consistent Y/N/S interactive prompts
- Web UI "Scan Todos" now shows approval UI instead of auto-adding items
- **Unified Tasks Database**: Consolidated all storage to single Notion database
  - Commitments, Todos, and Follow-ups now all stored in `tasksDatabaseId`
  - Legacy `commitments.notionDatabaseId` config no longer required
  - Simplified configuration: just set `notion.tasks_database_id`
  - All extraction and query operations use unified Tasks database

### Technical
- New `ExtractedItem.swift` model with `ItemType`, `ItemPriority`, `ItemSource`
- Interactive prompt helper: `parseTimeframeToHours()`
- Deduplication checks during extraction phase
- AlfredService extraction methods for GUI support
- HTTPServer handlers for extraction and approval endpoints
- New CSS styles for approval item list with checkboxes
- NotionService+Tasks compatibility methods:
  - `queryActiveCommitmentsFromTasks()` - Query commitments from unified DB
  - `queryOverdueCommitmentsFromTasks()` - Query overdue commitments
  - `queryUpcomingCommitmentsFromTasks()` - Query upcoming commitments
  - `findCommitmentByHashInTasks()` - Deduplication check
  - `createCommitmentInTasks()` - Create commitment in unified DB
- Removed dependency on legacy `commitments.notionDatabaseId` across all services

## [1.4.0] - 2026-01-26

### Added
- **Proactive Agent Insights**: Agents now surface insights without being asked
  - Daily briefings include agent observations, commitment reminders, and cross-agent suggestions
  - New `AgentInsights` section in briefings with proactive notices
  - Communication + Calendar coordination suggestions
- **Unified Commitments & Follow-ups**: Single view for all commitments
  - "I Owe" - commitments you made
  - "They Owe Me" - commitments others made
  - "Follow-ups" - reminders to check on things
  - Overdue indicators and due dates
- **Daily Agent Digest**: End-of-day summary of agent activity
  - CLI: `alfred digest` to generate and optionally email digest
  - API: `GET /api/agent-digest`
  - Web UI: New "Agent Digest" quick action button
  - Summary of decisions, learnings, and recommendations
- **Cross-Agent Coordination**: Agents now share context and work together
  - `SharedContextService` for inter-agent communication
  - Agents can raise alerts for other agents
  - Cross-agent suggestions (e.g., "wait until after meeting to message")
  - Activity tracking across all agents
- **Follow-up Task Type**: Unified Tasks database now supports Follow-ups
  - TaskItem model extended with `.followup` type
  - Follow-ups stored in Notion alongside Todos and Commitments
  - Automatic deduplication using hash
- **Web UI Improvements**
  - Updated Commitments button shows unified view (I Owe, They Owe Me, Follow-ups)
  - New Agent Digest quick action button
  - Better commitment formatting with overdue indicators

### Changed
- DecisionLog now uses singleton pattern for consistent tracking
- AgentManager integrates SharedContextService for cross-agent awareness
- BriefingOrchestrator includes `generateAgentDigest()` method
- NotionService+Tasks supports Follow-up type in schema

### Technical
- New `SharedContextService` for agent coordination
- Extended `AgentProtocol` with optional cross-agent methods
- `AgentDigest` and related models for daily summaries
- 1 new API endpoint: `/api/agent-digest`

## [1.3.1] - 2026-01-26

### Added
- **Agent Memory System**: Persistent, transparent learning for all agents
  - Markdown-based memory files (`~/.alfred/agents/[agent]/memory.md`)
  - Skills documentation (`~/.alfred/agents/[agent]/skills.md`)
  - User-taught rules with highest priority in AI prompts
  - Contact-specific patterns and learned preferences
- **Teach Mode**: Train agents with explicit rules
  - CLI: `alfred teach [agent] "rule"`
  - Web UI: Agents panel with teach form
  - API: `POST /api/agents/teach`
- **Memory Viewing**: Full transparency into what agents know
  - CLI: `alfred agents memory [agent]` and `alfred agents skills [agent]`
  - Web UI: Click any agent to view memory, rules, and skills
  - API: `GET /api/agents/memory` and `GET /api/agents/skills`
- **Learning Consolidation**: Automatic pattern extraction from usage
  - High-confidence patterns from `learning.db` consolidated to memory files
  - CLI: `alfred agents consolidate` and `alfred agents status`
  - API: `POST /api/agents/consolidate` and `GET /api/agents/status`
- **Web UI Agents Panel**: New 🧠 Agents quick action
  - View all 4 agents with memory stats
  - Detailed view with rules, patterns, and skills
  - Teach form with agent selector and context field
  - Delete rules with one click

### Changed
- All agents now use memory context in AI prompts (CommunicationAgent, TaskAgent, CalendarAgent, FollowupAgent)
- CommunicationAgent includes user-taught rules, style preferences, and contact patterns in drafts
- TaskAgent uses memory when categorizing meetings
- Improved agent initialization with shared AgentMemoryService

### Technical
- New `AgentMemoryService` singleton for memory/skills management
- SQLite integration for learning.db queries during consolidation
- 7 new API endpoints for agent management

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
| 1.4.2 | 2026-01-27 | Smart notes retrieval, Due Date fix, config priority |
| 1.4.1 | 2026-01-27 | Interactive task approval with Y/N/S prompts |
| 1.4.0 | 2026-01-26 | Proactive insights, unified commitments, agent digest, cross-agent coordination |
| 1.3.1 | 2026-01-26 | Agent memory system, teach mode, learning consolidation |
| 1.3.0 | 2026-01-26 | Web interface, HTTP API, query caching |
| 1.2.0 | 2026-01-20 | Commitments tracker with AI extraction |
| 1.1.0 | 2026-01-17 | Autonomous agent system |
| 1.0.0 | 2026-01-15 | Initial release |
