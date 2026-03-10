#!/bin/bash

# Alfred Startup Script
# Starts the HTTP server for CLI and Web access

cd "$(dirname "$0")"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🦇 Alfred - Your Personal Assistant"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Build if needed
if [ ! -f ".build/arm64-apple-macosx/debug/alfred" ]; then
    echo "Building Alfred..."
    swift build
    if [ $? -ne 0 ]; then
        echo "❌ Build failed"
        exit 1
    fi
    echo ""
fi

# Get local IP
LOCAL_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | head -1 | awk '{print $2}')

echo "✅ Starting HTTP server on port 8080"
echo ""
echo "📍 Access the web interface:"
echo ""
echo "   Local:"
echo "   http://localhost:8080/home.html?passcode=REDACTED_PASSCODE"
echo ""

if [ -n "$LOCAL_IP" ]; then
    echo "   Network:"
    echo "   http://$LOCAL_IP:8080/home.html?passcode=REDACTED_PASSCODE"
    echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Run the server
.build/arm64-apple-macosx/debug/alfred server
