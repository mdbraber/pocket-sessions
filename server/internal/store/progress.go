package store

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
}

func (s *Store) AllEpisodeProgress(userID int64) (map[string]EpisodeProgress, error) {
	rows, err := s.db.Query(`
SELECT episode_uuid, podcast_uuid, played_up_to, playing_status, duration, archived
FROM episode_progress WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]EpisodeProgress{}
	for rows.Next() {
		var p EpisodeProgress
		if err := rows.Scan(&p.EpisodeUUID, &p.PodcastUUID, &p.PlayedUpTo, &p.PlayingStatus, &p.Duration, &p.Archived); err != nil {
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
	for _, p := range entries {
		if _, err := tx.Exec(`
INSERT INTO episode_progress (user_id, episode_uuid, podcast_uuid, played_up_to, playing_status, duration, archived, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
ON CONFLICT(user_id, episode_uuid) DO UPDATE
SET podcast_uuid = excluded.podcast_uuid, played_up_to = excluded.played_up_to,
    playing_status = excluded.playing_status, duration = excluded.duration,
    archived = excluded.archived, updated_at = excluded.updated_at`,
			userID, p.EpisodeUUID, p.PodcastUUID, p.PlayedUpTo, p.PlayingStatus, p.Duration, p.Archived); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ProgressCursor is PC's `lastModified` for this user's progress polling; 0
// means "never polled", which seeds the baseline without firing hooks.
func (s *Store) ProgressCursor(userID int64) (int64, error) {
	var cursor int64
	err := s.db.QueryRow(`SELECT COALESCE(progress_cursor, 0) FROM meta WHERE user_id = ?`, userID).Scan(&cursor)
	return cursor, err
}

func (s *Store) SetProgressCursor(userID, cursor int64) error {
	_, err := s.db.Exec(`UPDATE meta SET progress_cursor = ? WHERE user_id = ?`, cursor, userID)
	return err
}
