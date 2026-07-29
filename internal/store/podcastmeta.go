package store

// AllPodcastMeta returns the cached catalog metadata: uuid → [title, author].
// The table stays small (one row per subscription ever seen), so reading it
// whole is simpler than IN-clause plumbing.
func (s *Store) AllPodcastMeta() (map[string][2]string, error) {
	rows, err := s.db.Query(`SELECT uuid, title, author FROM podcast_meta`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string][2]string{}
	for rows.Next() {
		var uuid, title, author string
		if err := rows.Scan(&uuid, &title, &author); err != nil {
			return nil, err
		}
		out[uuid] = [2]string{title, author}
	}
	return out, rows.Err()
}

func (s *Store) SavePodcastMeta(uuid, title, author string) error {
	_, err := s.db.Exec(`
INSERT INTO podcast_meta (uuid, title, author, fetched_at) VALUES (?, ?, ?, datetime('now'))
ON CONFLICT(uuid) DO UPDATE SET title = excluded.title, author = excluded.author, fetched_at = excluded.fetched_at`,
		uuid, title, author)
	return err
}
