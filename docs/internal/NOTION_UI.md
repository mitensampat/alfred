# Notion-Inspired UI Implementation

## Overview

Alfred now features a clean, Notion-inspired conversational interface for both Web and Desktop applications, replacing the previous menubar and dark-themed designs.

## Design Philosophy

### Notion Design Language

- **Clean & Minimal**: Whitespace-first design with subtle borders
- **Typography**: System fonts with careful size/weight hierarchy
- **Colors**: Neutral palette (beige/gray) with blue accent
- **Interactions**: Smooth transitions, hover states, and animations
- **Conversational**: Chat-first interface vs. traditional dashboard

### Color Palette

```
Background:   #f7f6f3  (warm beige-gray)
Surface:      #ffffff  (white cards)
Border:       #e9e9e7  (subtle gray)
Text:         #37352f  (dark gray, not black)
Secondary:    #787774  (medium gray)
Tertiary:     #9b9a97  (light gray)
Accent:       #2383e2  (bright blue)
```

## Web Interface

### File Structure

**New Notion UI**: `/Sources/GUI/Resources/index-notion.html`
- Clean HTML5 with embedded CSS and JavaScript
- No external dependencies
- Mobile-responsive design
- Fully self-contained

### Key Features

1. **Authentication Screen**
   - Centered card layout
   - Clean typography
   - Smooth error handling

2. **Chat Interface**
   - Message bubbles with avatars (👤 user, 🤖 Alfred)
   - Timestamps for each message
   - Loading indicator with animated dots
   - Suggested follow-ups as action chips

3. **Quick Prompts** (shown when empty)
   - Grid layout with 4 common actions
   - Icon + title + description
   - Hover effects with subtle lift

4. **Input Area**
   - Auto-resizing textarea
   - Send button (↑ arrow)
   - Sticky positioning at bottom
   - Disabled state when empty

### Usage

```bash
# Start the server
swift run alfred-app

# Access web interface
open http://localhost:8080
```

The web interface automatically loads the Notion-styled UI at the root path (`/`).

## Desktop App

### Architecture

**Entry Point**: `/Sources/GUI/AlfredMenuBarApp.swift`
- Changed from menubar popover to full window app
- `WindowGroup` with `ConversationView`
- Hidden title bar with unified toolbar style
- Minimum size: 700x600

**Main View**: `/Sources/GUI/Views/ConversationView.swift`
- SwiftUI-based conversation interface
- Matches web UI design philosophy
- Native macOS feel with Notion aesthetics

### Key Components

#### `ConversationView`
Main chat interface:
- Header with app name and tagline
- Scrollable message list
- Sticky input area at bottom
- Quick prompts when empty

#### `ConversationMessage`
Message model:
```swift
struct ConversationMessage: Identifiable {
    let id: UUID
    let text: String
    let isUser: Bool
    let timestamp: Date
    let isLoading: Bool
    let suggestions: [String]?
}
```

#### `MessageBubble`
Individual message display:
- Avatar (👤 for user, 🤖 for Alfred)
- Name + timestamp header
- Message text (card for user, plain for assistant)
- Suggested actions as chips

#### `QuickPromptCard`
Reusable prompt button:
- Icon + title + description
- Hover effects
- Grid layout (2 columns)

#### `ConversationViewModel`
State management:
- Message history
- Session ID for context tracking
- API communication
- Loading states

### Window Appearance

```swift
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.styleMask.insert(.fullSizeContentView)
window.isMovableByWindowBackground = true
window.backgroundColor = NSColor(red: 0.97, green: 0.96, blue: 0.95, alpha: 1.0)
```

### Usage

```bash
# Build and run desktop app
swift run alfred-app

# Or build executable
swift build
.build/debug/alfred-app
```

The app opens as a standard window (not menubar) with the conversational interface.

## Session Management

Both web and desktop apps maintain conversation context:

```javascript
// Web (JavaScript)
let sessionId = generateSessionId(); // Generated once per page load

// Desktop (Swift)
private let sessionId = UUID().uuidString // Generated once per app launch
```

Sessions are included in API requests to enable multi-turn conversations with context awareness.

## API Integration

### Request Format

```json
POST /api/query
{
  "query": "Show me commitments to Mona Gandhi",
  "sessionId": "session-abc123"
}
```

### Response Format

```json
{
  "type": "result",
  "query": "Show me commitments to Mona Gandhi",
  "response": "Found 3 commitments...",
  "data": {...},
  "intent": {
    "action": "list",
    "target": "commitments",
    "confidence": 0.95
  },
  "suggestedFollowUps": [
    "Show overdue commitments",
    "Scan for new commitments"
  ],
  "sessionId": "session-abc123"
}
```

## Switching Between UIs

### Web Interface

The Notion UI is now the default at `/`. Legacy UIs remain accessible:

- **Notion UI**: `http://localhost:8080/` (default)
- **V2 UI**: `http://localhost:8080/index-v2.html`
- **V1 UI**: Fallback if Notion UI not found

### Desktop App

To switch back to menubar app:

1. Restore backup: `mv Sources/GUI/AlfredMenuBarApp.swift.backup Sources/GUI/AlfredMenuBarApp.swift`
2. Delete current: `rm Sources/GUI/AlfredMenuBarApp.swift`
3. Rename backup: `mv *.backup AlfredMenuBarApp.swift`
4. Rebuild: `swift build`

## Responsive Design

### Web Interface

```css
@media (max-width: 640px) {
    .container { padding: 24px 16px; }
    .header h1 { font-size: 32px; }
    .quick-prompts-grid { grid-template-columns: 1fr; }
}
```

### Desktop App

- Minimum window size: 700x600
- Flexible layout adapts to window resize
- ScrollView for message history
- Sticky input always visible

## Key Differences from Previous Design

| Aspect | Previous (Dark) | New (Notion) |
|--------|----------------|--------------|
| Color Scheme | Dark (#1a1d21) | Light (#f7f6f3) |
| Layout | Dashboard with sections | Conversational chat |
| Navigation | Menubar popover | Full window app |
| Typography | Sans-serif, white | System fonts, dark gray |
| Interactions | Button-heavy | Chat-first with quick prompts |
| Mobile | Complex responsive grid | Simple, mobile-friendly chat |

## Implementation Files

### Web
- `/Sources/GUI/Resources/index-notion.html` - Complete web interface
- `/Sources/GUI/Services/HTTPServer.swift` - Updated to serve Notion UI

### Desktop
- `/Sources/GUI/AlfredMenuBarApp.swift` - Main entry point (window app)
- `/Sources/GUI/Views/ConversationView.swift` - SwiftUI conversation interface
- `Sources/GUI/AlfredMenuBarApp.swift.backup` - Original menubar app (backup)

### Shared
- Enhanced intent recognition with session support
- Conversation context tracking
- Multi-turn conversation capabilities

## Future Enhancements

Planned improvements:

1. **Rich Message Types**
   - Calendar event cards
   - Commitment lists with checkboxes
   - Meeting briefing cards
   - Attachment support

2. **Advanced Interactions**
   - Inline editing of commitments
   - Quick actions in message bubbles
   - Drag-and-drop for files
   - Voice input

3. **Personalization**
   - Custom color themes
   - Font size preferences
   - Compact/comfortable density modes
   - Saved quick prompts

4. **Data Visualization**
   - Calendar timeline view
   - Commitment kanban board
   - Priority matrix
   - Analytics dashboard

5. **Collaboration**
   - Share conversations
   - Export to PDF/Markdown
   - Multi-user sessions
   - Team briefings

## Testing

### Web Interface

```bash
# Start server
swift run alfred-app

# Test in browser
open http://localhost:8080

# Try quick prompts
- Click "Daily Briefing"
- Click "Commitments"
- Type custom query
```

### Desktop App

```bash
# Run app
swift run alfred-app

# Test features
- Type a message and press Enter
- Try quick prompt cards
- Test suggested follow-ups
- Resize window to test layout
```

### Multi-turn Conversations

```
Turn 1: "Show me commitments to Mona Gandhi"
Turn 2: "What about from last week?"
Turn 3: "Mark them as done"
```

Session context should resolve references across turns.

## Build & Deploy

### Development

```bash
# Build both CLI and GUI
swift build

# Run desktop app
swift run alfred-app

# Run CLI
swift run alfred
```

### Production

```bash
# Build release
swift build -c release

# Executables
.build/release/alfred      # CLI
.build/release/alfred-app  # Desktop app
```

The web interface is embedded in the desktop app's Resources.

## Troubleshooting

### Web UI Not Loading

1. Check HTML file exists: `ls Sources/GUI/Resources/index-notion.html`
2. Verify server is running: `curl http://localhost:8080/api/health`
3. Check console logs for file path errors

### Desktop App White Screen

1. Verify ConversationView.swift compiles
2. Check window appearance code runs
3. Look for SwiftUI errors in console

### Session Context Not Working

1. Verify sessionId is included in requests
2. Check IntentRecognitionService has ConversationContext
3. Test with simple follow-up: "Show commitments" → "What about yesterday?"

### API Connection Failed

1. Confirm passcode is correct in config.json
2. Verify server is running on correct port (8080)
3. Check network/firewall settings

## Credits

- Design inspired by Notion's clean, minimal aesthetic
- Built with SwiftUI for macOS and vanilla HTML/CSS/JS for web
- Powered by Claude Sonnet 4.5 for intent recognition
- Session management enables conversational AI experience
