package store

import (
	"database/sql"
	"time"
)

// The hook delivery queue. The progress watcher writes each event here in the
// same transaction that advances its baseline; a dispatcher delivers them and
// deletes each on success, retrying failures with backoff. Delivery is
// at-least-once — receivers are idempotent by contract.

type OutboxEvent struct {
	ID          int64
	UserID      int64
	EpisodeUUID string
	Payload     []byte // hooks.Event as JSON
	Attempts    int
	NextAttempt int64 // unix seconds
}

func enqueueHookEvents(tx *sql.Tx, userID int64, events []OutboxEvent) error {
	now := time.Now().Unix()
	for _, e := range events {
		if _, err := tx.Exec(`
INSERT INTO hook_outbox (user_id, episode_uuid, payload, next_attempt_at, created_at)
VALUES (?, ?, ?, ?, ?)`, userID, e.EpisodeUUID, string(e.Payload), now, now); err != nil {
			return err
		}
	}
	return nil
}

// EnqueueHookEvents queues events outside a poll (the replay sweep).
func (s *Store) EnqueueHookEvents(userID int64, events []OutboxEvent) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := enqueueHookEvents(tx, userID, events); err != nil {
		return err
	}
	return tx.Commit()
}

// PendingHookEvents returns queued events oldest first, due or not — the
// dispatcher needs the not-yet-due ones too, to hold back later events for
// the same episode and keep per-episode order.
func (s *Store) PendingHookEvents(limit int) ([]OutboxEvent, error) {
	rows, err := s.db.Query(`
SELECT id, user_id, episode_uuid, payload, attempts, next_attempt_at
FROM hook_outbox ORDER BY id LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []OutboxEvent
	for rows.Next() {
		var e OutboxEvent
		var payload string
		if err := rows.Scan(&e.ID, &e.UserID, &e.EpisodeUUID, &payload, &e.Attempts, &e.NextAttempt); err != nil {
			return nil, err
		}
		e.Payload = []byte(payload)
		out = append(out, e)
	}
	return out, rows.Err()
}

// DeleteHookEvent removes a delivered (or abandoned) event.
func (s *Store) DeleteHookEvent(id int64) error {
	_, err := s.db.Exec(`DELETE FROM hook_outbox WHERE id = ?`, id)
	return err
}

// RescheduleHookEvent records a failed attempt.
func (s *Store) RescheduleHookEvent(id int64, attempts int, next time.Time, lastErr string) error {
	_, err := s.db.Exec(`
UPDATE hook_outbox SET attempts = ?, next_attempt_at = ?, last_error = ? WHERE id = ?`,
		attempts, next.Unix(), lastErr, id)
	return err
}
