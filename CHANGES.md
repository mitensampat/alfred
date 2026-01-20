# Changes Summary

## Latest: Commitments Tracker Enhancement (v1.2.1)

### Enhanced Command-Line Arguments
- **Flexible lookback period**: Now supports both numeric (`14`) and suffixed (`14d`) formats
- **Better UX**: More intuitive command syntax matching natural language
- **Example usage**: `alfred commitments scan "Akshay Aedula" 14d`

**All supported formats:**
```bash
# Scan specific person with lookback period
alfred commitments scan "Akshay Aedula" 14d
alfred commitments scan "Kunal Shah" 14

# Scan all configured contacts with custom lookback
alfred commitments scan 7d
alfred commitments scan 7

# Scan specific person with default lookback (from config)
alfred commitments scan "Swamy Seetharaman"

# Scan all configured contacts with default lookback
alfred commitments scan
```

**Implementation:**
- Added `parseDaysArgument()` helper function supporting both "14" and "14d" formats
- Updated usage documentation with examples
- Fully backward compatible with existing syntax

## New Features

### 1. **Gmail/Email Integration**
- Added full Gmail API integration to read and analyze emails
- Emails are fetched with 48-hour lookback (vs 24h for messaging)
- Separate quota system for emails (`max_email_threads_to_analyze`)
- Priority-based filtering with keyword detection for critical emails (HR terms like "resignation", "last working day", etc.)
- Authentication command: `alfred auth-gmail`

**Configuration:**
```json
"email": {
  "enabled": true,
  "analyze_in_briefing": true,  // NEW: User can opt-out of email analysis
  "client_id": "YOUR_GOOGLE_CLIENT_ID",
  "client_secret": "YOUR_GOOGLE_CLIENT_SECRET",
  "redirect_uri": "http://localhost:8080/auth/callback",
  "max_emails_to_analyze": 100
}
```

### 2. **LiteLLM API Proxy Support**
- Added support for LiteLLM and other API proxies
- Fully backward compatible - works with both direct Anthropic API and LiteLLM
- Optional `base_url` config parameter (defaults to Anthropic API)

**Configuration:**
```json
"ai": {
  "anthropic_api_key": "YOUR_API_KEY",
  "base_url": "https://api.anthropic.com/v1/messages",  // NEW: Optional, defaults to Anthropic
  "model": "claude-sonnet-4-5-20250929",
  "message_analysis_model": "claude-haiku-4-5-20250929",
  "max_threads_to_analyze": 20,
  "max_email_threads_to_analyze": 20  // NEW: Separate quota for emails
}
```

### 3. **Improved Notification System**
- Renamed `--email` flag to `--notify` for clarity
- Better status messages showing which channels were used (email, Slack, push)
- Renamed internal `sendEmail` parameter to `sendNotifications` throughout codebase

**Usage:**
```bash
# Send briefing to all enabled notification channels (email, Slack, push)
alfred briefing tomorrow --notify

# Just generate briefing without sending notifications
alfred briefing tomorrow
```

## Files Added

- `Sources/Services/GmailReader.swift` - Gmail API integration service
- `Sources/Models/Message.swift` - Added `email` platform to enum
- Gmail tokens stored at: `~/.config/alfred/gmail_tokens.json`

## Files Modified

- `Sources/Models/Config.swift`
  - Added `EmailPlatformConfig` with `analyze_in_briefing` option
  - Added `baseUrl` to `AIConfig` for LiteLLM support
  - Added `maxEmailThreadsToAnalyze` for separate email quotas

- `Sources/Core/BriefingOrchestrator.swift`
  - Integrated email fetching with 48h lookback
  - Added `prioritizeEmailThreads()` with keyword detection
  - Separate quotas for messaging vs email threads
  - Renamed `sendEmail` → `sendNotifications`

- `Sources/Services/ClaudeAIService.swift`
  - Changed `baseURL` from constant to configurable

- `Sources/App/main.swift`
  - Added `auth-gmail` command
  - Changed `--email` flag to `--notify`
  - Better notification status messages

- `Sources/Services/NotificationService.swift`
  - Added debug logging
  - Improved status messages

- `.gitignore`
  - Added `client_secret*.json`
  - Added `**/gmail_tokens.json`

- `Config/config.example.json`
  - Updated with new email and LiteLLM config options

## Security Improvements

- Added `client_secret*.json` to `.gitignore`
- Added Gmail token files to `.gitignore`
- Removed committed client_secret files

## Backward Compatibility

All changes are fully backward compatible:
- `base_url` is optional (defaults to Anthropic API)
- `analyze_in_briefing` defaults to `true`
- `max_email_threads_to_analyze` has sensible defaults
- Existing configs will continue to work without modification

## Testing

- ✅ Gmail authentication and email fetching
- ✅ Slack notifications
- ✅ WhatsApp focused thread analysis (Miten's feature)
- ✅ LiteLLM API proxy
- ✅ Separate messaging/email quotas
- ✅ Priority email detection with keywords
- ✅ Backward compatibility with direct Anthropic API
