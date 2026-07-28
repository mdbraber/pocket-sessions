package api

import (
	"context"
	"errors"
	"net/http"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
)

var errNotLinked = errors.New("no Pocket Casts account linked")

// The query API (/api/v1) — read access to what the server mirrored from Pocket
// Casts, for scripts, Shortcuts and dashboards. Reads are served from the mirror;
// /pull refreshes it on demand (the nudge does the same automatically).

func (s *Server) handlePullMirror(w http.ResponseWriter, r *http.Request, userID int64) {
	if err := s.refreshMirror(r.Context(), userID); err != nil {
		s.logger.Error("mirror pull", "err", err)
		http.Error(w, "mirror pull failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	s.handleUpNext(w, r, userID)
}

func (s *Server) handleUpNext(w http.ResponseWriter, r *http.Request, userID int64) {
	payload, fetchedAt, err := s.store.Mirror(userID, "up_next")
	if err != nil {
		http.Error(w, "no mirrored queue yet — POST /api/v1/pull first", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Mirror-Fetched-At", fetchedAt)
	_, _ = w.Write(payload)
}

// refreshMirror pulls the linked account's state from Pocket Casts into the
// mirror. Called by /api/v1/pull and by the session nudge (the app telling us it
// just synced), which is what keeps the mirror near-real-time.
func (s *Server) refreshMirror(ctx context.Context, userID int64) error {
	link, linked, err := s.store.PCLink(userID)
	if err != nil {
		return err
	}
	if !linked {
		return errNotLinked
	}
	upNext, err := pc.FetchUpNext(ctx, link.AccessToken, "pcs-server")
	if err != nil {
		// The access token may have expired — renew via the refresh token and retry once.
		if link.RefreshToken == "" {
			return err
		}
		exchange, exErr := pc.ExchangeRefreshToken(ctx, link.RefreshToken, link.Scope)
		if exErr != nil {
			return err
		}
		link.AccessToken = exchange.AccessToken
		if exchange.RefreshToken != "" {
			link.RefreshToken = exchange.RefreshToken
		}
		if exchange.Email != "" {
			link.Email = exchange.Email
		}
		_ = s.store.SetPCLink(userID, link)
		upNext, err = pc.FetchUpNext(ctx, link.AccessToken, "pcs-server")
		if err != nil {
			return err
		}
	}
	if err := s.store.SaveMirror(userID, "up_next", upNext); err != nil {
		return err
	}
	// History is bigger and changes more slowly; a failure here must not lose the
	// queue we just stored, so it only warns.
	if history, hErr := pc.FetchHistory(ctx, link.AccessToken); hErr == nil {
		if sErr := s.store.SaveMirror(userID, "history", history); sErr != nil {
			s.logger.Warn("mirror save (history)", "err", sErr)
		}
	} else {
		s.logger.Warn("mirror fetch (history)", "err", hErr)
	}
	return nil
}

func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request, userID int64) {
	payload, fetchedAt, err := s.store.Mirror(userID, "history")
	if err != nil {
		http.Error(w, "no mirrored history yet — POST /api/v1/pull first", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Mirror-Fetched-At", fetchedAt)
	_, _ = w.Write(payload)
}
