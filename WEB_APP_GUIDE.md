# Alfred Web App - The Simple, Working Solution

## Why Web App > Desktop App

The web app is **dramatically simpler** and more reliable:

| Feature | Web App | SwiftUI Desktop App |
|---------|---------|-------------------|
| **Code complexity** | Simple HTML/CSS/JS | Complex SwiftUI bindings |
| **Text input** | ✅ Works perfectly | ❌ Broken (TextField binding issues) |
| **Remote access** | ✅ Access from anywhere | ❌ Local only |
| **Debugging** | ✅ Browser DevTools | ❌ Xcode required |
| **Deployment** | ✅ Just open browser | ❌ Need to build/run |
| **Cross-platform** | ✅ Any device with browser | ❌ macOS only |

## How to Use

### 1. Start the Server

The server is already running! If not, start it:

```bash
cd "/Users/mitensampat/Documents/Claude apps/Alfred"
swift run alfred-app
```

Or use the CLI version which is lighter:
```bash
swift run alfred
```

### 2. Open Web Interface

**Option A: Direct URL**
```
http://localhost:8080/web/home.html?passcode=REDACTED_PASSCODE
```

**Option B: Enter passcode manually**
```
http://localhost:8080/web/home.html
```
Then enter passcode: `REDACTED_PASSCODE`

### 3. Use Alfred

Once authenticated:
- Click any quick prompt button (Daily Briefing, Calendar, etc.)
- Or type any question in the input box
- See formatted responses with calendar events, times, attendees
- Click suggested follow-ups to continue the conversation

## Features

### ✅ Working Features

1. **Quick Prompts**
   - 📋 Daily Briefing
   - ✅ Commitments
   - 📅 Calendar
   - 🎯 Attention Check

2. **Formatted Responses**
   - Calendar events with times and attendees
   - Focus time calculations
   - Clickable suggested follow-ups

3. **Conversation**
   - Message history
   - Context-aware follow-ups
   - Loading indicators

4. **Design**
   - Clean Notion-inspired UI
   - Responsive layout
   - Smooth animations

## Remote Access

### From Same Network

On another device on your network:
```
http://<your-mac-ip>:8080/web/home.html?passcode=REDACTED_PASSCODE
```

Find your IP: `ifconfig | grep "inet " | grep -v 127.0.0.1`

### From Internet (Advanced)

Use ngrok or similar:
```bash
ngrok http 8080
```

Then access via the ngrok URL.

## File Locations

- **Web interface**: `/Sources/GUI/Resources/home.html`
- **Server code**: `/Sources/GUI/Services/HTTPServer.swift`
- **Config**: `/Config/config.json`

## Customization

### Change Passcode

Edit `Config/config.json`:
```json
{
  "api": {
    "passcode": "your-new-passcode"
  }
}
```

### Change Port

Edit `Config/config.json`:
```json
{
  "api": {
    "port": 8080
  }
}
```

### Modify UI

Edit `/Sources/GUI/Resources/home.html` - it's just HTML/CSS/JavaScript!

## Advantages Over Desktop App

1. **No SwiftUI Issues** - Plain JavaScript, no binding problems
2. **Remote Access** - Use from phone, iPad, another computer
3. **Easy Debugging** - Browser DevTools show everything
4. **Faster Iteration** - Just refresh browser, no rebuild
5. **Mobile Friendly** - Responsive design works on any screen
6. **Shareable** - Send link to others (with passcode)

## Current Status

**Working:**
- ✅ All quick prompts
- ✅ Calendar with formatted events
- ✅ Suggested follow-ups (clickable)
- ✅ Message history
- ✅ Loading indicators
- ✅ Text input (obviously!)

**Not Yet Implemented:**
- Multi-line text input (currently single line)
- File uploads
- Voice input
- Push notifications

## Recommendation

**Use the web app** for daily use. It's simpler, works perfectly, and you can access it remotely. The desktop SwiftUI app has fundamental issues with text input that would require significant architectural changes to fix.

## Quick Start

```bash
# 1. Start server (if not running)
cd "/Users/mitensampat/Documents/Claude apps/Alfred"
swift run alfred-app &

# 2. Open in browser
open "http://localhost:8080/web/home.html?passcode=REDACTED_PASSCODE"

# 3. Click Calendar and enjoy!
```

That's it! 🎉
