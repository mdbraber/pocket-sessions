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
		AccessToken  string `json:"accessToken"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || (in.RefreshToken == "" && in.AccessToken == "") {
		http.Error(w, "bad link request", http.StatusBadRequest)
		return
	}

	link := store.PCLink{RefreshToken: in.RefreshToken, AccessToken: in.AccessToken}
	// A refresh token is the good case: validate it with a real exchange and keep the
	// ROTATED token PC returns (the one the app sent may now be spent).
	if in.RefreshToken != "" {
		exchange, err := pc.ExchangeRefreshToken(r.Context(), in.RefreshToken)
		if err != nil {
			s.logger.Warn("pc link: refresh exchange failed, falling back to access token", "err", err)
		} else {
			link.Email = exchange.Email
			link.AccessToken = exchange.AccessToken
			if exchange.RefreshToken != "" {
				link.RefreshToken = exchange.RefreshToken
			}
		}
	}
	// No usable refresh token: validate the access token directly. It expires (the app
	// must re-link, or send a refresh token later), but it proves the link works today.
	if link.Email == "" {
		if link.AccessToken == "" {
			http.Error(w, "pocket casts exchange failed", http.StatusBadGateway)
			return
		}
		if err := pc.ValidateAccessToken(r.Context(), link.AccessToken); err != nil {
			s.logger.Error("pc link: access token rejected", "err", err)
			http.Error(w, "pocket casts rejected the token", http.StatusBadGateway)
			return
		}
	}
	exchange := struct{ Email string }{Email: link.Email}
	if err := s.store.SetPCLink(userID, link); err != nil {
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
