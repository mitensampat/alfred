#!/bin/bash
# Grant Full Disk Access to Alfred
# This script opens System Preferences to the right pane

echo "Alfred Permission Setup"
echo "======================="
echo ""
echo "Alfred needs Full Disk Access to avoid repeated permission prompts."
echo ""
echo "The alfred binary is at: ~/.alfred/bin/alfred"
echo ""
echo "Steps:"
echo "1. System Preferences will open to Privacy & Security"
echo "2. Click 'Full Disk Access' on the left"
echo "3. Click the '+' button"
echo "4. Press Cmd+Shift+G and paste: ~/.alfred/bin/alfred"
echo "5. Click 'Open' to add it"
echo "6. Ensure the checkbox is enabled"
echo ""
echo "Press Enter to open System Preferences..."
read

# Open System Preferences to Privacy & Security > Full Disk Access
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

echo ""
echo "After adding Full Disk Access, restart Alfred:"
echo "  pkill -f 'alfred menubar'"
echo "  open ~/Documents/Claude\\ apps/Alfred/Alfred.app"
