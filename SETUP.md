# Alfred Setup Guide

Complete guide to setting up Alfred on your Mac.

## Prerequisites

- **macOS 13+** (Ventura or later)
- **Swift 5.9+** (comes with Xcode Command Line Tools)
- **Xcode Command Line Tools**: `xcode-select --install`

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/miten/alfred.git
cd alfred
```

### 2. Configure Alfred

```bash
# Copy the example config
cp Config/config.example.json Config/config.json

# Edit with your credentials
nano Config/config.json  # or use your preferred editor
```

**Required configurations:**
- `api.passcode` - Change to a secure passcode
- `ai.anthropic_api_key` - Your Anthropic API key
- `calendar.google` - Google Calendar OAuth credentials
- `user` - Your name, email, and company domain

### 3. Build the Project

```bash
swift build
```

### 4. Authenticate with Google Calendar

```bash
.build/debug/alfred auth
```

Follow the OAuth flow in your browser.

### 5. Start the Server

```bash
.build/debug/alfred server
```

### 6. Open the Web Interface

Open in browser:
```
http://localhost:8080/web/index-notion.html?passcode=YOUR_PASSCODE
```

## Configuration Details

### API Section (Required for Web Interface)

```json
"api": {
  "enabled": true,
  "port": 8080,
  "passcode": "YOUR_SECURE_PASSCODE"
}
```

**Security Note**: Change the default passcode to something secure. The passcode protects your personal data.

### Google Calendar Setup

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project
3. Enable the Google Calendar API
4. Create OAuth 2.0 credentials (Desktop App)
5. Download credentials and add to config:

```json
"calendar": {
  "google": [
    {
      "name": "primary",
      "client_id": "YOUR_CLIENT_ID.apps.googleusercontent.com",
      "client_secret": "YOUR_CLIENT_SECRET",
      "redirect_uri": "http://localhost:8080/auth/callback",
      "calendar_id": "your.email@gmail.com"
    }
  ]
}
```

### Anthropic API Key

1. Get an API key from [Anthropic Console](https://console.anthropic.com/)
2. Add to config:

```json
"ai": {
  "anthropic_api_key": "sk-ant-..."
}
```

### Notion Integration (Optional)

For commitment tracking:

1. Create a [Notion Integration](https://www.notion.so/my-integrations)
2. Get the API key
3. Create a database and share it with your integration
4. Add to config:

```json
"notion": {
  "api_key": "secret_...",
  "database_id": "YOUR_DATABASE_ID"
}
```

### Message Access (macOS Permissions)

To read messages from iMessage, WhatsApp, and Signal, Alfred needs **Full Disk Access**:

1. Open **System Settings** > **Privacy & Security** > **Full Disk Access**
2. Add Terminal (or your terminal app like iTerm2)
3. Restart your terminal

**Default database paths:**
- iMessage: `~/Library/Messages/chat.db`
- WhatsApp: `~/Library/Application Support/WhatsApp/Databases/ChatStorage.sqlite`
- Signal: `~/Library/Application Support/Signal/sql/db.sqlite`

## Usage

### Web Interface (Recommended)

The web interface provides:
- Quick action buttons for common tasks
- Calendar view with date selection
- Message summaries
- Commitment tracking
- Conversational interface

**Access locally:**
```
http://localhost:8080/web/index-notion.html?passcode=YOUR_PASSCODE
```

**Access from other devices on your network:**
```
http://YOUR_MAC_IP:8080/web/index-notion.html?passcode=YOUR_PASSCODE
```

Find your Mac's IP: `ifconfig | grep "inet " | grep -v 127.0.0.1`

### CLI Commands

```bash
# Daily briefing
.build/debug/alfred briefing

# Calendar
.build/debug/alfred calendar today
.build/debug/alfred calendar tomorrow
.build/debug/alfred calendar work 2026-01-27

# Messages
.build/debug/alfred messages all 24h
.build/debug/alfred messages whatsapp "Contact Name" 7d

# Attention check
.build/debug/alfred attention
```

## Remote Access

### Option 1: Tailscale (Recommended)

1. Install [Tailscale](https://tailscale.com/) on your Mac and remote device
2. Access via Tailscale IP: `http://100.x.x.x:8080/web/index-notion.html?passcode=YOUR_PASSCODE`

### Option 2: ngrok

```bash
ngrok http 8080
```

Use the ngrok URL from any device.

## Troubleshooting

### Server won't start
- Check if port 8080 is in use: `lsof -i :8080`
- Kill existing process: `pkill alfred`

### Calendar not showing events
- Verify Google Calendar credentials
- Re-authenticate: `.build/debug/alfred auth`
- Test CLI: `.build/debug/alfred calendar today`

### Messages not loading
- Grant Full Disk Access to Terminal
- Verify database paths in config
- Check if messaging apps store data locally

### Web interface authentication fails
- Ensure passcode in URL matches config
- Clear browser cache
- Check server logs for errors

## Development

### Project Structure

```
Alfred/
├── Config/
│   ├── config.json          # Your configuration (git-ignored)
│   └── config.example.json  # Template
├── Sources/
│   ├── App/main.swift       # CLI entry point
│   ├── Core/                # Business logic
│   ├── Models/              # Data models
│   ├── Services/            # API integrations
│   │   ├── HTTPServer.swift # Web server
│   │   └── ...
│   └── GUI/
│       └── Resources/       # Web interface files
└── .build/debug/alfred      # Compiled binary
```

### Making Changes

**Web interface only:**
Edit `Sources/GUI/Resources/index-notion.html`, save, and refresh browser.

**Backend changes:**
```bash
swift build
pkill alfred
.build/debug/alfred server
```

## Support

- Issues: https://github.com/miten/alfred/issues
- Documentation: See `/docs` folder for detailed guides
