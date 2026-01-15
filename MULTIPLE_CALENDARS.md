# Multiple Calendar Configuration Guide

## Overview
Alfred now supports multiple Google Calendar accounts. You can configure personal, work, or any number of Google Calendar accounts and the briefing will aggregate events from all of them.

## Configuration

### 1. Update Config.json

The `calendar.google` field is now an array of calendar accounts. Each account needs:
- `name`: A unique identifier for this calendar (e.g., "personal", "work", "secondary")
- `client_id`: Google OAuth Client ID
- `client_secret`: Google OAuth Client Secret
- `redirect_uri`: OAuth redirect URI (typically `http://localhost:8080/auth/callback`)

Example with two calendars:

```json
{
  "calendar": {
    "google": [
      {
        "name": "primary",
        "client_id": "YOUR_PRIMARY_CLIENT_ID",
        "client_secret": "YOUR_PRIMARY_CLIENT_SECRET",
        "redirect_uri": "http://localhost:8080/auth/callback"
      },
      {
        "name": "work",
        "client_id": "YOUR_WORK_CLIENT_ID",
        "client_secret": "YOUR_WORK_CLIENT_SECRET",
        "redirect_uri": "http://localhost:8080/auth/callback"
      }
    ]
  }
}
```

### 2. Authenticate Each Calendar

Run the auth command:

```bash
alfred auth
```

You'll see a menu:
```
Google Calendar Accounts Available:
  1. primary
  2. work

Enter the number of the account to authenticate (or 'all' for all accounts):
```

Options:
- Enter a number (e.g., `1`) to authenticate a single account
- Enter `all` to authenticate all accounts in sequence

For each account:
1. Visit the authorization URL in your browser
2. Sign in with the appropriate Google account
3. Grant permissions
4. Copy the `code` parameter from the redirect URL
5. Paste it into the terminal

Each calendar's tokens are stored separately as:
- `Config/google_tokens_primary.json`
- `Config/google_tokens_work.json`
- etc.

## How It Works

When you run `alfred briefing`, the system:
1. Fetches events from all configured calendars in parallel
2. Aggregates and deduplicates events by start time
3. Marks attendees as internal/external based on your company domains
4. Calculates total meeting time and focus slots across all calendars
5. Generates meeting briefings for external meetings

## Benefits

- **No context switching**: See all your meetings in one place
- **Comprehensive planning**: Total meeting time includes all calendars
- **Accurate focus time**: Free slots calculated across all events
- **External meeting detection**: Works across all calendar accounts

## Token Management

Each calendar account has its own token file in `Config/`:
- Tokens are automatically refreshed when expired
- Re-authenticate anytime by running `alfred auth`
- Tokens are git-ignored for security

## Adding a New Calendar

1. Add the new calendar configuration to `config.json`
2. Run `alfred auth`
3. Select the new calendar number or use `all`
4. Complete the OAuth flow

That's it! Your next briefing will include events from the new calendar.
