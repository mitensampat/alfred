# Contributing to Alfred

Thanks for your interest in Alfred! This guide will help you get started.

## Getting Started

### Prerequisites
- macOS 13.0 or later
- Swift 5.9 or later (comes with Xcode Command Line Tools)
- Anthropic API key
- Google Calendar API credentials (optional)

### Installation for Development

1. Clone the repository:
```bash
git clone <your-repo-url>
cd Alfred
```

2. Copy and configure the example config:
```bash
cp Config/config.example.json Config/config.json
```

3. Edit `Config/config.json` with your credentials:
   - Add your Anthropic API key
   - Add Google Calendar OAuth credentials (if using calendar features)
   - Configure other settings as needed

4. Build and run:
```bash
swift build
.build/debug/alfred --help
```

## Project Structure

```
Alfred/
├── Sources/
│   ├── App/                    # CLI interface
│   ├── Core/                   # Business logic
│   ├── Models/                 # Data models
│   ├── Services/               # External integrations
│   │   ├── MessageReaders/    # Message platform readers
│   │   ├── ClaudeAIService.swift
│   │   ├── GoogleCalendarService.swift
│   │   └── ...
│   └── Utils/                  # Utilities
├── Config/                     # Configuration files
├── Tests/                      # Unit tests
└── Package.swift              # Swift package manifest
```

## Making Changes

### Code Style
- Follow Swift conventions
- Use meaningful variable names
- Add comments for complex logic
- Keep functions focused and concise

### Testing Your Changes

```bash
# Build
swift build

# Run tests (when available)
swift test

# Test specific commands
.build/debug/alfred calendar tomorrow
.build/debug/alfred briefing
```

### Configuration

The app uses a JSON configuration file with these sections:
- `app`: Application settings
- `user`: User information
- `calendar`: Calendar configurations
- `ai`: AI model settings
- `messaging`: Message platform settings
- `notifications`: Email/notification settings

See `Config/config.example.json` for details.

## Submitting Changes

1. Create a new branch:
```bash
git checkout -b feature/your-feature-name
```

2. Make your changes and commit:
```bash
git add .
git commit -m "Description of your changes"
```

3. Push and create a pull request

## Common Development Tasks

### Adding a New Command

1. Add command parsing in `Sources/App/main.swift`
2. Implement logic in appropriate service or orchestrator
3. Update help text
4. Test thoroughly

### Adding a New Service

1. Create service file in `Sources/Services/`
2. Define service protocol if needed
3. Integrate with `BriefingOrchestrator`
4. Add configuration to `Config.swift`

### Debugging

Enable verbose logging by adding debug prints or using breakpoints in Xcode:
```bash
swift package generate-xcodeproj
open Alfred.xcodeproj
```

## Getting Help

- Check existing issues
- Read the documentation in `/docs`
- Ask questions in discussions

## Code of Conduct

Be respectful, inclusive, and constructive in all interactions.

## License

MIT License - see LICENSE file for details
