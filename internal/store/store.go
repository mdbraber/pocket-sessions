// Package store owns the SQLite database. Schema is multi-user from day one
// (user_id scoping everywhere) even though there is one user in practice.
package store

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"

	_ "modernc.org/sqlite" // pure-Go driver: no cgo, trivial cross-compile for the VPS
)

type Store struct {
	db *sql.DB
}

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)")
	if err != nil {
		return nil, err
	}
	// SQLite + this driver want a single writer; the busy timeout covers readers.
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS users (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS tokens (
    token      TEXT PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    label      TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS devices (
    device_id  TEXT NOT NULL,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    apns_token TEXT NOT NULL DEFAULT '',
    apns_env   TEXT NOT NULL DEFAULT 'sandbox',
    last_seen  TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (user_id, device_id)
);
CREATE TABLE IF NOT EXISTS fork_sessions (
    user_id    INTEGER NOT NULL,
    uuid       TEXT NOT NULL,
    payload    TEXT NOT NULL,
    updated_at INTEGER NOT NULL, -- client clock, unix ms; LWW per record
    deleted    INTEGER NOT NULL DEFAULT 0,
    cursor     INTEGER NOT NULL, -- server change cursor for delta sync
    PRIMARY KEY (user_id, uuid)
);
CREATE TABLE IF NOT EXISTS fork_presets (
    user_id    INTEGER NOT NULL,
    uuid       TEXT NOT NULL,
    payload    TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted    INTEGER NOT NULL DEFAULT 0,
    cursor     INTEGER NOT NULL,
    PRIMARY KEY (user_id, uuid)
);
CREATE TABLE IF NOT EXISTS fork_offered (
    user_id      INTEGER NOT NULL,
    podcast_uuid TEXT NOT NULL,
    date         INTEGER NOT NULL, -- unix ms; monotonic max, never regresses
    cursor       INTEGER NOT NULL,
    PRIMARY KEY (user_id, podcast_uuid)
);
CREATE TABLE IF NOT EXISTS fork_seen_ledger (
    user_id INTEGER PRIMARY KEY,
    payload TEXT NOT NULL, -- {"seenAt":{uuid:ms},"unseenAt":{uuid:ms}} union doc
    cursor  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS meta (
    user_id INTEGER PRIMARY KEY,
    cursor  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_sessions_cursor ON fork_sessions(user_id, cursor);
CREATE INDEX IF NOT EXISTS idx_presets_cursor  ON fork_presets(user_id, cursor);
`)
	return err
}

// EnsureBootstrapUser guarantees user 1 exists and, when a token is supplied,
// that it authenticates as them. Local dev with no PCC_AUTH_TOKEN runs open.
func (s *Store) EnsureBootstrapUser(token string) error {
	if _, err := s.db.Exec(`INSERT OR IGNORE INTO users(id, name) VALUES (1, 'owner')`); err != nil {
		return err
	}
	if _, err := s.db.Exec(`INSERT OR IGNORE INTO meta(user_id, cursor) VALUES (1, 0)`); err != nil {
		return err
	}
	if token != "" {
		if _, err := s.db.Exec(`INSERT OR IGNORE INTO tokens(token, user_id, label) VALUES (?, 1, 'bootstrap')`, token); err != nil {
			return err
		}
	}
	return nil
}

// UserForToken resolves a bearer token; ("", 0) means unauthenticated.
func (s *Store) UserForToken(token string) (int64, error) {
	var id int64
	err := s.db.QueryRow(`SELECT user_id FROM tokens WHERE token = ?`, token).Scan(&id)
	if err == sql.ErrNoRows {
		return 0, nil
	}
	return id, err
}

// HasTokens reports whether any token exists — when none do (fresh local dev
// database, no PCC_AUTH_TOKEN), the API runs open as user 1.
func (s *Store) HasTokens() (bool, error) {
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM tokens`).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
