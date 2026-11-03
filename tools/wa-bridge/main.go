// wa-bridge — a long-running WhatsApp I/O helper for Alfred, built on whatsmeow (the same
// library Commit uses). It wraps a whatsmeow client + a pure-Go SQLite session store and a
// local message/contact cache, and exposes a localhost HTTP API:
//
//	GET  /status              -> {"paired":bool,"connected":bool,"logged_out":bool,"pairing":bool,
//	                              "messages":int,"newest_message":unix,"reason":"...",
//	                              "last_connected":rfc3339,"last_disconnect":rfc3339,"jid":"..."}
//	GET  /qr                  -> {"code":"..."} current pairing code (empty once paired)
//	POST /send  {jid,message} -> {"ok":bool,"id":"...","error":"..."}
//	POST /repair              -> clears an unusable session and offers a fresh QR
//	GET  /messages?since=&chat=&limit=  -> [{id,chat_jid,sender_jid,sender_name,chat_name,content,timestamp,is_from_me,is_group}]
//	GET  /contacts            -> [{jid,full_name,first_name,push_name}]
//
// It ingests messages two ways: whatsmeow's link-time HistorySync (recent backfill) and
// live *events.Message (forward capture, inbound + outbound). Text-only, deduped by message
// ID. The recipient JID for sends comes straight from Alfred's commitment thread_id, which is
// already a WhatsApp JID. One-time pairing: run the binary, scan the QR from WhatsApp →
// Linked Devices.
//
// On reporting failure honestly: WhatsApp ingestion once stopped for five weeks without
// anything noticing, because every signal the bridge emitted was a false green. `paired`
// reflects the session saved on disk, so it stayed true while the socket was dead; the 6-hourly
// "contact sync: N contacts" line reads the *local* store, so it kept printing a healthy count;
// and whatsmeow was handed waLog.Noop, which dropped every reconnect error and every
// "deleting session" notice the library tried to emit. So: the library gets a real logger,
// every connection-state event is handled and logged with a timestamp, /status reports
// `connected` plus the age of the newest message, and a session that can no longer be used can
// be re-paired through /repair instead of requiring someone to delete whatsmeow.db by hand.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/mdp/qrterminal/v3"
	"rsc.io/qr"
	"go.mau.fi/whatsmeow"
	waProto "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"
)

// maxReconnectBackoffSteps caps whatsmeow's reconnect delay. It waits
// AutoReconnectErrors*2 seconds between attempts and never resets that counter, so across a
// long outage the gap grows without bound — by the thousandth failure it is over half an hour,
// and it keeps climbing. 150 steps pins the ceiling at five minutes.
const maxReconnectBackoffSteps = 150

type app struct {
	wa        *whatsmeow.Client
	store     *Store
	container *sqlstore.Container
	waLog     waLog.Logger
	qr        string
	mu        sync.RWMutex

	// Connection health. `paired` alone cannot answer "is this thing working?" — it describes
	// the session on disk, not the socket — so these record what actually happened and when.
	lastConnected  time.Time
	lastDisconnect time.Time
	lastReason     string // why the bridge is not receiving, in plain words
	loggedOut      bool   // session invalidated; needs a QR scan
	pairing        bool   // a pairLoop is running right now
}

// logf timestamps every line. The log used to interleave timestamped whatsmeow output with
// bare fmt.Println lines, so there was no way to date a state change after the fact.
func logf(format string, args ...any) {
	fmt.Printf("[%s] %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, args...))
}

// client reads the current client under the lock. Pairing replaces the client wholesale, so
// nothing may hold on to a stale pointer across a re-pair.
func (a *app) client() *whatsmeow.Client {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.wa
}

// adoptClient installs a client and all its wiring. Every path that creates a client goes
// through here so the event handler and the reconnect hook can never be forgotten.
func (a *app) adoptClient(c *whatsmeow.Client) {
	c.AddEventHandler(a.handleEvent)
	c.AutoReconnectHook = a.onReconnectFailure
	a.mu.Lock()
	a.wa = c
	a.qr = ""
	a.mu.Unlock()
}

func dataDir() string {
	if d := os.Getenv("WA_BRIDGE_DIR"); d != "" {
		os.MkdirAll(d, 0o755)
		return d
	}
	home, _ := os.UserHomeDir()
	d := filepath.Join(home, ".alfred")
	os.MkdirAll(d, 0o755)
	return d
}

func main() {
	ctx := context.Background()
	dir := dataDir()

	st, err := openStore(dir)
	if err != nil {
		panic(fmt.Sprintf("open message store: %v", err))
	}

	// whatsmeow used to be handed waLog.Noop, which threw away every reconnect error and
	// every "device removed, deleting session" notice it emitted — the single biggest reason
	// a five-week outage left no evidence. WARN keeps the log readable while still surfacing
	// anything that matters; WA_BRIDGE_LOG_LEVEL=DEBUG when diagnosing.
	level := os.Getenv("WA_BRIDGE_LOG_LEVEL")
	if level == "" {
		level = "WARN"
	}
	logger := waLog.Stdout("whatsmeow", level, false)

	container, err := sqlstore.New(ctx, "sqlite",
		fmt.Sprintf("file:%s?_pragma=foreign_keys(1)", filepath.Join(dir, "whatsmeow.db")), logger.Sub("db"))
	if err != nil {
		panic(fmt.Sprintf("open session store: %v", err))
	}
	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		panic(fmt.Sprintf("get device: %v", err))
	}

	a := &app{store: st, container: container, waLog: logger}
	a.adoptClient(whatsmeow.NewClient(device, logger))

	if device.ID == nil {
		go a.beginPairing(ctx) // keeps a fresh QR available until scanned (survives timeouts)
	} else if err := a.client().Connect(); err != nil {
		// Deliberately not fatal. Exiting here would just have launchd restart the bridge
		// into the same failure, and KeepAlive would spin. Staying up keeps /status and
		// /repair reachable — so the failure is visible and fixable — while whatsmeow's
		// autoreconnect keeps trying underneath.
		logf("⚠️  initial connect failed: %v — staying up so /status and /repair work; autoreconnect will retry", err)
	} else {
		logf("✓  WhatsApp connecting (existing session)")
	}

	// Refresh the contact name cache every 6h.
	go func() {
		t := time.NewTicker(6 * time.Hour)
		for range t.C {
			a.syncContacts(context.Background())
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/status", a.handleStatus)
	mux.HandleFunc("/qr", a.handleQR)
	mux.HandleFunc("/qr.png", a.handleQRPNG)
	mux.HandleFunc("/send", a.handleSend)
	mux.HandleFunc("/repair", a.handleRepair)
	mux.HandleFunc("/messages", a.handleMessages)
	mux.HandleFunc("/contacts", a.handleContacts)

	addr := "127.0.0.1:8790"
	if v := os.Getenv("WA_BRIDGE_ADDR"); v != "" {
		addr = v
	}
	fmt.Println("wa-bridge listening on", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		panic(err)
	}
}

// beginPairing gets a scannable QR in front of the user, replacing the client first when the
// current one can no longer pair.
//
// That replacement is not optional: store.Device.Delete marks the device deleted and swaps
// every one of its stores for a NoopStore that errors, so once a session has been deleted —
// by whatsmeow on logout, or by /repair — the old client is permanently inert and
// GetQRChannel on it cannot succeed. Pairing needs a brand new device and client.
//
// The `pairing` flag keeps this to one loop at a time, since both a LoggedOut event and a
// /repair call can reach it.
func (a *app) beginPairing(ctx context.Context) {
	a.mu.Lock()
	if a.pairing {
		a.mu.Unlock()
		return
	}
	a.pairing = true
	stale := a.wa == nil || a.wa.Store == nil || a.wa.Store.Deleted || a.wa.Store.ID != nil
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		a.pairing = false
		a.mu.Unlock()
	}()

	if stale {
		a.adoptClient(whatsmeow.NewClient(a.container.NewDevice(), a.waLog))
		logf("🔁  new session created — waiting for a QR scan (GET /qr.png)")
	}
	a.pairLoop(ctx)
}

// pairLoop keeps a scannable QR available: whatsmeow's QR channel times out after a few
// minutes, so on timeout we disconnect and request a fresh one. Exits once paired.
func (a *app) pairLoop(ctx context.Context) {
	for {
		c := a.client()
		if c == nil || c.Store == nil || c.Store.ID != nil {
			return
		}
		qrChan, err := c.GetQRChannel(ctx)
		if err != nil {
			logf("⚠️  could not open a pairing channel: %v", err)
			_ = c.Connect()
			return
		}
		if err := c.Connect(); err != nil {
			logf("⚠️  connect during pairing failed: %v — retrying in 10s", err)
			time.Sleep(10 * time.Second)
			continue
		}
		paired := false
		for evt := range qrChan {
			switch evt.Event {
			case "code":
				a.mu.Lock()
				a.qr = evt.Code
				a.mu.Unlock()
				logf("📱  Scan in WhatsApp → Settings → Linked Devices → Link a Device:")
				qrterminal.GenerateHalfBlock(evt.Code, qrterminal.L, os.Stdout)
			case "success":
				a.mu.Lock()
				a.qr = ""
				a.loggedOut = false
				a.lastReason = ""
				a.mu.Unlock()
				logf("✓  Paired. Session saved. %d previously ingested messages kept.", a.store.MessageCount())
				go a.syncContacts(context.Background())
				paired = true
			default:
				logf("pairing event: %s", evt.Event) // timeout / error
			}
		}
		if paired || c.Store.ID != nil {
			return
		}
		// Channel closed without success (timeout) — clear stale code, reset, retry.
		a.mu.Lock()
		a.qr = ""
		a.mu.Unlock()
		c.Disconnect()
		time.Sleep(3 * time.Second)
	}
}

// ── event handling / ingestion ──

// handleEvent routes whatsmeow's events. Every case below except Message/HistorySync exists
// because the bridge used to handle none of them: a session could be unlinked, replaced,
// banned or simply dropped and the only observable effect was that messages quietly stopped
// arriving. Each one now says, in the log, that ingestion has stopped and why.
func (a *app) handleEvent(evt any) {
	switch e := evt.(type) {
	case *events.Message:
		a.handleMessage(e)
	case *events.HistorySync:
		go a.handleHistorySync(e)
	case *events.Connected:
		a.onConnected()
	case *events.LoggedOut:
		go a.onLoggedOut(e)
	case *events.StreamReplaced:
		a.noteDisconnect("stream replaced — another process is connected with this session")
	case *events.ClientOutdated:
		a.noteDisconnect("client outdated — rebuild wa-bridge against a newer whatsmeow")
	case *events.ConnectFailure:
		a.noteDisconnect("connect failure: " + e.Reason.String())
	case *events.TemporaryBan:
		a.noteDisconnect(e.String())
	case *events.KeepAliveTimeout:
		a.noteDisconnect("keepalive timeout — the socket has stopped answering")
	case *events.KeepAliveRestored:
		logf("✓  keepalive restored")
	case *events.Disconnected:
		a.noteDisconnect("socket disconnected")

	// ── pairing ──
	// A scan that fails on the phone ("couldn't link device", "check your connection")
	// produces nothing at all unless these are handled: the QR channel only reports its own
	// timeouts, so a server-side rejection or an unsupported handshake step is invisible and
	// looks identical to nobody scanning. Log every one of them.
	case *events.PairSuccess:
		logf("✓  pair success: %s (platform %q, business %q)", e.ID, e.Platform, e.BusinessName)
	case *events.PairError:
		logf("❌  pair FAILED for %s after the server accepted the scan: %v", e.ID, e.Error)
	case *events.QRScannedWithoutMultidevice:
		logf("❌  QR scanned but multi-device is not enabled on the phone — enable it in " +
			"WhatsApp → Settings → Linked Devices, then scan the same code again")
	case *events.PairPasskeyRequest:
		// WhatsApp can require a WebAuthn passkey handshake to link a device. whatsmeow hands
		// the challenge over and expects Client.SendPasskeyResponse with a response from an
		// authenticator; this bridge has no authenticator, so pairing cannot complete and the
		// phone reports a generic connection error. Say so plainly rather than stalling mutely.
		logf("❌  WhatsApp requires a PASSKEY handshake to link this device, which wa-bridge " +
			"does not implement — pairing cannot complete, and the phone will show a generic " +
			"connection error. This needs SendPasskeyResponse backed by a WebAuthn authenticator.")
	case *events.PairPasskeyError:
		logf("❌  passkey handshake error (continuation=%v): %v", e.Continuation, e.Error)
	case *events.PairPasskeyConfirmation:
		logf("📱  passkey confirmation code %q (skip_handoff=%v)", e.Code, e.SkipHandoffUX)
	}
}

// onConnected fires when the websocket comes up — which happens during QR pairing too, before
// there is any session. Only a connection that is also logged in means messages are flowing, so
// anything else must not clear the recorded failure reason or it erases the diagnosis.
func (a *app) onConnected() {
	c := a.client()
	if c == nil || !c.IsLoggedIn() {
		logf("socket connected (not logged in yet)")
		return
	}
	a.mu.Lock()
	reconnect := !a.lastConnected.IsZero()
	a.lastConnected = time.Now()
	a.lastReason = ""
	a.loggedOut = false
	a.mu.Unlock()
	if reconnect {
		logf("✓  WhatsApp reconnected — ingestion resumed")
	} else {
		logf("✓  WhatsApp connected — ingesting")
	}
	go a.syncContacts(context.Background())
}

// noteDisconnect records why the bridge is not receiving, for /status and for the log. None of
// these states is cosmetic: whenever `connected` is false, nothing is being ingested.
func (a *app) noteDisconnect(reason string) {
	a.mu.Lock()
	a.lastDisconnect = time.Now()
	a.lastReason = reason
	a.mu.Unlock()
	logf("⚠️  WhatsApp not receiving: %s", reason)
}

// onLoggedOut handles the session being invalidated — unlinked from the phone, logged out from
// another device, or banned. whatsmeow has already deleted the session row before this fires,
// so the client is inert and beginPairing will build a replacement. Only the whatsmeow session
// is gone; wa-messages.db is a separate database and keeps everything ingested so far.
func (a *app) onLoggedOut(e *events.LoggedOut) {
	a.mu.Lock()
	a.loggedOut = true
	a.lastDisconnect = time.Now()
	a.lastReason = "logged out — " + e.Reason.String()
	a.mu.Unlock()
	logf("❌  WhatsApp session invalidated (%s, on_connect=%v). INGESTION HAS STOPPED. "+
		"The %d messages already ingested are untouched — scan the QR at /qr.png to re-pair.",
		e.Reason, e.OnConnect, a.store.MessageCount())
	a.beginPairing(context.Background())
}

// onReconnectFailure runs on whatsmeow's own reconnect goroutine, which is the only place it
// is safe to touch AutoReconnectErrors — the event handlers run elsewhere. Capping the counter
// bounds the backoff (see maxReconnectBackoffSteps) so a bridge that regains the network comes
// back in minutes rather than hours, and logging here makes a previously silent retry loop
// visible. Returning true keeps whatsmeow retrying.
func (a *app) onReconnectFailure(err error) bool {
	c := a.client()
	if c == nil {
		return false
	}
	if c.AutoReconnectErrors > maxReconnectBackoffSteps {
		c.AutoReconnectErrors = maxReconnectBackoffSteps
	}
	a.noteDisconnect(fmt.Sprintf("reconnect attempt %d failed: %v", c.AutoReconnectErrors, err))
	return true
}

func (a *app) handleMessage(e *events.Message) {
	text := extractText(e.Message)
	if text == "" {
		return // media / voice / calls carry no text — the store stays honest
	}
	isGroup := e.Info.Chat.Server == types.GroupServer
	a.store.SaveMessage(Msg{
		ID:         e.Info.ID,
		ChatJID:    e.Info.Chat.String(),
		SenderJID:  e.Info.Sender.String(),
		SenderName: e.Info.PushName,
		ChatName:   a.chatName(e.Info.Chat, isGroup, e.Info.PushName, e.Info.IsFromMe),
		Content:    text,
		Timestamp:  e.Info.Timestamp.Unix(),
		IsFromMe:   e.Info.IsFromMe,
		IsGroup:    isGroup,
	})
}

func (a *app) handleHistorySync(e *events.HistorySync) {
	if e.Data == nil {
		return
	}
	saved := 0
	for _, conv := range e.Data.GetConversations() {
		chatJID := conv.GetID()
		jid, err := types.ParseJID(chatJID)
		if err != nil {
			continue
		}
		isGroup := jid.Server == types.GroupServer
		chatName := conv.GetName()
		for _, hm := range conv.GetMessages() {
			wm := hm.GetMessage()
			if wm == nil {
				continue
			}
			text := extractText(wm.GetMessage())
			if text == "" {
				continue
			}
			ts := wm.GetMessageTimestamp()
			if ts == 0 {
				continue
			}
			key := wm.GetKey()
			senderJID := key.GetParticipant()
			if senderJID == "" {
				senderJID = chatJID
			}
			a.store.SaveMessage(Msg{
				ID:         key.GetID(),
				ChatJID:    chatJID,
				SenderJID:  senderJID,
				SenderName: wm.GetPushName(),
				ChatName:   chatName,
				Content:    text,
				Timestamp:  int64(ts),
				IsFromMe:   key.GetFromMe(),
				IsGroup:    isGroup,
			})
			saved++
		}
	}
	if saved > 0 {
		fmt.Printf("history sync: stored %d messages (total %d)\n", saved, a.store.MessageCount())
	}
}

func extractText(m *waProto.Message) string {
	if m == nil {
		return ""
	}
	if c := m.GetConversation(); c != "" {
		return c
	}
	if e := m.GetExtendedTextMessage(); e != nil {
		return e.GetText()
	}
	return ""
}

// chatName resolves a display name for a chat: group name for groups, else the best contact
// name from the synced cache, falling back to the push name.
func (a *app) chatName(chat types.JID, isGroup bool, pushName string, isFromMe bool) string {
	if isGroup {
		mu := &a.mu
		mu.RLock()
		c := a.wa
		mu.RUnlock()
		if c != nil {
			if info, err := c.GetGroupInfo(context.Background(), chat); err == nil && info.Name != "" {
				return info.Name
			}
		}
		return ""
	}
	// 1:1 — prefer the synced contact name for this JID.
	for _, ct := range a.store.GetContacts() {
		if ct.JID == chat.ToNonAD().String() {
			if ct.FullName != "" {
				return ct.FullName
			}
			if ct.PushName != "" {
				return ct.PushName
			}
			if ct.FirstName != "" {
				return ct.FirstName
			}
		}
	}
	if !isFromMe {
		return pushName
	}
	return ""
}

// syncContacts pulls WhatsApp's address book into contact_names, mirroring each name onto
// both the phone-JID and LID identities so either address resolves.
func (a *app) syncContacts(ctx context.Context) {
	c := a.client()
	if c == nil || c.Store == nil || c.Store.Contacts == nil {
		return
	}
	// GetAllContacts reads the LOCAL whatsmeow store, not the network, so it succeeds and
	// reports a healthy-looking count even when the socket is dead. That is exactly what
	// happened for five weeks: "contact sync: 16314 contacts" every 6h while nothing was
	// being ingested. Report the truth instead of a number that means nothing here.
	if !c.IsConnected() || !c.IsLoggedIn() {
		logf("⚠️  contact sync skipped — not connected, so nothing is being ingested")
		return
	}
	contacts, err := c.Store.Contacts.GetAllContacts(ctx)
	if err != nil {
		logf("⚠️  contact sync failed: %v", err)
		return
	}
	n := 0
	for jid, info := range contacts {
		primary := jid.ToNonAD().String()
		a.store.SaveContact(Contact{JID: primary, FullName: info.FullName, FirstName: info.FirstName, PushName: info.PushName})
		n++
		// Mirror onto the other identity (phone <-> LID) so LID-addressed inbound resolves.
		if other, ok := a.otherIdentity(ctx, jid); ok {
			a.store.SaveContact(Contact{JID: other.ToNonAD().String(), FullName: info.FullName, FirstName: info.FirstName, PushName: info.PushName})
		}
	}
	if n > 0 {
		logf("contact sync: %d contacts", n)
	}
}

func (a *app) otherIdentity(ctx context.Context, jid types.JID) (types.JID, bool) {
	c := a.wa
	if c == nil || c.Store == nil || c.Store.LIDs == nil {
		return types.EmptyJID, false
	}
	switch jid.Server {
	case types.DefaultUserServer:
		if out, err := c.Store.LIDs.GetLIDForPN(ctx, jid); err == nil && !out.IsEmpty() {
			return out, true
		}
	case types.HiddenUserServer:
		if out, err := c.Store.LIDs.GetPNForLID(ctx, jid); err == nil && !out.IsEmpty() {
			return out, true
		}
	}
	return types.EmptyJID, false
}

// ── HTTP handlers ──

func (a *app) handleStatus(w http.ResponseWriter, r *http.Request) {
	a.mu.RLock()
	c := a.wa
	lastConnected, lastDisconnect := a.lastConnected, a.lastDisconnect
	reason, loggedOut, pairing := a.lastReason, a.loggedOut, a.pairing
	a.mu.RUnlock()
	paired := c != nil && c.Store != nil && c.Store.ID != nil
	connected := c != nil && c.IsConnected() && c.IsLoggedIn()
	// The paired account's own JID, in the canonical <number>@s.whatsapp.net form used in chats —
	// so Alfred can address the user's self-chat (@schedule prompts).
	selfJID := ""
	if paired {
		selfJID = c.Store.ID.User + "@s.whatsapp.net"
	}
	out := map[string]any{
		"paired":    paired,
		"connected": connected,
		// paired says a session exists, connected says the socket is up — only the second
		// one means messages are arriving. Callers that route on `paired` alone will sit on
		// a dead bridge, which is how this went unnoticed for five weeks.
		"logged_out": loggedOut,
		"pairing":    pairing,
		"messages":   a.store.MessageCount(),
		// newest_message is the signal that exposes a stalled bridge at a glance: the count
		// stays high and paired stays true while the newest message gets older and older.
		"newest_message": a.store.NewestMessageTimestamp(),
		"reason":         reason,
		"jid":            selfJID,
	}
	if !lastConnected.IsZero() {
		out["last_connected"] = lastConnected.UTC().Format(time.RFC3339)
	}
	if !lastDisconnect.IsZero() {
		out["last_disconnect"] = lastDisconnect.UTC().Format(time.RFC3339)
	}
	writeJSON(w, out)
}

// handleRepair clears a session that can no longer be used and offers a fresh QR.
//
// This exists for the state that caused the five-week outage and had no way out: `paired:
// true` from the session on disk, `connected: false`, and no LoggedOut event ever delivered —
// so pairLoop, which only runs while Store.ID is nil, could never offer a code, and /qr
// returned an empty string forever. The only recovery was deleting whatsmeow.db by hand.
//
// It deletes ONLY the whatsmeow session. The ingested messages live in wa-messages.db, a
// separate database this never touches, and the response reports the count that was kept.
// Refuses to disturb a healthy bridge unless ?force=1.
func (a *app) handleRepair(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	a.mu.RLock()
	c := a.wa
	pairing := a.pairing
	a.mu.RUnlock()
	if c == nil {
		writeJSON(w, map[string]any{"ok": false, "error": "no whatsapp client"})
		return
	}
	if pairing {
		writeJSON(w, map[string]any{"ok": true, "status": "already pairing — scan the QR at /qr.png"})
		return
	}
	if c.IsConnected() && c.IsLoggedIn() && r.URL.Query().Get("force") != "1" {
		writeJSON(w, map[string]any{"ok": false,
			"error": "bridge is connected and logged in — pass ?force=1 to re-pair anyway"})
		return
	}

	kept := a.store.MessageCount()
	c.Disconnect()
	if c.Store != nil && c.Store.ID != nil && !c.Store.Deleted {
		if err := c.Store.Delete(r.Context()); err != nil {
			logf("⚠️  could not clear the session for re-pairing: %v", err)
			writeJSON(w, map[string]any{"ok": false, "error": err.Error()})
			return
		}
	}
	logf("🔁  session cleared on request — pairing again (%d ingested messages kept)", kept)
	go a.beginPairing(context.Background())
	writeJSON(w, map[string]any{
		"ok":            true,
		"status":        "session cleared — scan the QR at /qr.png",
		"messages_kept": kept,
	})
}

func (a *app) handleQR(w http.ResponseWriter, r *http.Request) {
	a.mu.RLock()
	code := a.qr
	a.mu.RUnlock()
	writeJSON(w, map[string]any{"code": code})
}

// handleQRPNG renders the current pairing code as a scannable QR PNG so Alfred's own UI can
// show it (no external QR library needed in the browser). 404 once paired (no code).
func (a *app) handleQRPNG(w http.ResponseWriter, r *http.Request) {
	a.mu.RLock()
	code := a.qr
	a.mu.RUnlock()
	if code == "" {
		http.Error(w, "no pairing code (already paired?)", http.StatusNotFound)
		return
	}
	img, err := qr.Encode(code, qr.M)
	if err != nil {
		http.Error(w, "qr encode failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(img.PNG())
}

func (a *app) handleSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		JID     string `json:"jid"`
		Message string `json:"message"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.JID == "" || body.Message == "" {
		writeJSON(w, map[string]any{"ok": false, "error": "jid and message required"})
		return
	}
	jid, err := types.ParseJID(body.JID)
	if err != nil {
		writeJSON(w, map[string]any{"ok": false, "error": "invalid jid: " + body.JID})
		return
	}
	a.mu.RLock()
	c := a.wa
	a.mu.RUnlock()
	if c == nil || !c.IsLoggedIn() {
		writeJSON(w, map[string]any{"ok": false, "error": "not paired — run wa-bridge and scan the QR"})
		return
	}
	resp, err := c.SendMessage(r.Context(), jid, &waProto.Message{Conversation: proto.String(body.Message)})
	if err != nil {
		writeJSON(w, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, map[string]any{"ok": true, "id": resp.ID})
}

func (a *app) handleMessages(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	since := int64(0)
	if v := q.Get("since"); v != "" {
		since, _ = strconv.ParseInt(v, 10, 64)
	}
	limit := 5000
	if v := q.Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			limit = n
		}
	}
	writeJSON(w, a.store.GetMessages(since, q.Get("chat"), limit))
}

func (a *app) handleContacts(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, a.store.GetContacts())
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
