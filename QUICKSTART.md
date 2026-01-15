# Alfred - Quick Start Guide

Get up and running with Alfred in 10 minutes.

## Prerequisites

- macOS 13.0 or later
- Terminal access
- Google Calendar account(s)
- Anthropic API account
- Gmail account (for email notifications)

## Step 1: Installation (2 minutes)

### Navigate to Project

```bash
cd "/Users/mitensampat/Documents/Claude apps/Alfred"
```

### Run Installer

```bash
./install.sh
```

This will:
- Build the release binary
- Install `alfred` command to `~/.local/bin`
- Add `~/.local/bin` to your PATH in `~/.zshrc`

### Activate PATH

**Option A**: Open a new terminal window (recommended)

**Option B**: In current terminal:
```bash
source ~/.zshrc
```

### Verify Installation

```bash
alfred
```

You should see the help menu with all available commands.

## Step 2: Get API Credentials (5 minutes)

### Anthropic API Key

1. Visit https://console.anthropic.com/
2. Sign in or create account
3. Go to API Keys
4. Create a new key
5. Copy it (starts with `sk-ant-`)

### Google Calendar OAuth

1. Go to https://console.cloud.google.com/
2. Create a new project (or use existing)
3. Enable "Google Calendar API"
4. Go to "Credentials" → "Create Credentials" → "OAuth 2.0 Client ID"
5. Choose "Desktop app"
6. Copy Client ID and Client Secret
7. **Important**: Add authorized redirect URI: `http://localhost:8080/auth/callback`

**For multiple calendars**: Repeat this process for each Google account, or use the same project to access multiple calendars from one Google account.

### Gmail App Password (for email notifications)

1. Visit https://myaccount.google.com/apppasswords
2. Create an app password
3. Copy the 16-character password

## Step 3: Configure (2 minutes)

### Create Config File

```bash
cd "/Users/mitensampat/Documents/Claude apps/Alfred"
cp Config/config.example.json Config/config.json
```

### Edit Config

Open `Config/config.json` and update these key fields:

**Required:**
- `user.name`, `user.email`, `user.company_domains` - Your info
- `calendar.google[0].client_id` - Google OAuth Client ID
- `calendar.google[0].client_secret` - Google OAuth Client Secret
- `ai.anthropic_api_key` - Your Anthropic API key
- `notifications.email.smtp_username` - Your Gmail address
- `notifications.email.smtp_password` - Gmail app password

## Step 4: Grant Permissions (1 minute)

### Full Disk Access (Required for iMessage)

1. Open System Settings
2. Go to Privacy & Security → Full Disk Access
3. Click the "+" button
4. Add your Terminal app (Terminal.app or iTerm2)
5. Restart Terminal

**Without this**: iMessage reading will fail.

## Step 5: Authenticate Google Calendar (1 minute)

```bash
alfred auth
```

Type `1` (or `all`) when prompted.

The terminal will show a Google authorization URL:

1. Copy and paste the URL into your browser
2. Sign in to the correct Google account
3. Grant calendar permissions
4. You'll be redirected to: `http://localhost:8080/auth/callback?code=LONG_CODE&scope=...`
5. **Copy only the code** (part after `code=` and before `&`)
6. Paste into terminal and press Enter

You should see: `✓ Authentication successful for 'primary'!`

## Step 6: Test It! (1 minute)

### Generate Your First Briefing

```bash
alfred briefing
```

First run may take 10-30 seconds.

### Send Via Email

```bash
alfred briefing --email
```

Check your email for "Daily Briefing - [date]"

### Try Other Commands

```bash
# Tomorrow's briefing
alfred briefing tomorrow

# Specific date
alfred briefing 2026-01-20

# Recent messages
alfred messages imessage 1h

# Attention defense
alfred attention
```

## Common Issues

### "Failed to load configuration"
- Ensure `Config/config.json` exists
- Verify JSON is valid
- Check all required fields are filled

### "Failed to fetch iMessages"
- Grant Full Disk Access to Terminal
- Restart Terminal

### "Not authenticated with Google Calendar"
- Run `alfred auth` again
- Verify OAuth redirect URI is `http://localhost:8080/auth/callback`

### Email not sending
- Use Gmail **app password**, not regular password
- Check SMTP settings
- Use `--email` flag

### OAuth "Access blocked"
- Add yourself as test user in Google Cloud Console

## Next Steps

### Add Multiple Calendars

See [MULTIPLE_CALENDARS.md](MULTIPLE_CALENDARS.md)

### Run Automatically

Use a LaunchAgent to run briefings at scheduled times - see README.md for details.

---

**You're all set!** 🎉
