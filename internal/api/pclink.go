package api

import (
	"encoding/json"
	"net/http"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

// The PC link: the app sends its Pocket Casts REFRESH token once (never a password);
// the server validates it with a real token exchange, then acts as another PC client.
// M2 stage 1 — the mirror puller and query API build on this.

func (s *Server) handlePCLinkStatus(w http.ResponseWriter, r *http.Request, userID int64) {
	link, linked, err := s.store.PCLink(userID)
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"linked": linked, "email": link.Email})
}

func (s *Server) handlePCLink(w http.ResponseWriter, r *http.Request, userID int64) {
	var in struct {
		RefreshToken string `json:"refreshToken"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.RefreshToken == "" {
		http.Error(w, "bad link request", http.StatusBadRequest)
		return
	}
	// Validate by doing a real exchange — and keep the ROTATED refresh token PC returns,
	// not the one the app sent (which this exchange may have just invalidated).
	exchange, err := pc.ExchangeRefreshToken(r.Context(), in.RefreshToken)
	if err != nil {
		s.logger.Error("pc link exchange", "err", err)
		http.Error(w, "pocket casts exchange failed", http.StatusBadGateway)
		return
	}
	rotated := exchange.RefreshToken
	if rotated == "" {
		rotated = in.RefreshToken
	}
	if err := s.store.SetPCLink(userID, store.PCLink{
		Email:        exchange.Email,
		RefreshToken: rotated,
		AccessToken:  exchange.AccessToken,
	}); err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	s.logger.Info("pc account linked", "user", userID, "email", exchange.Email)
	writeJSON(w, map[string]any{"linked": true, "email": exchange.Email})
}

func (s *Server) handlePCUnlink(w http.ResponseWriter, r *http.Request, userID int64) {
	if err := s.store.DeletePCLink(userID); err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
