# Alfred - Your Personal Assistant 🦇

An AI-powered personal assistant that helps you manage your schedule, track commitments, and stay on top of messages across multiple platforms.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

### 📅 Calendar Management
- Google Calendar integration (multiple accounts)
- View today's schedule with meeting details
- See external attendees and locations
- Calculate available focus time
- AI-powered meeting briefings

### ✅ Commitment Tracking
- Extract commitments from conversations using AI
- Track "I owe" vs "They owe me"
- Store in Notion for easy management
- Scan messages for new commitments

### 💬 Message Analysis
- Read from iMessage, WhatsApp, and Signal
- AI-summarized conversations
- Action item extraction
- Contact-specific message history

### 🎯 Attention Defense
- Daily 3PM focus check alert
- Identify what needs attention
- Prioritize important tasks

### 🌐 Web Interface
- Clean, Notion-inspired UI
- Works on any device (phone, tablet, laptop)
- Remote access via local network or VPN
- Quick action buttons for common tasks

## Quick Start

### Prerequisites

- macOS 13+ (Ventura or later)
- Xcode Command Line Tools: `xcode-select --install`
- [Anthropic API key](https://console.anthropic.com/)
- [Google Calendar OAuth credentials](https://console.cloud.google.com/)

### Installation

```bash
# Clone the repository
git clone https://github.com/miten/alfred.git
cd alfred

# Copy and configure
cp Config/config.example.json Config/config.json
# Edit Config/config.json with your credentials

# Build
swift build

# Authenticate with Google Calendar
.build/debug/alfred auth

# Start the server
.build/debug/alfred server
```

### Access the Web Interface

Open in your browser:
```
http://localhost:8080/web/index-notion.html?passcode=YOUR_PASSCODE
```

## Usage

### Web Interface (Recommended)

The web interface provides quick action buttons for:
- 📋 Daily Briefing
- 📅 View Calendar (with date picker)
- 💬 Messages Summary
- ✅ Commitment Check
- 🔍 Scan Commitments
- 📝 Scan Todos
- 🎯 Attention Check

### CLI Commands

```bash
# Daily briefing
alfred briefing
alfred briefing tomorrow

# Calendar
alfred calendar today
alfred calendar work tomorrow
alfred calendar all 2026-01-27

# Messages
alfred messages all 24h
alfred messages whatsapp "Contact Name" 7d
alfred messages imessage 1h

# Commitments
alfred commitments scan 7d
alfred commitments check "Person Name"

# Attention
alfred attention
```

## Configuration

See [SETUP.md](SETUP.md) for detailed configuration instructions.

### Required Settings

| Setting | Description |
|---------|-------------|
| `api.passcode` | Secure passcode for web access |
| `ai.anthropic_api_key` | Your Anthropic API key |
| `calendar.google` | Google Calendar OAuth credentials |
| `user.name/email` | Your identity |

### Optional Integrations

| Integration | Purpose |
|-------------|---------|
| Notion | Commitment tracking database |
| Gmail | Email analysis in briefings |
| Slack | Notification delivery |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Alfred Application                        │
├─────────────────────────────────┬───────────────────────────┤
│         CLI Interface           │      Web Interface         │
│          (Swift)                │    (HTML/CSS/JS)           │
└─────────────────┬───────────────┴─────────────┬─────────────┘
                  │                             │
                  └──────────────┬──────────────┘
                                 │
                      ┌──────────▼──────────┐
                      │   HTTP API Server   │
                      │    (Port 8080)      │
                      └──────────┬──────────┘
                                 │
         ┌───────────┬───────────┼───────────┬───────────┐
         │           │           │           │           │
    ┌────▼────┐ ┌────▼────┐ ┌────▼────┐ ┌────▼────┐ ┌────▼────┐
    │ Google  │ │ Message │ │  Notion │ │ Claude  │ │  Query  │
    │Calendar │ │ Readers │ │   API   │ │   AI    │ │  Cache  │
    └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘
```

## Remote Access

### Same Network
```bash
# Find your Mac's IP
ifconfig | grep "inet " | grep -v 127.0.0.1

# Access from any device
http://YOUR_MAC_IP:8080/web/index-notion.html?passcode=YOUR_PASSCODE
```

### Over Internet (Tailscale recommended)
1. Install [Tailscale](https://tailscale.com/) on Mac and remote device
2. Access via Tailscale IP: `http://100.x.x.x:8080/...`

## Documentation

- [SETUP.md](SETUP.md) - Complete setup guide
- [CONTRIBUTING.md](CONTRIBUTING.md) - Contribution guidelines
- [CHANGELOG.md](CHANGELOG.md) - Version history
- [docs/](docs/) - Additional documentation

## Security Notes

- **Passcode**: Change the default passcode in `config.json`
- **Config file**: Contains sensitive credentials, git-ignored by default
- **Full Disk Access**: Required for message reading (iMessage, WhatsApp, Signal)
- **Local by default**: Server only accessible on your network unless you configure remote access

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- Built with [Swift](https://swift.org/)
- AI powered by [Anthropic Claude](https://www.anthropic.com/)
- Integrates with [Google Calendar](https://calendar.google.com/), [Notion](https://notion.so/), and more
