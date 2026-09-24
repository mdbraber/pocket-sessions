package store

import (
	"github.com/mdbraber/pocket-sessions-server/internal/pc"
)

// The Pocket Casts replica: every sync record the account has ever shown us,
// raw bytes plus indexed columns, and a listening-history ledger that never
// truncates (PC's own /history/sync caps at 100 entries; this one only grows).
//
// Merge semantics mirror the watcher's: PC omits fields it has nothing new to
// say about, so parsed columns merge field-wise, and the raw column
// *concatenates* incoming bytes — protobuf wire concatenation IS field-wise
// message merge, so the stored blob stays a valid, complete SyncUserEpisode.
// A cap keeps hot episodes from growing unboundedly: past 8KB the blob resets
// to the newest record (the merged columns preserve state regardless).

const rawMergeCap = 8 << 10

// UpsertReplicaEpisodes merges episode records into the replica.
func (s *Store) UpsertReplicaEpisodes(userID int64, source string, episodes []pc.EpisodeProgress) error {
	if len(episodes) == 0 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, e := range episodes {
		if e.EpisodeUUID == "" {
			continue
		}
		var (
			playedUpTo, status, duration, archived, starred int64
			raw                                             []byte
		)
		err := tx.QueryRow(`
SELECT played_up_to, playing_status, duration, archived, starred, raw
FROM pc_replica WHERE user_id = ? AND kind = 'episode' AND uuid = ?`,
			userID, e.EpisodeUUID).Scan(&playedUpTo, &status, &duration, &archived, &starred, &raw)
		known := err == nil

		merged := func(incoming, previous int64) int64 {
			if incoming == 0 {
				return previous
			}
			return incoming
		}
		presence := func(incoming, previous int64) int64 {
			if incoming < 0 {
				return previous
			}
			return incoming
		}
		if e.HasPlayedUpTo {
			playedUpTo = e.PlayedUpTo
		} else {
			playedUpTo = merged(e.PlayedUpTo, playedUpTo)
		}
		status = merged(e.PlayingStatus, status)
		duration = merged(e.Duration, duration)
		archived = presence(e.Archived, archived)
		starred = presence(e.Starred, starred)

		switch {
		case len(e.Raw) == 0:
			// Column-only update (e.g. the flat per-podcast sweep) — keep
			// whatever SyncUserEpisode bytes we already hold.
		case known && len(raw)+len(e.Raw) <= rawMergeCap:
			raw = append(raw, e.Raw...)
		default:
			raw = e.Raw
		}
		if raw == nil {
			raw = []byte{}
		}

		podcastUUID := e.PodcastUUID
		if _, err := tx.Exec(`
INSERT INTO pc_replica (user_id, kind, uuid, podcast_uuid, played_up_to, playing_status, duration, archived, starred, raw, source, updated_at)
VALUES (?, 'episode', ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
ON CONFLICT(user_id, kind, uuid) DO UPDATE SET
  podcast_uuid = CASE WHEN excluded.podcast_uuid != '' THEN excluded.podcast_uuid ELSE pc_replica.podcast_uuid END,
  played_up_to = excluded.played_up_to, playing_status = excluded.playing_status,
  duration = excluded.duration, archived = excluded.archived, starred = excluded.starred,
  raw = excluded.raw, source = excluded.source, updated_at = excluded.updated_at`,
			userID, e.EpisodeUUID, podcastUUID, playedUpTo, status, duration, archived, starred, raw, source); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// UpsertReplicaRecords stores non-episode sync records (podcast, playlist,
// folder, bookmark, device) raw. Latest write wins; these records arrive
// whole, not field-sparse.
func (s *Store) UpsertReplicaRecords(userID int64, source string, records []pc.RawRecord) error {
	if len(records) == 0 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, r := range records {
		if r.UUID == "" || r.Kind == "" {
			continue
		}
		if _, err := tx.Exec(`
INSERT INTO pc_replica (user_id, kind, uuid, raw, source, updated_at)
VALUES (?, ?, ?, ?, ?, datetime('now'))
ON CONFLICT(user_id, kind, uuid) DO UPDATE SET
  raw = excluded.raw, source = excluded.source, updated_at = excluded.updated_at`,
			userID, r.Kind, r.UUID, r.Raw, source); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// UpsertHistoryLedger accumulates listening-history entries, so the ledger
// outgrows PC's 100-entry window over time. Entries only leave it when the
// user removes that one entry (action delete); "clear all" is ignored, since
// keeping history PC no longer serves is the ledger's purpose.
func (s *Store) UpsertHistoryLedger(userID int64, entries []pc.HistoryEntry) error {
	if len(entries) == 0 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, h := range entries {
		if h.EpisodeUUID == "" || h.Action == pc.HistoryActionClearAll {
			continue
		}
		if h.Action == pc.HistoryActionDelete {
			if _, err := tx.Exec(`DELETE FROM pc_history_ledger WHERE user_id = ? AND episode_uuid = ?`,
				userID, h.EpisodeUUID); err != nil {
				return err
			}
			continue
		}
		if _, err := tx.Exec(`
INSERT INTO pc_history_ledger (user_id, episode_uuid, podcast_uuid, title, url, modified_at)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(user_id, episode_uuid) DO UPDATE SET
  podcast_uuid = CASE WHEN excluded.podcast_uuid != '' THEN excluded.podcast_uuid ELSE pc_history_ledger.podcast_uuid END,
  title = CASE WHEN excluded.title != '' THEN excluded.title ELSE pc_history_ledger.title END,
  url = CASE WHEN excluded.url != '' THEN excluded.url ELSE pc_history_ledger.url END,
  modified_at = MAX(excluded.modified_at, pc_history_ledger.modified_at)`,
			userID, h.EpisodeUUID, h.PodcastUUID, h.Title, h.URL, h.ModifiedAt); err != nil {
			return err
		}
	}
	return tx.Commit()
}

type ReplicaStatus struct {
	Episodes      int64 `json:"episodes"`
	Played        int64 `json:"played"`
	Archived      int64 `json:"archived"`
	OtherRecords  int64 `json:"otherRecords"`
	LedgerEntries int64 `json:"ledgerEntries"`
}

func (s *Store) ReplicaStatus(userID int64) (ReplicaStatus, error) {
	var st ReplicaStatus
	row := s.db.QueryRow(`
SELECT
  COUNT(*) FILTER (WHERE kind = 'episode'),
  COUNT(*) FILTER (WHERE kind = 'episode' AND playing_status = 3),
  COUNT(*) FILTER (WHERE kind = 'episode' AND archived = 1),
  COUNT(*) FILTER (WHERE kind != 'episode')
FROM pc_replica WHERE user_id = ?`, userID)
	if err := row.Scan(&st.Episodes, &st.Played, &st.Archived, &st.OtherRecords); err != nil {
		return st, err
	}
	err := s.db.QueryRow(`SELECT COUNT(*) FROM pc_history_ledger WHERE user_id = ?`, userID).Scan(&st.LedgerEntries)
	return st, err
}

type LedgerEntry struct {
	EpisodeUUID string `json:"episodeUuid"`
	PodcastUUID string `json:"podcastUuid"`
	Title       string `json:"title,omitempty"`
	URL         string `json:"url,omitempty"`
	ModifiedAt  int64  `json:"modifiedAt"`
}

// HistoryLedger returns the accumulated history, newest first.
func (s *Store) HistoryLedger(userID int64, limit int) ([]LedgerEntry, error) {
	if limit <= 0 || limit > 10000 {
		limit = 1000
	}
	rows, err := s.db.Query(`
SELECT episode_uuid, podcast_uuid, title, url, modified_at
FROM pc_history_ledger WHERE user_id = ? ORDER BY modified_at DESC LIMIT ?`, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LedgerEntry
	for rows.Next() {
		var e LedgerEntry
		if err := rows.Scan(&e.EpisodeUUID, &e.PodcastUUID, &e.Title, &e.URL, &e.ModifiedAt); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// ReplicaPodcastUUIDs returns every podcast uuid the replica knows about —
// the sweep list for deep-history seeding.
func (s *Store) ReplicaPodcastUUIDs(userID int64) ([]string, error) {
	rows, err := s.db.Query(`
SELECT DISTINCT podcast_uuid FROM pc_replica WHERE user_id = ? AND podcast_uuid != ''
UNION SELECT DISTINCT podcast_uuid FROM pc_history_ledger WHERE user_id = ? AND podcast_uuid != ''`,
		userID, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var uuid string
		if err := rows.Scan(&uuid); err != nil {
			return nil, err
		}
		out = append(out, uuid)
	}
	return out, rows.Err()
}

// ReplicaEpisode returns one replica episode row (test/inspection helper).
func (s *Store) ReplicaEpisode(userID int64, uuid string) (bool, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM pc_replica WHERE user_id = ? AND kind = 'episode' AND uuid = ?`, userID, uuid).Scan(&n)
	return n > 0, err
}
