#!/bin/bash

echo "=========================================="
echo "🤖 ALFRED AGENT MESSAGE SENDING DEMO"
echo "=========================================="
echo ""

cd "/Users/mitensampat/Documents/Claude apps/Alfred"

echo "1️⃣ STEP 1: Generate Briefing (Agents Analyze & Draft)"
echo "Command: swift run alfred briefing"
echo ""
echo "Press Enter to continue..."
read

swift run alfred briefing

echo ""
echo "=========================================="
echo ""
echo "2️⃣ STEP 2: View Drafts Created by Agents"
echo "Command: swift run alfred drafts"
echo ""
echo "Press Enter to continue..."
read

swift run alfred drafts

echo ""
echo "=========================================="
echo ""
echo "3️⃣ STEP 3: Send a Draft (Example)"
echo "Command: swift run alfred send-draft 1"
echo ""
echo "⚠️  NOTE: This will attempt to send an actual message!"
echo "         WhatsApp drafts won't send (needs Business API)"
echo "         iMessage drafts WILL send via Messages.app"
echo ""
echo "Type 'yes' to try sending, or 'no' to skip:"
read response

if [ "$response" = "yes" ]; then
    swift run alfred send-draft 1
else
    echo "Skipped sending. You can send drafts later with:"
    echo "  swift run alfred send-draft <number>"
fi

echo ""
echo "=========================================="
echo ""
echo "4️⃣ STEP 4: View Learning Database"
echo "Command: sqlite3 ~/.alfred/decisions.db 'SELECT * FROM decisions LIMIT 5'"
echo ""
echo "Press Enter to continue..."
read

if [ -f ~/.alfred/decisions.db ]; then
    echo "Recent agent decisions:"
    sqlite3 ~/.alfred/decisions.db "SELECT agent_type, action_type, confidence, executed_at FROM decisions ORDER BY timestamp DESC LIMIT 5"
    echo ""
    echo "Total decisions: $(sqlite3 ~/.alfred/decisions.db 'SELECT COUNT(*) FROM decisions')"
else
    echo "No decisions database yet. Run 'alfred briefing' first."
fi

echo ""
echo "=========================================="
echo "✅ DEMO COMPLETE"
echo "=========================================="
echo ""
echo "Key commands:"
echo "  alfred briefing       - Agents analyze and create drafts"
echo "  alfred drafts         - View pending drafts"
echo "  alfred send-draft N   - Send draft number N"
echo "  alfred clear-drafts   - Remove all drafts"
echo ""
echo "Files to inspect:"
echo "  ~/.alfred/message_drafts.json   - Pending drafts"
echo "  ~/.alfred/decisions.db          - Agent decision log"
echo "  ~/.alfred/learning.db           - Learning patterns"
echo ""
echo "Read AGENT_MESSAGING.md for complete documentation!"
echo ""
