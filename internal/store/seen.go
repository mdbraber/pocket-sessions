package store

// SeenEpisodes returns the watcher's ledger for a user: which episode uuids it
// already knows, and which podcasts have been seeded at all (a podcast with no
// rows is new to the watcher — its current episodes seed silently, no alerts).
func (s *Store) SeenEpisodes(userID int64) (episodes map[string]bool, podcasts map[string]bool, err error) {
	rows, err := s.db.Query(`SELECT episode_uuid, podcast_uuid FROM seen_episodes WHERE user_id = ?`, userID)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	episodes, podcasts = map[string]bool{}, map[string]bool{}
	for rows.Next() {
		var episodeUUID, podcastUUID string
		if err := rows.Scan(&episodeUUID, &podcastUUID); err != nil {
			return nil, nil, err
		}
		episodes[episodeUUID] = true
		podcasts[podcastUUID] = true
	}
	return episodes, podcasts, rows.Err()
}

func (s *Store) MarkEpisodesSeen(userID int64, podcastUUID string, episodeUUIDs []string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, uuid := range episodeUUIDs {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO seen_episodes(user_id, episode_uuid, podcast_uuid) VALUES (?, ?, ?)`,
			userID, uuid, podcastUUID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// LinkedUserIDs lists users with a PC link — the set the episode watcher serves.
func (s *Store) LinkedUserIDs() ([]int64, error) {
	rows, err := s.db.Query(`SELECT user_id FROM pc_links`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
