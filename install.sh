#!/bin/bash

# Alfred Installation Script
# This script installs Alfred to your system

set -e  # Exit on error

echo "🦇 Alfred Installation"
echo "====================="
echo ""

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ Error: Alfred only supports macOS"
    exit 1
fi

# Check for Swift
if ! command -v swift &> /dev/null; then
    echo "❌ Error: Swift is not installed"
    echo "Please install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

echo "✓ Swift found: $(swift --version | head -1)"
echo ""

# Check if config exists
if [ ! -f "Config/config.json" ]; then
    echo "⚠️  Configuration file not found"
    if [ -f "Config/config.example.json" ]; then
        echo "Creating config.json from example..."
        cp Config/config.example.json Config/config.json
        echo "✓ Created Config/config.json"
        echo ""
        echo "⚠️  IMPORTANT: Edit Config/config.json with your credentials:"
        echo "  - Anthropic API key"
        echo "  - Google Calendar OAuth credentials"
        echo "  - SMTP email settings (optional)"
        echo ""
        read -p "Press Enter to continue after editing config.json, or Ctrl+C to exit..."
    else
        echo "❌ Error: Config/config.example.json not found"
        exit 1
    fi
fi

# Build release version
echo "🔨 Building Alfred..."
swift build -c release

if [ $? -ne 0 ]; then
    echo "Error: Build failed"
    exit 1
fi

# Create local bin directory if it doesn't exist
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"

# Create config directory
CONFIG_DIR="$HOME/.config/alfred"
mkdir -p "$CONFIG_DIR"

# Copy config if it doesn't exist in standard location
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    if [ -f "Config/config.json" ]; then
        echo "Copying config.json to $CONFIG_DIR..."
        cp "Config/config.json" "$CONFIG_DIR/"
    fi
fi

# Copy token files if they exist
if ls Config/google_tokens_*.json 1> /dev/null 2>&1; then
    echo "Copying token files to $CONFIG_DIR..."
    cp Config/google_tokens_*.json "$CONFIG_DIR/" 2>/dev/null || true
fi

# Install binary
INSTALL_PATH="$LOCAL_BIN/alfred"
BINARY_PATH="$(pwd)/.build/release/alfred"

echo "Installing binary to $INSTALL_PATH..."

# Copy the binary directly instead of symlinking
cp "$BINARY_PATH" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

echo "✓ Build complete"
echo "📦 Binary installed to $INSTALL_PATH"
echo ""

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
    echo "⚠️  ~/.local/bin is not in your PATH"
    echo "Adding to your shell configuration..."

    # Detect shell
    if [ -n "$ZSH_VERSION" ]; then
        SHELL_RC="$HOME/.zshrc"
    elif [ -n "$BASH_VERSION" ]; then
        SHELL_RC="$HOME/.bashrc"
    else
        SHELL_RC="$HOME/.profile"
    fi

    echo "" >> "$SHELL_RC"
    echo "# Added by Alfred installer" >> "$SHELL_RC"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"

    echo "✓ Added to $SHELL_RC"
    echo "  Run: source $SHELL_RC"
    echo "  Or restart your terminal"
    echo ""
fi

# Check for Full Disk Access (for iMessage)
echo "⚠️  IMPORTANT: For iMessage access, grant Full Disk Access:"
echo "  1. Open System Settings"
echo "  2. Go to Privacy & Security > Full Disk Access"
echo "  3. Add your terminal app (Terminal.app or iTerm2)"
echo "  4. Restart your terminal"
echo ""

echo "✅ Installation complete!"
echo ""
echo "Try it out:"
echo "  alfred calendar tomorrow"
echo "  alfred briefing"
echo "  alfred --help"
echo ""
echo "Next steps:"
echo "  1. Edit: ~/.config/alfred/config.json (with your credentials)"
echo "  2. Run: alfred auth  (to authenticate Google Calendar)"
echo "  3. Grant Full Disk Access for iMessage"
echo "  4. Test with: alfred calendar tomorrow"
echo ""
