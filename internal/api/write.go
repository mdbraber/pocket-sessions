package api

import (
	"encoding/json"
	"net/http"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
)

// Write-through automation: POST /api/v1/up-next applies a queue change to
// Pocket Casts with the linked account's token, stores the queue PC returns
// (one call writes AND refreshes the mirror), and nudges the user's devices so
// they pick the change up. Writes always go to PC, never to the mirror alone —
// staleness can't corrupt a write, and PC's own semantics resolve conflicts.
type queueChangeRequest struct {
	Action      string `json:"action"` // play_now | play_next | play_last | remove
	EpisodeUUID string `json:"episodeUuid"`
	Title       string `json:"title,omitempty"`       // only needed when PC can't resolve a new episode
	PodcastUUID string `json:"podcastUuid,omitempty"` // ditto
}

func (s *Server) handleUpNextChange(w http.ResponseWriter, r *http.Request, userID int64) {
	var in queueChangeRequest
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.EpisodeUUID == "" {
		http.Error(w, "bad request: need {action, episodeUuid}", http.StatusBadRequest)
		return
	}
	action, err := pc.ParseQueueAction(in.Action)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	link, linked, err := s.store.PCLink(userID)
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	if !linked {
		http.Error(w, errNotLinked.Error(), http.StatusPreconditionRequired)
		return
	}

	// Always write against a FRESH read: PC ignores changes carrying a stale
	// serverModified, and the mirror may be minutes old.
	current, err := pc.FetchUpNext(r.Context(), link.AccessToken, "pcs-server")
	if err != nil && link.RefreshToken != "" {
		if exchange, exErr := pc.ExchangeRefreshToken(r.Context(), link.RefreshToken); exErr == nil {
			link.AccessToken = exchange.AccessToken
			if exchange.RefreshToken != "" {
				link.RefreshToken = exchange.RefreshToken
			}
			_ = s.store.SetPCLink(userID, link)
			current, err = pc.FetchUpNext(r.Context(), link.AccessToken, "pcs-server")
		}
	}
	if err != nil {
		s.logger.Error("up next write-through: pre-read", "err", err)
		http.Error(w, "pocket casts read failed: "+err.Error(), http.StatusBadGateway)
		return
	}

	upNext, err := pc.ChangeUpNext(r.Context(), link.AccessToken, "pcs-server", action, in.EpisodeUUID, in.Title, in.PodcastUUID, current.ServerModified)
	if err != nil && link.RefreshToken != "" {
		// Access token may have expired — renew and retry once, same as the read path.
		if exchange, exErr := pc.ExchangeRefreshToken(r.Context(), link.RefreshToken); exErr == nil {
			link.AccessToken = exchange.AccessToken
			if exchange.RefreshToken != "" {
				link.RefreshToken = exchange.RefreshToken
			}
			_ = s.store.SetPCLink(userID, link)
			upNext, err = pc.ChangeUpNext(r.Context(), link.AccessToken, "pcs-server", action, in.EpisodeUUID, in.Title, in.PodcastUUID, current.ServerModified)
		}
	}
	if err != nil {
		s.logger.Error("up next write-through", "action", in.Action, "err", err)
		http.Error(w, "pocket casts write failed: "+err.Error(), http.StatusBadGateway)
		return
	}

	if err := s.store.SaveMirror(userID, "up_next", upNext); err != nil {
		s.logger.Warn("mirror save after write", "err", err)
	}
	// Tell the user's devices something changed upstream so they re-sync with PC.
	changes, cErr := s.store.ChangesSince(userID, 0)
	if cErr == nil {
		s.fanOut(userID, changes.Cursor, r.Header.Get("X-Device-Id"))
	}
	writeJSON(w, upNext)
}
