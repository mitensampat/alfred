# Alfred

Your AI-powered personal assistant that analyzes messages, prepares meeting briefings, and defends your attention. Like Alfred to Batman. 🦇

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

### Command-Line Interface
- **Date-specific briefings**: Generate briefings for tomorrow, specific dates, or +N days from now
- **Message summaries**: Query messages by platform and timeframe (e.g., last 1h, 24h, 7d)
- **Email delivery**: Optional `--email` flag to send briefings via email
- **Multi-calendar auth**: Easy authentication flow for multiple calendar accounts

## Quick Start

### Installation

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

# All messages from last week
alfred messages all 7d
```

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
│   ├── Core/                   # Core orchestration
│   │   └── BriefingOrchestrator.swift
│   ├── Models/                 # Data models
│   │   ├── Message.swift
│   │   ├── Calendar.swift
│   │   ├── Briefing.swift
│   │   └── Config.swift
│   ├── Services/               # External integrations
│   │   ├── MessageReaders/
│   │   │   ├── iMessageReader.swift
│   │   │   ├── WhatsAppReader.swift  (disabled)
│   │   │   └── SignalReader.swift    (disabled)
│   │   ├── GoogleCalendarService.swift
│   │   ├── MultiCalendarService.swift
│   │   ├── ClaudeAIService.swift
│   │   ├── ResearchService.swift
│   │   └── NotificationService.swift
│   └── Utils/                  # Utilities
├── Config/                     # Configuration files
│   ├── config.json            # Your credentials (gitignored)
│   ├── config.example.json    # Template
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
- [ ] Native macOS menu bar app with UI
- [ ] Web dashboard
- [ ] Email inbox integration
- [ ] Task management integration (Todoist, Things)
- [ ] Voice briefings
- [ ] Meeting transcription integration

## Documentation

- [README.md](README.md) - This file
- [QUICKSTART.md](QUICKSTART.md) - Quick start guide
- [MULTIPLE_CALENDARS.md](MULTIPLE_CALENDARS.md) - Multiple calendar setup
- [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md) - Technical overview
- [IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md) - Implementation details

## License

MIT

---

**Note**: This is a powerful productivity tool that requires access to sensitive personal data. Use responsibly and ensure you understand the permissions you're granting.

Built with Claude Sonnet 4.5
