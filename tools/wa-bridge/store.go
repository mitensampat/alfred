// store.go — the bridge's own message + contact cache (SQLite via pure-Go modernc driver).
// This is what Alfred's WhatsAppBridgeReader reads instead of the WhatsApp Desktop DB.
package main

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"sync"
	"time"
)

type Store struct {
	db *sql.DB
	mu sync.Mutex
}

// Msg mirrors the fields Alfred's Message model needs (text-only, same shape as the
// WhatsApp Desktop reader produced).
type Msg struct {
	ID         string `json:"id"`
	ChatJID    string `json:"chat_jid"`
	SenderJID  string `json:"sender_jid"`
	SenderName string `json:"sender_name"`
	ChatName   string `json:"chat_name"`
	Content    string `json:"content"`
	Timestamp  int64  `json:"timestamp"` // unix seconds
	IsFromMe   bool   `json:"is_from_me"`
	IsGroup    bool   `json:"is_group"`
}

type Contact struct {
	JID       string `json:"jid"`
	FullName  string `json:"full_name"`
	FirstName string `json:"first_name"`
	PushName  string `json:"push_name"`
}

func openStore(dir string) (*Store, error) {
	path := filepath.Join(dir, "wa-messages.db")
	db, err := sql.Open("sqlite",
		fmt.Sprintf("file:%s?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)", path))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // modernc + WAL: single writer is simplest & safe
	schema := `
	CREATE TABLE IF NOT EXISTS messages (
		id          TEXT PRIMARY KEY,
		chat_jid    TEXT NOT NULL,
		sender_jid  TEXT NOT NULL,
		sender_name TEXT NOT NULL DEFAULT '',
		chat_name   TEXT NOT NULL DEFAULT '',
		content     TEXT NOT NULL,
		timestamp   INTEGER NOT NULL,
		is_from_me  INTEGER NOT NULL DEFAULT 0,
		is_group    INTEGER NOT NULL DEFAULT 0
	);
	CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_jid);
	CREATE INDEX IF NOT EXISTS idx_messages_ts   ON messages(timestamp);
	CREATE TABLE IF NOT EXISTS contact_names (
		jid        TEXT PRIMARY KEY,
		full_name  TEXT NOT NULL DEFAULT '',
		first_name TEXT NOT NULL DEFAULT '',
		push_name  TEXT NOT NULL DEFAULT '',
		synced_at  INTEGER
	);`
	if _, err := db.Exec(schema); err != nil {
		return nil, err
	}
	return &Store{db: db}, nil
}

// SaveMessage upserts by WhatsApp message ID — history sync + live capture dedupe naturally.
func (s *Store) SaveMessage(m Msg) {
	if m.ID == "" || m.Content == "" || m.Timestamp == 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.db.Exec(`
		INSERT INTO messages (id,chat_jid,sender_jid,sender_name,chat_name,content,timestamp,is_from_me,is_group)
		VALUES (?,?,?,?,?,?,?,?,?)
		ON CONFLICT(id) DO UPDATE SET
			chat_name=CASE WHEN excluded.chat_name<>'' THEN excluded.chat_name ELSE chat_name END,
			sender_name=CASE WHEN excluded.sender_name<>'' THEN excluded.sender_name ELSE sender_name END`,
		m.ID, m.ChatJID, m.SenderJID, m.SenderName, m.ChatName, m.Content, m.Timestamp, b2i(m.IsFromMe), b2i(m.IsGroup))
}

func (s *Store) GetMessages(since int64, chat string, limit int) []Msg {
	s.mu.Lock()
	defer s.mu.Unlock()
	q := `SELECT id,chat_jid,sender_jid,sender_name,chat_name,content,timestamp,is_from_me,is_group
	      FROM messages WHERE timestamp >= ?`
	args := []any{since}
	if chat != "" {
		q += " AND chat_jid = ?"
		args = append(args, chat)
	}
	q += " ORDER BY timestamp DESC"
	if limit > 0 {
		q += fmt.Sprintf(" LIMIT %d", limit)
	}
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := []Msg{}
	for rows.Next() {
		var m Msg
		var fromMe, grp int
		if err := rows.Scan(&m.ID, &m.ChatJID, &m.SenderJID, &m.SenderName, &m.ChatName,
			&m.Content, &m.Timestamp, &fromMe, &grp); err != nil {
			continue
		}
		m.IsFromMe = fromMe == 1
		m.IsGroup = grp == 1
		out = append(out, m)
	}
	return out
}

func (s *Store) MessageCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	var n int
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&n)
	return n
}

func (s *Store) SaveContact(c Contact) {
	if c.JID == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.db.Exec(`
		INSERT INTO contact_names (jid,full_name,first_name,push_name,synced_at)
		VALUES (?,?,?,?,?)
		ON CONFLICT(jid) DO UPDATE SET
			full_name=excluded.full_name, first_name=excluded.first_name,
			push_name=excluded.push_name, synced_at=excluded.synced_at`,
		c.JID, c.FullName, c.FirstName, c.PushName, time.Now().Unix())
}

func (s *Store) GetContacts() []Contact {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(`SELECT jid,full_name,first_name,push_name FROM contact_names`)
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := []Contact{}
	for rows.Next() {
		var c Contact
		if err := rows.Scan(&c.JID, &c.FullName, &c.FirstName, &c.PushName); err != nil {
			continue
		}
		out = append(out, c)
	}
	return out
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}
