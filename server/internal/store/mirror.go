package store

import "encoding/json"

// The PC mirror: what the server pulled from Pocket Casts on the user's behalf.
// Stored as whole documents per kind — the mirror is a snapshot, not a change log,
// and the query API only ever reads the latest.

func (s *Store) SaveMirror(userID int64, kind string, payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	_, err = s.db.Exec(`
INSERT INTO mirror (user_id, kind, payload, fetched_at) VALUES (?, ?, ?, datetime('now'))
ON CONFLICT(user_id, kind) DO UPDATE SET payload = excluded.payload, fetched_at = excluded.fetched_at`,
		userID, kind, string(data))
	return err
}

// Mirror returns the stored document and when it was fetched ("" if never).
func (s *Store) Mirror(userID int64, kind string) (json.RawMessage, string, error) {
	var payload, fetchedAt string
	err := s.db.QueryRow(`SELECT payload, fetched_at FROM mirror WHERE user_id = ? AND kind = ?`, userID, kind).
		Scan(&payload, &fetchedAt)
	if err != nil {
		return nil, "", err
	}
	return json.RawMessage(payload), fetchedAt, nil
}
