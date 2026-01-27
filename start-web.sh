#!/bin/bash

# Start Alfred HTTP Server for Web Interface
cd "$(dirname "$0")"

echo "🚀 Starting Alfred HTTP Server..."
echo "📍 Web interface will be available at: http://localhost:8080/web/index-notion.html"
echo "🔐 Passcode: 1234567891011121314"
echo ""

# Build and run just the HTTP server
swift run alfred-http-server

