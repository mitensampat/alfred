# Alfred

Your AI-powered personal assistant that analyzes messages, prepares meeting briefings, and defends your attention. Like Alfred to Batman. 🦇

Available as both a **CLI tool** and a **native macOS menu bar app** with sleek Slack-inspired UI.

## 🤖 What's New in v1.1: Autonomous Agents

Alfred now features an **intelligent agent system** that learns your communication style and acts autonomously:

- **AI-Powered Draft Generation**: Automatically creates personalized message drafts that match your writing style
- **Training-Based Learning**: Teach Alfred your communication patterns with simple training examples
- **Context-Aware Responses**: Drafts consider message history, calendar context, and tone requirements
- **Automatic Workflow**: View messages → agents analyze → drafts ready for review
- **Multi-Agent System**: Specialized agents for communication, tasks, calendar, and follow-ups

**Quality Improvement**: Generic templates → Personalized, context-aware responses that sound like you.

See [Agent Training Guide](docs/guides/AGENT_TRAINING_GUIDE.md) for customization.

## Features

### Morning Briefing
- **Message Analysis**: Scans iMessage (WhatsApp and Signal support disabled due to encryption/sandboxing)
- **Key Interactions**: Highlights important conversations requiring your attention
- **Response Tracking**: Identifies who needs a response from you
- **Action Items**: Extracts critical to-dos from conversations

### Calendar Intelligence
- **Multiple Calendar Support**: Aggregate events from multiple Google Calendar accounts
- **Daily Schedule**: Comprehensive overview of your day ahead
- **Meeting Briefings**: 45-60 second executive briefings for external meetings
- **Contact Research**: Pulls information from LinkedIn, message history, web search, and your Notion notes
- **Focus Time**: Identifies blocks of time for deep work

### Attention Defense (3pm Alert)
- **Priority Analysis**: AI-powered assessment of what needs to be done today
- **Push-off Suggestions**: Identifies tasks that can safely wait until tomorrow
- **Time Management**: Calculates available time vs. required work
- **Strategic Recommendations**: Actionable advice for the rest of your day

### Dual Interface

**CLI (Command-Line Interface)**
- **Date-specific briefings**: Generate briefings for tomorrow, specific dates, or +N days from now
- **Message summaries**: Query messages by platform and timeframe (e.g., last 1h, 24h, 7d)
- **Focused thread analysis**: Deep-dive into specific WhatsApp conversations
- **Autonomous draft creation**: Agents automatically generate personalized drafts for messages needing responses
- **Draft management**: Review, edit, and approve AI-generated drafts with `alfred drafts`
- **Email delivery**: Optional `--email` flag to send briefings via email
- **Multi-calendar auth**: Easy authentication flow for multiple calendar accounts

**GUI (Menu Bar App)**
- **Always accessible**: Quick access from your menu bar
- **Slack-inspired design**: Clean, familiar aubergine theme
- **Platform selection**: Choose between all messages, iMessage only, or WhatsApp only
- **Focused search**: Search specific WhatsApp contacts/groups with custom timeframes
- **Calendar filtering**: View all calendars, primary only, or work calendar only
- **Date navigation**: Easily view briefings and calendars for today, tomorrow, or specific dates
- **WhatsApp todos**: Scan messages to yourself for action items and add to Notion

## Quick Start

### Installation

**CLI Tool:**
```bash
# Navigate to the project directory
cd "/Users/mitensampat/Documents/Claude apps/Alfred"

# Run the installation script
./install.sh
```

This will:
- Build the release binary
- Install `alfred` command to `~/.local/bin`
- Add `~/.local/bin` to your PATH

**GUI Menu Bar App:**
```bash
# Build the GUI app
swift build --product alfred-app

# Run the menu bar app
.build/debug/alfred-app
```

The app will appear in your menu bar with a lightning bolt icon ⚡

### Configure

1. Copy and edit the configuration file:
```bash
cp Config/config.example.json Config/config.json
```

2. Add your credentials to `Config/config.json`:
   - Anthropic API key
   - Google Calendar OAuth credentials
   - SMTP email settings
   - Company domains for internal/external meeting detection

### Authenticate

```bash
alfred auth
```

Select which calendar account(s) to authenticate.

## Usage

The `alfred` command works from any directory:

### Generate Briefings

```bash
# Tomorrow's briefing (default)
alfred briefing

# Specific date
alfred briefing tomorrow
alfred briefing 2026-01-15
alfred briefing +3  # 3 days from now

# Send via email
alfred briefing --email
alfred briefing tomorrow --email
```

### Query Messages

```bash
# All messages from last hour
alfred messages all 1h

# iMessages from last 24 hours
alfred messages imessage 24h

# WhatsApp messages from last week
alfred messages whatsapp 7d

# Focused WhatsApp thread analysis
alfred messages whatsapp "John Doe" 8h
alfred messages whatsapp "Team Group" 24h
```

### Manage AI-Generated Drafts (NEW in v1.1)

```bash
# View all pending drafts
alfred drafts

# Agents automatically create drafts when you view messages
# Example workflow:
alfred messages whatsapp 2h    # Agents analyze and create drafts
alfred drafts                  # Review, edit, and approve drafts
```

Drafts are personalized based on your communication training in `Config/communication_training.json`.

### Attention Defense

```bash
# Generate attention defense report
alfred attention

# Send via email
alfred attention --email
```

### Calendar Authentication

```bash
# Authenticate calendar accounts
alfred auth
```

You'll be prompted to select which account(s) to authenticate.

## Multiple Calendar Support

Alfred supports multiple Google Calendar accounts. See [MULTIPLE_CALENDARS.md](MULTIPLE_CALENDARS.md) for detailed setup instructions.

**Quick summary:**
1. Add multiple calendar configs to `config.json` in the `calendar.google` array
2. Each calendar needs a unique `name` identifier
3. Run `alfred auth` to authenticate each account
4. Briefings will automatically aggregate events from all calendars

## Configuration

### Required Credentials

#### Anthropic API Key
1. Visit https://console.anthropic.com/
2. Create an account or sign in
3. Navigate to API Keys
4. Create a new API key
5. Add to config as `anthropic_api_key`

#### Google Calendar API
1. Go to https://console.cloud.google.com/
2. Create a new project
3. Enable Google Calendar API
4. Create OAuth 2.0 credentials (Desktop app)
5. Add authorized redirect URI: `http://localhost:8080/auth/callback`
6. Add `client_id` and `client_secret` to config
7. For multiple calendars, repeat for each Google account

#### SMTP Email (Gmail)
1. Generate an App Password: https://myaccount.google.com/apppasswords
2. Add to config:
   - `smtp_host`: "smtp.gmail.com"
   - `smtp_port`: 587
   - `smtp_username`: your email
   - `smtp_password`: app password (16-character code)

### Optional Integrations

#### Notion (Optional)
1. Go to https://www.notion.so/my-integrations
2. Create a new integration
3. Create a contacts database
4. Share database with integration
5. Add `api_key` and `database_id` to config

#### LinkedIn API (Optional)
Currently disabled. Enable in config if you have API access.

## Permissions

### Full Disk Access (for iMessage)
1. Open System Settings
2. Go to Privacy & Security > Full Disk Access
3. Add your terminal application (Terminal.app or iTerm2)
4. Restart terminal

Without this permission, iMessage reading will fail with a connection error.

## Architecture

```
Alfred/
├── Sources/
│   ├── App/                    # Main CLI application
│   │   └── main.swift
│   ├── GUI/                    # Menu bar GUI application
│   │   ├── AlfredMenuBarApp.swift
│   │   ├── Views/              # SwiftUI views
│   │   │   ├── MainMenuView.swift
│   │   │   ├── MessagesOptionsView.swift
│   │   │   ├── MessagesListView.swift
│   │   │   ├── MessageDetailView.swift
│   │   │   ├── BriefingOptionsView.swift
│   │   │   ├── BriefingDetailView.swift
│   │   │   ├── CalendarOptionsView.swift
│   │   │   ├── CalendarDetailView.swift
│   │   │   ├── AttentionCheckView.swift
│   │   │   └── NotionTodosView.swift
│   │   ├── ViewModels/
│   │   │   └── MainMenuViewModel.swift
│   │   ├── Services/           # GUI-specific services
│   │   │   └── AlfredService.swift
│   │   ├── Models/             # GUI data models
│   │   └── SlackTheme.swift    # Design system
│   ├── Agents/                 # 🤖 Autonomous agent system (NEW)
│   │   ├── Core/
│   │   │   ├── AgentProtocol.swift
│   │   │   ├── AgentManager.swift
│   │   │   ├── AgentDecision.swift
│   │   │   └── ExecutionEngine.swift
│   │   ├── Specialized/
│   │   │   ├── CommunicationAgent.swift
│   │   │   ├── TaskAgent.swift
│   │   │   ├── CalendarAgent.swift
│   │   │   └── FollowupAgent.swift
│   │   └── Learning/
│   │       └── LearningEngine.swift
│   ├── Core/                   # Shared orchestration logic
│   │   └── BriefingOrchestrator.swift
│   ├── Models/                 # Shared data models
│   │   ├── Message.swift
│   │   ├── Calendar.swift
│   │   ├── Briefing.swift
│   │   ├── Config.swift
│   │   └── CommunicationTraining.swift  # 🤖 NEW
│   ├── Services/               # Shared external integrations
│   │   ├── MessageReaders/
│   │   │   ├── iMessageReader.swift
│   │   │   ├── WhatsAppReader.swift
│   │   │   └── SignalReader.swift
│   │   ├── GoogleCalendarService.swift
│   │   ├── MultiCalendarService.swift
│   │   ├── ClaudeAIService.swift
│   │   ├── ResearchService.swift
│   │   └── NotificationService.swift
│   └── Utils/                  # Utilities
├── Config/                     # Configuration files
│   ├── config.json            # Your credentials (gitignored)
│   ├── config.example.json    # Template
│   ├── communication_training.json  # 🤖 Agent training data (NEW)
│   └── google_tokens_*.json   # OAuth tokens (gitignored)
└── install.sh                 # Installation script
```

## Privacy & Security

This app:
- Runs entirely locally on your Mac
- Only sends message summaries (not full content) to Claude API
- Does not store messages permanently
- Requires explicit permissions for all data access
- All credentials stay in your local config file

**Recommendations:**
- Keep `config.json` secure (already in .gitignore)
- Use Gmail app-specific passwords for email
- Review API permissions regularly
- Consider using a dedicated API key with spending limits

## Troubleshooting

### Can't read iMessage database

**Error**: `Failed to fetch iMessages: connectionFailed("iMessage")`

**Fix**: Grant Full Disk Access to your terminal:
1. System Settings > Privacy & Security > Full Disk Access
2. Add your terminal application
3. Restart terminal

### Configuration not loading

**Error**: `Error: Failed to load configuration`

**Fix**: Ensure you're in the project directory or the wrapper script is correctly installed. The config must be in `Config/config.json`.

### Google Calendar authentication fails

Check that:
- OAuth redirect URI is exactly `http://localhost:8080/auth/callback`
- Calendar API is enabled in Google Cloud Console
- Credentials are correct in config.json
- You've added yourself as a test user if app is in testing mode

### Claude API errors

Verify:
- API key is correct
- You have API credits available
- Network connection is working
- Model name is correct: `claude-sonnet-4-5-20250929`

### Email not sending

Check:
- SMTP settings are correct
- Using Gmail app password (not regular password)
- Email is enabled in config
- Using `--email` flag with commands

## Advanced Usage

### Run in Scheduled Mode

```bash
alfred schedule
```

This will:
- Run morning briefing at configured time (default: 7am)
- Run attention defense at configured time (default: 3pm)
- Keep running in the background

### Run as Launch Agent

See [QUICKSTART.md](QUICKSTART.md) for setting up automatic execution on login.

## Development

### Building

```bash
# Debug build
swift build

# Release build
swift build -c release

# Run directly
.build/release/Alfred briefing
```

### Project Structure

- **Models**: Data structures for messages, calendar events, briefings
- **Services**: External API integrations (Google, Claude, Notion)
- **Core**: Business logic orchestration
- **App**: CLI interface and command routing

## Roadmap

- [x] Multiple calendar support
- [x] CLI interface with date-specific briefings
- [x] Email delivery on demand
- [x] Message querying by platform/timeframe
- [x] Focused WhatsApp thread analysis
- [x] Native macOS menu bar app with UI
- [x] Platform selection in GUI (all/iMessage/WhatsApp)
- [x] Focused search with custom timeframes
- [x] WhatsApp todo scanning to Notion
- [x] **v1.1: Autonomous agent system** 🤖
- [x] **v1.1: AI-powered draft generation** 🤖
- [x] **v1.1: Communication training & learning** 🤖
- [ ] Calendar view (native UI)
- [ ] Web dashboard
- [ ] Email inbox integration
- [ ] Task management integration (Todoist, Things)
- [ ] Voice briefings
- [ ] Meeting transcription integration

## Documentation

### Core Documentation
- [README.md](README.md) - This file
- [QUICK_START.md](docs/QUICK_START.md) - Quick start guide
- [MULTIPLE_CALENDARS.md](MULTIPLE_CALENDARS.md) - Multiple calendar setup

### Agent System (NEW in v1.1) 🤖
- [Agent Training Guide](docs/guides/AGENT_TRAINING_GUIDE.md) - Customize agent communication style
- [Agent Messaging Overview](docs/guides/AGENT_MESSAGING.md) - How the agent system works

### Technical Details
- [Project Overview](docs/archive/PROJECT_OVERVIEW.md) - Technical architecture
- [Implementation Summary](docs/archive/IMPLEMENTATION_SUMMARY.md) - Implementation details

## License

MIT

---

**Note**: This is a powerful productivity tool that requires access to sensitive personal data. Use responsibly and ensure you understand the permissions you're granting.

Built with Claude Sonnet 4.5
