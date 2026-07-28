package store

import "database/sql"

type PCLink struct {
	Email        string
	RefreshToken string
	AccessToken  string
}

// SetPCLink stores (or replaces) a user's Pocket Casts link. The refresh token
// rotates on every exchange, so callers persist the LATEST one from PC's response.
func (s *Store) SetPCLink(userID int64, link PCLink) error {
	_, err := s.db.Exec(`
INSERT INTO pc_links (user_id, pc_email, pc_refresh_token, pc_access_token, linked_at)
VALUES (?, ?, ?, ?, datetime('now'))
ON CONFLICT(user_id) DO UPDATE
SET pc_email = excluded.pc_email, pc_refresh_token = excluded.pc_refresh_token,
    pc_access_token = excluded.pc_access_token`,
		userID, link.Email, link.RefreshToken, link.AccessToken)
	return err
}

func (s *Store) PCLink(userID int64) (PCLink, bool, error) {
	var link PCLink
	err := s.db.QueryRow(`SELECT pc_email, pc_refresh_token, pc_access_token FROM pc_links WHERE user_id = ?`, userID).
		Scan(&link.Email, &link.RefreshToken, &link.AccessToken)
	if err == sql.ErrNoRows {
		return PCLink{}, false, nil
	}
	return link, err == nil, err
}

func (s *Store) DeletePCLink(userID int64) error {
	_, err := s.db.Exec(`DELETE FROM pc_links WHERE user_id = ?`, userID)
	return err
}
