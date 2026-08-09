#!/usr/bin/env bash
# wa-bridge — build / pair / run the WhatsApp send bridge for Alfred (whatsmeow).
#
#   scripts/wa-bridge.sh build     # compile the Go binary
#   scripts/wa-bridge.sh pair      # run in the foreground; scan the QR once to link WhatsApp
#   scripts/wa-bridge.sh run       # same as pair, but the usual "keep it running" verb
#   scripts/wa-bridge.sh install   # load a launchd agent so it stays running (pair first)
#   scripts/wa-bridge.sh uninstall # stop + remove the launchd agent
#   scripts/wa-bridge.sh status    # curl the bridge /status
#
# One-time: run `pair`, open WhatsApp on your phone → Settings → Linked Devices →
# Link a Device, scan the QR. The session is saved in ~/.alfred/whatsmeow.db. After that
# you can `install` it as a background agent (no QR needed again).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tools/wa-bridge" && pwd)"
BIN="$DIR/wa-bridge"
# launchd must run the binary from a NON-TCC-protected location — executing from
# ~/Documents triggers a privacy assessment that hangs the agent in dyld. Run from ~/.alfred.
DEST="$HOME/.alfred/wa-bridge"
SIGN_ID="Alfred Dev (msfoundry)"
PLIST="$HOME/Library/LaunchAgents/com.msfoundry.alfred-wa-bridge.plist"

build() {
  ( cd "$DIR" && go build -o wa-bridge . ) || return 1
  codesign --force --sign "$SIGN_ID" --identifier com.msfoundry.alfred.wabridge "$BIN" 2>/dev/null || true
  echo "✓ built + signed $BIN"
}

stage() { # copy the signed binary to the non-TCC run location
  mkdir -p "$HOME/.alfred"
  cp "$BIN" "$DEST"
  codesign --force --sign "$SIGN_ID" --identifier com.msfoundry.alfred.wabridge "$DEST" 2>/dev/null || true
}

case "${1:-run}" in
  build) build ;;
  pair|run)
    [ -x "$BIN" ] || build
    echo "Starting wa-bridge on 127.0.0.1:8790 — Ctrl-C to stop."
    echo "If not yet linked, a QR will print below; scan it from WhatsApp → Linked Devices."
    exec "$BIN"
    ;;
  install)
    [ -x "$BIN" ] || build
    stage
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.msfoundry.alfred-wa-bridge</string>
  <key>ProgramArguments</key><array><string>$DEST</string></array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>WorkingDirectory</key><string>$HOME</string>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$HOME</string>
    <key>WA_BRIDGE_DIR</key><string>$HOME/.alfred</string>
    <key>WA_BRIDGE_ADDR</key><string>127.0.0.1:8790</string>
  </dict>
  <key>StandardOutPath</key><string>$HOME/.alfred/wa-bridge.log</string>
  <key>StandardErrorPath</key><string>$HOME/.alfred/wa-bridge.log</string>
</dict></plist>
PL
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "✓ wa-bridge launchd agent installed (running $DEST; logs: ~/.alfred/wa-bridge.log)"
    ;;
  uninstall)
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "✓ removed"
    ;;
  status)
    curl -s http://127.0.0.1:8790/status || echo "bridge not reachable"
    echo ""
    ;;
  *) echo "usage: $0 {build|pair|run|install|uninstall|status}"; exit 1 ;;
esac
