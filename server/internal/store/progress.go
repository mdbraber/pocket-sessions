package store

import "database/sql"

// Episode playback progress as last seen from Pocket Casts — the baseline the
// watcher diffs each poll against, so hooks fire on change rather than on
// every sync.

type EpisodeProgress struct {
	EpisodeUUID   string
	PodcastUUID   string
	PlayedUpTo    int64
	PlayingStatus int64
	Duration      int64
	// The app's archived flag (0/1) as last seen from Pocket Casts.
	Archived int64
	// 1 once PC moved this episode from completed back to unplayed or
	// in-progress; cleared when it completes again.
	Reopened int64
}

func (s *Store) AllEpisodeProgress(userID int64) (map[string]EpisodeProgress, error) {
	rows, err := s.db.Query(`
SELECT episode_uuid, podcast_uuid, played_up_to, playing_status, duration, archived, reopened
FROM episode_progress WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]EpisodeProgress{}
	for rows.Next() {
		var p EpisodeProgress
		if err := rows.Scan(&p.EpisodeUUID, &p.PodcastUUID, &p.PlayedUpTo, &p.PlayingStatus, &p.Duration, &p.Archived, &p.Reopened); err != nil {
			return nil, err
		}
		out[p.EpisodeUUID] = p
	}
	return out, rows.Err()
}

func (s *Store) SaveEpisodeProgress(userID int64, entries []EpisodeProgress) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := saveEpisodeProgress(tx, userID, entries); err != nil {
		return err
	}
	return tx.Commit()
}

func saveEpisodeProgress(tx *sql.Tx, userID int64, entries []EpisodeProgress) error {
	for _, p := range entries {
		if _, err := tx.Exec(`
INSERT INTO episode_progress (user_id, episode_uuid, podcast_uuid, played_up_to, playing_status, duration, archived, reopened, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
ON CONFLICT(user_id, episode_uuid) DO UPDATE
SET podcast_uuid = excluded.podcast_uuid, played_up_to = excluded.played_up_to,
    playing_status = excluded.playing_status, duration = excluded.duration,
    archived = excluded.archived, reopened = excluded.reopened, updated_at = excluded.updated_at`,
			userID, p.EpisodeUUID, p.PodcastUUID, p.PlayedUpTo, p.PlayingStatus, p.Duration, p.Archived, p.Reopened); err != nil {
			return err
		}
	}
	return nil
}

// CommitProgressPoll saves a poll's outcome atomically: the advanced baseline,
// the hook events diffed from it (queued for delivery) and the new cursor. A
// crash or a failed receiver can then never leave the baseline ahead of an
// event nobody delivered.
func (s *Store) CommitProgressPoll(userID int64, entries []EpisodeProgress, events []OutboxEvent, cursor int64) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := saveEpisodeProgress(tx, userID, entries); err != nil {
		return err
	}
	if err := enqueueHookEvents(tx, userID, events); err != nil {
		return err
	}
	if err := setProgressCursor(tx, userID, cursor); err != nil {
		return err
	}
	return tx.Commit()
}

// ProgressCursor is PC's `lastModified` for this user's progress polling; 0
// means "never polled", which seeds the baseline without firing hooks.
func (s *Store) ProgressCursor(userID int64) (int64, error) {
	var cursor int64
	err := s.db.QueryRow(`SELECT COALESCE(progress_cursor, 0) FROM meta WHERE user_id = ?`, userID).Scan(&cursor)
	if err == sql.ErrNoRows {
		return 0, nil // only user 1 gets a meta row up front
	}
	return cursor, err
}

// SetProgressCursor only ever moves the cursor forward.
func (s *Store) SetProgressCursor(userID, cursor int64) error {
	return setProgressCursor(s.db, userID, cursor)
}

type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

func setProgressCursor(db execer, userID, cursor int64) error {
	if _, err := db.Exec(`INSERT OR IGNORE INTO meta(user_id, cursor) VALUES (?, 0)`, userID); err != nil {
		return err
	}
	_, err := db.Exec(`UPDATE meta SET progress_cursor = MAX(progress_cursor, ?) WHERE user_id = ?`, cursor, userID)
	return err
}
