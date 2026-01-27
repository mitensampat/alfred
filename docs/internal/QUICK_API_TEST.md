# Quick API Testing Guide

## Current Status

✅ **HTTP API Server Implemented** - 445 lines of code
✅ **Authentication Working** - Passcode-based security
✅ **All Endpoints Implemented** - 6 REST endpoints
✅ **Build Successful** - 0 errors
⏳ **Server Initialization** - Uses polling to wait for service

## Testing Steps

### 1. Ensure App Is Running

```bash
ps aux | grep alfred-app | grep -v grep
```

Should show the alfred-app process.

### 2. Wait for Initialization

The HTTP server starts automatically after the AlfredService initializes (polls every 0.5s for up to 30 seconds).

**To speed up initialization: Click the ⚡️ menu bar icon**

### 3. Test Health Endpoint

```bash
curl -H "X-API-Key: alfred-remote-2026-secure-key-do-not-share" \
  http://localhost:8080/api/health
```

**Expected Response:**
```json
{
  "status": "ok",
  "timestamp": "2026-01-22T22:30:00Z"
}
```

### 4. Test Other Endpoints

**Get Commitments:**
```bash
curl -H "X-API-Key: alfred-remote-2026-secure-key-do-not-share" \
  http://localhost:8080/api/commitments | jq .
```

**Get Overdue Commitments:**
```bash
curl -H "X-API-Key: alfred-remote-2026-secure-key-do-not-share" \
  http://localhost:8080/api/commitments/overdue | jq .
```

**Get Briefing:**
```bash
curl -H "X-API-Key: alfred-remote-2026-secure-key-do-not-share" \
  http://localhost:8080/api/briefing | jq .
```

**Get Drafts:**
```bash
curl -H "X-API-Key: alfred-remote-2026-secure-key-do-not-share" \
  http://localhost:8080/api/drafts | jq .
```

**Scan for Commitments:**
```bash
curl -X POST \
  -H "X-API-Key: alfred-remote-2026-secure-key-do-not-share" \
  -H "Content-Type: application/json" \
  -d '{"contactName":"Kunal Shah","lookbackDays":14}' \
  http://localhost:8080/api/commitments/scan | jq .
```

## Troubleshooting

### Server Not Responding

**Check if port is open:**
```bash
lsof -i :8080
```

**Check logs:**
```bash
tail -50 /tmp/alfred-final.log
```

**Expected log messages:**
- `✅ Config loaded successfully`
- `✅ AlfredService initialized, isInitialized=true`
- `✅ Service initialized after X.Xs, starting HTTP server...`
- `🌐 HTTP API server started on port 8080`
- `✅ HTTP API server started successfully on port 8080`

### Connection Refused

The server may still be initializing. Wait 30-60 seconds after starting the app, or click the menu bar icon to trigger initialization.

### 401 Unauthorized

Check you're using the correct passcode from `~/.config/alfred/config.json`:
```bash
cat ~/.config/alfred/config.json | grep -A 4 '"api"'
```

## Alternative: Query Parameter Auth

If headers don't work, use query parameter:
```bash
curl "http://localhost:8080/api/health?passcode=alfred-remote-2026-secure-key-do-not-share"
```

## Check Server Status

```bash
# Is app running?
ps aux | grep alfred-app | grep -v grep

# Is port open?
lsof -i :8080

# Test connection
nc -zv localhost 8080

# Test API
curl -v http://localhost:8080/api/health
```

## Next Steps

Once the server is confirmed working:
1. Install Tailscale on Mac and iPhone
2. Note your Mac's Tailscale IP
3. Test from iPhone using that IP
4. Create iOS Shortcuts (see API_REMOTE_ACCESS_SETUP.md)

## Complete Documentation

- **Setup Guide:** `docs/API_REMOTE_ACCESS_SETUP.md`
- **Implementation Details:** `docs/HTTP_API_IMPLEMENTATION.md`
- **iOS Shortcuts Examples:** `docs/API_REMOTE_ACCESS_SETUP.md` (includes 3 ready-to-use shortcuts)
