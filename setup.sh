#!/bin/bash

# Exec Assistant Setup Script
# This script helps you set up the Exec Assistant app

set -e

echo "======================================"
echo "  Exec Assistant Setup"
echo "======================================"
echo ""

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "Error: This app only works on macOS"
    exit 1
fi

# Check Swift version
echo "Checking Swift installation..."
if ! command -v swift &> /dev/null; then
    echo "Error: Swift is not installed. Please install Xcode from the App Store."
    exit 1
fi

SWIFT_VERSION=$(swift --version | head -n 1)
echo "Found: $SWIFT_VERSION"
echo ""

# Create config from example if it doesn't exist
if [ ! -f "Config/config.json" ]; then
    echo "Creating configuration file..."
    cp Config/config.example.json Config/config.json
    echo "✓ Created Config/config.json"
    echo ""
    echo "IMPORTANT: You need to edit Config/config.json with your credentials:"
    echo "  - Anthropic API key"
    echo "  - Google Calendar credentials"
    echo "  - Notion API key (optional)"
    echo "  - Email SMTP settings"
    echo "  - Slack webhook (optional)"
    echo ""
    read -p "Press Enter to open the config file in your default editor..."
    open -t Config/config.json
    echo ""
    read -p "After editing the config, press Enter to continue..."
else
    echo "✓ Configuration file already exists"
fi
echo ""

# Check database paths
echo "Checking message database paths..."

IMESSAGE_DB="$HOME/Library/Messages/chat.db"
if [ -f "$IMESSAGE_DB" ]; then
    echo "✓ iMessage database found"
else
    echo "⚠ iMessage database not found at $IMESSAGE_DB"
    echo "  You may need to update the path in config.json"
fi

WHATSAPP_DB="$HOME/Library/Application Support/WhatsApp/Databases/ChatStorage.sqlite"
if [ -f "$WHATSAPP_DB" ]; then
    echo "✓ WhatsApp database found"
else
    echo "⚠ WhatsApp database not found"
    echo "  Make sure WhatsApp Desktop is installed and you've used it recently"
fi

SIGNAL_DB="$HOME/Library/Application Support/Signal/sql/db.sqlite"
if [ -f "$SIGNAL_DB" ]; then
    echo "✓ Signal database found"
else
    echo "⚠ Signal database not found"
    echo "  Make sure Signal Desktop is installed and you've used it recently"
fi

echo ""

# Build the project
echo "Building Exec Assistant..."
if swift build -c release; then
    echo "✓ Build successful"
    echo ""
    echo "Executable location: .build/release/ExecAssistant"
else
    echo "✗ Build failed"
    echo "Please check the error messages above"
    exit 1
fi

echo ""
echo "======================================"
echo "  Setup Complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo ""
echo "1. Authenticate with Google Calendar:"
echo "   swift run ExecAssistant auth"
echo ""
echo "2. Grant Full Disk Access for message scanning:"
echo "   - Open System Settings"
echo "   - Go to Privacy & Security > Full Disk Access"
echo "   - Add your Terminal app"
echo "   - Restart Terminal"
echo ""
echo "3. Test the morning briefing:"
echo "   swift run ExecAssistant briefing"
echo ""
echo "4. Test the attention defense:"
echo "   swift run ExecAssistant attention"
echo ""
echo "5. Run in scheduled mode:"
echo "   swift run ExecAssistant schedule"
echo ""
echo "6. (Optional) Set up as launch agent:"
echo "   See README.md for instructions"
echo ""
echo "For detailed documentation, see README.md"
echo ""
