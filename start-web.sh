#!/bin/bash

# Start Alfred HTTP Server for Web Interface
cd "$(dirname "$0")"

echo "🚀 Starting Alfred HTTP Server..."
echo "📍 Web interface will be available at: http://localhost:8080/web/index-notion.html"
echo "🔐 Passcode: REDACTED_PASSCODE"
echo ""

# Build and run just the HTTP server
swift run alfred-http-server

