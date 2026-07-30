package store

import "database/sql"

// An index of enclosure URLs across the account's subscribed podcasts, built
// lazily from Pocket Casts' public catalogs. External playback reports (POST
// /api/v1/playback) identify an episode by an enclosure substring — for
// OwnTube that's the videoId — and this is what resolves it.

type EpisodeEnclosure struct {
	EpisodeUUID string
	PodcastUUID string
	URL         string
}

// SaveEpisodeEnclosures upserts the given entries (existing rows refresh).
func (s *Store) SaveEpisodeEnclosures(userID int64, entries []EpisodeEnclosure) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	stmt, err := tx.Prepare(`
INSERT INTO episode_enclosures (user_id, episode_uuid, podcast_uuid, url, updated_at)
VALUES (?, ?, ?, ?, datetime('now'))
ON CONFLICT (user_id, episode_uuid) DO UPDATE SET
  podcast_uuid = excluded.podcast_uuid, url = excluded.url, updated_at = excluded.updated_at`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, e := range entries {
		if e.EpisodeUUID == "" || e.URL == "" {
			continue
		}
		if _, err := stmt.Exec(userID, e.EpisodeUUID, e.PodcastUUID, e.URL); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// FindEpisodeByEnclosure returns the episode whose enclosure URL contains the
// given fragment. The newest row wins if several match (a feed republishing
// the same media under a new episode uuid).
func (s *Store) FindEpisodeByEnclosure(userID int64, fragment string) (EpisodeEnclosure, bool, error) {
	row := s.db.QueryRow(`
SELECT episode_uuid, podcast_uuid, url FROM episode_enclosures
WHERE user_id = ? AND instr(url, ?) > 0
ORDER BY updated_at DESC LIMIT 1`, userID, fragment)
	var e EpisodeEnclosure
	if err := row.Scan(&e.EpisodeUUID, &e.PodcastUUID, &e.URL); err != nil {
		if err == sql.ErrNoRows {
			return EpisodeEnclosure{}, false, nil
		}
		return EpisodeEnclosure{}, false, err
	}
	return e, true, nil
}
