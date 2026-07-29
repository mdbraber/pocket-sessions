package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
)

// The wire shapes mirror the iOS client's Codable payloads: session/preset
// payloads are opaque JSON blobs keyed by uuid — the server never interprets
// them, it only merges records. Timestamps are client-clock unix milliseconds.

type Record struct {
	UUID      string          `json:"uuid"`
	UpdatedAt int64           `json:"updatedAt"`
	Payload   json.RawMessage `json:"payload,omitempty"`
	Deleted   bool            `json:"deleted,omitempty"`
}

type SeenLedger struct {
	SeenAt   map[string]int64 `json:"seenAt"`
	UnseenAt map[string]int64 `json:"unseenAt"`
}

// PlaybackPointer is the "what's playing where" document — an opaque client
// blob (session pointer + current episode + originating device), single row
// per user, last-writer-wins. Powers the opt-in follow-playback feature.
type PlaybackPointer struct {
	UpdatedAt int64           `json:"updatedAt"`
	Payload   json.RawMessage `json:"payload"`
}

// NudgeInfo tells pollers that PC-side data moved: seq increments on every
// nudge, deviceId names the originator so devices can ignore their own.
type NudgeInfo struct {
	Seq      int64  `json:"seq"`
	DeviceID string `json:"deviceId,omitempty"`
}

type Changes struct {
	Cursor   int64            `json:"cursor"`
	Sessions []Record         `json:"sessions,omitempty"`
	Presets  []Record         `json:"presets,omitempty"`
	Offered  map[string]int64 `json:"offered,omitempty"`
	Ledger   *SeenLedger      `json:"seenLedger,omitempty"`
	Playback *PlaybackPointer `json:"playback,omitempty"`
	Nudge    *NudgeInfo       `json:"nudge,omitempty"`
}

// BumpNudge records "device X just put fresh data on PC" — pollers compare seq
// and re-sync with PC when it advances (push delivery alone is best-effort).
func (s *Store) BumpNudge(userID int64, deviceID string) error {
	_, err := s.db.Exec(`UPDATE meta SET nudge_seq = nudge_seq + 1, nudge_device = ? WHERE user_id = ?`, deviceID, userID)
	return err
}

// ApplyChanges merges a client batch and returns the new cursor. Merge rules
// mirror SessionCloudSync exactly:
//   - sessions / presets: last-writer-wins per record on updatedAt
//   - offeredThrough: monotonic max per podcast (a lower date would re-offer
//     episodes another device already triaged away)
//   - seen-ledger: union-newest of both maps; entries never die by omission
//     from one side, only by both sides having pruned them
func (s *Store) ApplyChanges(userID int64, in Changes) (int64, bool, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return 0, false, err
	}
	defer tx.Rollback()

	cursor, err := nextCursor(tx, userID)
	if err != nil {
		return 0, false, err
	}
	changed := false

	for _, table := range []struct {
		name string
		recs []Record
	}{{"sessions", in.Sessions}, {"presets", in.Presets}} {
		for _, r := range table.recs {
			res, err := tx.Exec(fmt.Sprintf(`
INSERT INTO %s (user_id, uuid, payload, updated_at, deleted, cursor)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(user_id, uuid) DO UPDATE
SET payload = excluded.payload, updated_at = excluded.updated_at,
    deleted = excluded.deleted, cursor = excluded.cursor
WHERE excluded.updated_at >= %s.updated_at`, table.name, table.name),
				userID, r.UUID, string(r.Payload), r.UpdatedAt, r.Deleted, cursor)
			if err != nil {
				return 0, false, err
			}
			if n, _ := res.RowsAffected(); n > 0 {
				changed = true
			}
		}
	}

	for podcast, date := range in.Offered {
		res, err := tx.Exec(`
INSERT INTO offered_through (user_id, podcast_uuid, date, cursor) VALUES (?, ?, ?, ?)
ON CONFLICT(user_id, podcast_uuid) DO UPDATE
SET date = excluded.date, cursor = excluded.cursor
WHERE excluded.date > offered_through.date`, userID, podcast, date, cursor)
		if err != nil {
			return 0, false, err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			changed = true
		}
	}

	if in.Playback != nil {
		res, err := tx.Exec(`
INSERT INTO active_playback (user_id, payload, updated_at, cursor) VALUES (?, ?, ?, ?)
ON CONFLICT(user_id) DO UPDATE
SET payload = excluded.payload, updated_at = excluded.updated_at, cursor = excluded.cursor
WHERE excluded.updated_at > active_playback.updated_at`,
			userID, string(in.Playback.Payload), in.Playback.UpdatedAt, cursor)
		if err != nil {
			return 0, false, err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			changed = true
		}
	}

	if in.Ledger != nil {
		merged, didChange, err := mergeLedger(tx, userID, *in.Ledger)
		if err != nil {
			return 0, false, err
		}
		if didChange {
			payload, err := json.Marshal(merged)
			if err != nil {
				return 0, false, err
			}
			if _, err := tx.Exec(`
INSERT INTO seen_ledger (user_id, payload, cursor) VALUES (?, ?, ?)
ON CONFLICT(user_id) DO UPDATE SET payload = excluded.payload, cursor = excluded.cursor`,
				userID, string(payload), cursor); err != nil {
				return 0, false, err
			}
			changed = true
		}
	}

	if changed {
		if _, err := tx.Exec(`UPDATE meta SET cursor = ? WHERE user_id = ?`, cursor, userID); err != nil {
			return 0, false, err
		}
	} else {
		// Nothing merged (all stale) — report the existing cursor, don't burn one.
		if err := tx.QueryRow(`SELECT cursor FROM meta WHERE user_id = ?`, userID).Scan(&cursor); err != nil {
			return 0, false, err
		}
	}
	return cursor, changed, tx.Commit()
}

// ChangesSince returns deltas for sessions/presets (records with cursor >
// since) and, when anything moved, full snapshots of the small offered/ledger
// documents — the same grain the CloudKit engine used.
func (s *Store) ChangesSince(userID, since int64) (Changes, error) {
	out := Changes{}
	var nudge NudgeInfo
	err := s.db.QueryRow(`SELECT COALESCE(cursor, 0), COALESCE(nudge_seq, 0), COALESCE(nudge_device, '') FROM meta WHERE user_id = ?`, userID).
		Scan(&out.Cursor, &nudge.Seq, &nudge.DeviceID)
	if err != nil && err != sql.ErrNoRows {
		return out, err
	}
	// The nudge rides EVERY response, cursor movement or not — it's how a
	// foreground poller learns that PC-side data (progress, queue) moved.
	if nudge.Seq > 0 {
		out.Nudge = &nudge
	}
	if out.Cursor <= since {
		out.Cursor = maxInt64(out.Cursor, since)
		return out, nil // nothing new in session data
	}

	for _, q := range []struct {
		table string
		dest  *[]Record
	}{{"sessions", &out.Sessions}, {"presets", &out.Presets}} {
		rows, err := s.db.Query(fmt.Sprintf(
			`SELECT uuid, updated_at, payload, deleted FROM %s WHERE user_id = ? AND cursor > ?`, q.table), userID, since)
		if err != nil {
			return out, err
		}
		for rows.Next() {
			var r Record
			var payload string
			if err := rows.Scan(&r.UUID, &r.UpdatedAt, &payload, &r.Deleted); err != nil {
				rows.Close()
				return out, err
			}
			r.Payload = json.RawMessage(payload)
			*q.dest = append(*q.dest, r)
		}
		rows.Close()
	}

	offered := map[string]int64{}
	rows, err := s.db.Query(`SELECT podcast_uuid, date FROM offered_through WHERE user_id = ? AND cursor > ?`, userID, since)
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var uuid string
		var date int64
		if err := rows.Scan(&uuid, &date); err != nil {
			rows.Close()
			return out, err
		}
		offered[uuid] = date
	}
	rows.Close()
	if len(offered) > 0 {
		out.Offered = offered
	}

	var ledgerPayload string
	var ledgerCursor int64
	err = s.db.QueryRow(`SELECT payload, cursor FROM seen_ledger WHERE user_id = ?`, userID).Scan(&ledgerPayload, &ledgerCursor)
	if err == nil && ledgerCursor > since {
		var ledger SeenLedger
		if err := json.Unmarshal([]byte(ledgerPayload), &ledger); err == nil {
			out.Ledger = &ledger
		}
	} else if err != nil && err != sql.ErrNoRows {
		return out, err
	}

	var playbackPayload string
	var playback PlaybackPointer
	var playbackCursor int64
	err = s.db.QueryRow(`SELECT payload, updated_at, cursor FROM active_playback WHERE user_id = ?`, userID).
		Scan(&playbackPayload, &playback.UpdatedAt, &playbackCursor)
	if err == nil && playbackCursor > since {
		playback.Payload = json.RawMessage(playbackPayload)
		out.Playback = &playback
	} else if err != nil && err != sql.ErrNoRows {
		return out, err
	}
	return out, nil
}

func mergeLedger(tx *sql.Tx, userID int64, incoming SeenLedger) (SeenLedger, bool, error) {
	current := SeenLedger{SeenAt: map[string]int64{}, UnseenAt: map[string]int64{}}
	var payload string
	err := tx.QueryRow(`SELECT payload FROM seen_ledger WHERE user_id = ?`, userID).Scan(&payload)
	if err != nil && err != sql.ErrNoRows {
		return current, false, err
	}
	if err == nil {
		_ = json.Unmarshal([]byte(payload), &current)
	}
	merged := SeenLedger{
		SeenAt:   unionNewest(current.SeenAt, incoming.SeenAt),
		UnseenAt: unionNewest(current.UnseenAt, incoming.UnseenAt),
	}
	changed := !equalMaps(merged.SeenAt, current.SeenAt) || !equalMaps(merged.UnseenAt, current.UnseenAt)
	return merged, changed, nil
}

func unionNewest(a, b map[string]int64) map[string]int64 {
	out := make(map[string]int64, len(a)+len(b))
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		if cur, ok := out[k]; !ok || v > cur {
			out[k] = v
		}
	}
	return out
}

func equalMaps(a, b map[string]int64) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

func nextCursor(tx *sql.Tx, userID int64) (int64, error) {
	var cur int64
	err := tx.QueryRow(`SELECT COALESCE(cursor, 0) FROM meta WHERE user_id = ?`, userID).Scan(&cur)
	if err == sql.ErrNoRows {
		cur = 0
		err = nil
	}
	return cur + 1, err
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// RegisterDevice upserts a device's push registration.
func (s *Store) RegisterDevice(userID int64, deviceID, apnsToken, apnsEnv string) error {
	_, err := s.db.Exec(`
INSERT INTO devices (user_id, device_id, apns_token, apns_env, last_seen)
VALUES (?, ?, ?, ?, datetime('now'))
ON CONFLICT(user_id, device_id) DO UPDATE
SET apns_token = excluded.apns_token, apns_env = excluded.apns_env, last_seen = excluded.last_seen`,
		userID, deviceID, apnsToken, apnsEnv)
	return err
}

type Device struct {
	DeviceID  string
	APNSToken string
	APNSEnv   string
}

// DevicesExcept lists the user's registered devices minus the originator —
// the push fan-out set.
func (s *Store) DevicesExcept(userID int64, exceptDeviceID string) ([]Device, error) {
	rows, err := s.db.Query(`SELECT device_id, apns_token, apns_env FROM devices WHERE user_id = ? AND device_id != ?`,
		userID, exceptDeviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		var d Device
		if err := rows.Scan(&d.DeviceID, &d.APNSToken, &d.APNSEnv); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}
