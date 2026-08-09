// wa-bridge — a long-running WhatsApp I/O helper for Alfred, built on whatsmeow (the same
// library Commit uses). It wraps a whatsmeow client + a pure-Go SQLite session store and a
// local message/contact cache, and exposes a localhost HTTP API:
//
//	GET  /status              -> {"paired":bool,"connected":bool,"messages":int}
//	GET  /qr                  -> {"code":"..."} current pairing code (empty once paired)
//	POST /send  {jid,message} -> {"ok":bool,"id":"...","error":"..."}
//	GET  /messages?since=&chat=&limit=  -> [{id,chat_jid,sender_jid,sender_name,chat_name,content,timestamp,is_from_me,is_group}]
//	GET  /contacts            -> [{jid,full_name,first_name,push_name}]
//
// It ingests messages two ways: whatsmeow's link-time HistorySync (recent backfill) and
// live *events.Message (forward capture, inbound + outbound). Text-only, deduped by message
// ID. The recipient JID for sends comes straight from Alfred's commitment thread_id, which is
// already a WhatsApp JID. One-time pairing: run the binary, scan the QR from WhatsApp →
// Linked Devices.
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

type app struct {
	wa    *whatsmeow.Client
	store *Store
	qr    string
	mu    sync.RWMutex
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

	container, err := sqlstore.New(ctx, "sqlite",
		fmt.Sprintf("file:%s?_pragma=foreign_keys(1)", filepath.Join(dir, "whatsmeow.db")), waLog.Noop)
	if err != nil {
		panic(fmt.Sprintf("open session store: %v", err))
	}
	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		panic(fmt.Sprintf("get device: %v", err))
	}

	a := &app{wa: whatsmeow.NewClient(device, waLog.Noop), store: st}
	a.wa.AddEventHandler(a.handleEvent)

	if a.wa.Store.ID == nil {
		go a.pairLoop(ctx) // keeps a fresh QR available until scanned (survives timeouts)
	} else {
		if err := a.wa.Connect(); err != nil {
			panic(fmt.Sprintf("connect: %v", err))
		}
		fmt.Println("✓  WhatsApp connected (existing session).")
		go a.syncContacts(ctx)
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

// pairLoop keeps a scannable QR available: whatsmeow's QR channel times out after a few
// minutes, so on timeout we disconnect and request a fresh one. Exits once paired.
func (a *app) pairLoop(ctx context.Context) {
	for {
		if a.wa.Store.ID != nil {
			return
		}
		qrChan, err := a.wa.GetQRChannel(ctx)
		if err != nil {
			_ = a.wa.Connect()
			return
		}
		if err := a.wa.Connect(); err != nil {
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
				fmt.Println("\n📱  Scan in WhatsApp → Settings → Linked Devices → Link a Device:")
				qrterminal.GenerateHalfBlock(evt.Code, qrterminal.L, os.Stdout)
			case "success":
				a.mu.Lock()
				a.qr = ""
				a.mu.Unlock()
				fmt.Println("✓  Paired. Session saved.")
				go a.syncContacts(context.Background())
				paired = true
			default:
				fmt.Println("pairing event:", evt.Event) // timeout / error
			}
		}
		if paired || a.wa.Store.ID != nil {
			return
		}
		// Channel closed without success (timeout) — clear stale code, reset, retry.
		a.mu.Lock()
		a.qr = ""
		a.mu.Unlock()
		a.wa.Disconnect()
		time.Sleep(3 * time.Second)
	}
}

// ── event handling / ingestion ──

func (a *app) handleEvent(evt any) {
	switch e := evt.(type) {
	case *events.Message:
		a.handleMessage(e)
	case *events.HistorySync:
		go a.handleHistorySync(e)
	case *events.Connected:
		go a.syncContacts(context.Background())
	}
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
	a.mu.RLock()
	c := a.wa
	a.mu.RUnlock()
	if c == nil || c.Store == nil || c.Store.Contacts == nil {
		return
	}
	contacts, err := c.Store.Contacts.GetAllContacts(ctx)
	if err != nil {
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
		fmt.Printf("contact sync: %d contacts\n", n)
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
	a.mu.RUnlock()
	paired := c != nil && c.Store.ID != nil
	connected := c != nil && c.IsConnected() && c.IsLoggedIn()
	writeJSON(w, map[string]any{"paired": paired, "connected": connected, "messages": a.store.MessageCount()})
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
