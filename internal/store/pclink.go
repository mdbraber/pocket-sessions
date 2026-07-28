package store

import "database/sql"

type PCLink struct {
	Email        string
	RefreshToken string
	AccessToken  string
	Scope        string // token lineage scope: "tv" (device-flow link) or "mobile"
}

// SetPCLink stores (or replaces) a user's Pocket Casts link. The refresh token
// rotates on every exchange, so callers persist the LATEST one from PC's response.
func (s *Store) SetPCLink(userID int64, link PCLink) error {
	if link.Scope == "" {
		link.Scope = "mobile"
	}
	_, err := s.db.Exec(`
INSERT INTO pc_links (user_id, pc_email, pc_refresh_token, pc_access_token, pc_scope, linked_at)
VALUES (?, ?, ?, ?, ?, datetime('now'))
ON CONFLICT(user_id) DO UPDATE
SET pc_email = excluded.pc_email, pc_refresh_token = excluded.pc_refresh_token,
    pc_access_token = excluded.pc_access_token, pc_scope = excluded.pc_scope`,
		userID, link.Email, link.RefreshToken, link.AccessToken, link.Scope)
	return err
}

func (s *Store) PCLink(userID int64) (PCLink, bool, error) {
	var link PCLink
	err := s.db.QueryRow(`SELECT pc_email, pc_refresh_token, pc_access_token, pc_scope FROM pc_links WHERE user_id = ?`, userID).
		Scan(&link.Email, &link.RefreshToken, &link.AccessToken, &link.Scope)
	if err == sql.ErrNoRows {
		return PCLink{}, false, nil
	}
	return link, err == nil, err
}

func (s *Store) DeletePCLink(userID int64) error {
	_, err := s.db.Exec(`DELETE FROM pc_links WHERE user_id = ?`, userID)
	return err
}

// PCLinkEmailExists reports whether some user is already linked to this PC
// account (case-insensitive) — one of the ways an enrollment proves it's welcome.
func (s *Store) PCLinkEmailExists(email string) (bool, error) {
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM pc_links WHERE lower(pc_email) = lower(?)`, email).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

// HasPCLinks reports whether any PC account is linked at all — a completely
// fresh server trusts its first enrollment (there is nothing to protect yet).
func (s *Store) HasPCLinks() (bool, error) {
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM pc_links`).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}
