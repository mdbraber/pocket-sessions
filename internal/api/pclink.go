package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

// The PC link. Primary path is the device-code flow (/pc-link/start + /complete):
// the server mints its OWN token lineage via PC's TV-pairing flow and the app
// merely approves the code with its existing session — no password, and no token
// ever travels from the app to the server. The legacy POST /pc-link (app donates
// a token) stays as a curl-able fallback.

func (s *Server) handlePCLinkStatus(w http.ResponseWriter, r *http.Request, userID int64) {
	link, linked, err := s.store.PCLink(userID)
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	// "renewable" tells the app whether this link can refresh itself forever
	// (a refresh-token lineage) or will expire (a donated access token).
	writeJSON(w, map[string]any{"linked": linked, "email": link.Email, "renewable": link.RefreshToken != ""})
}

// handlePCLinkStart begins a device-code link: ask PC for a code pair, remember
// the device code server-side, and hand the app the user code to approve.
func (s *Server) handlePCLinkStart(w http.ResponseWriter, r *http.Request, userID int64) {
	auth, err := pc.DeviceAuthorize(r.Context())
	if err != nil {
		s.logger.Error("pc link start", "err", err)
		http.Error(w, "pocket casts device authorize failed", http.StatusBadGateway)
		return
	}
	s.pendingMu.Lock()
	s.pendingLinks[userID] = pendingLink{deviceCode: auth.DeviceCode, expires: time.Now().Add(time.Duration(auth.ExpiresIn) * time.Second)}
	s.pendingMu.Unlock()
	writeJSON(w, map[string]any{
		"userCode":                auth.UserCode,
		"verificationUri":         auth.VerificationURI,
		"verificationUriComplete": auth.VerificationURIComplete,
		"expiresIn":               auth.ExpiresIn,
		"interval":                auth.Interval,
	})
}

// handlePCLinkComplete redeems the pending device code. Until the code is
// approved PC answers authorization_pending, surfaced as 202 so the app can
// retry; success stores the lineage and issues the app its own PCS API token.
func (s *Server) handlePCLinkComplete(w http.ResponseWriter, r *http.Request, userID int64) {
	s.pendingMu.Lock()
	pending, ok := s.pendingLinks[userID]
	s.pendingMu.Unlock()
	if !ok || time.Now().After(pending.expires) {
		http.Error(w, "no pending link — POST /session/v1/pc-link/start first", http.StatusConflict)
		return
	}

	exchange, err := pc.RedeemDeviceCode(r.Context(), pending.deviceCode)
	if errors.Is(err, pc.ErrAuthorizationPending) {
		w.WriteHeader(http.StatusAccepted)
		writeJSON(w, map[string]any{"pending": true})
		return
	}
	if err != nil {
		s.logger.Error("pc link complete", "err", err)
		http.Error(w, "pocket casts device link failed", http.StatusBadGateway)
		return
	}

	if err := s.store.SetPCLink(userID, store.PCLink{
		Email:        exchange.Email,
		AccessToken:  exchange.AccessToken,
		RefreshToken: exchange.RefreshToken,
		Scope:        pc.DeviceScope,
	}); err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	s.pendingMu.Lock()
	delete(s.pendingLinks, userID)
	s.pendingMu.Unlock()

	// Issue the app its own PCS API token so the manually-typed bootstrap token
	// becomes an operator concern only. Failure to mint must not fail the link.
	apiToken := ""
	if deviceID := r.Header.Get("X-Device-Id"); true {
		label := "pc-link"
		if deviceID != "" {
			label = "device:" + deviceID
		}
		if tok, tokErr := s.store.CreateToken(userID, label); tokErr == nil {
			apiToken = tok
		} else {
			s.logger.Warn("pc link: token mint failed", "err", tokErr)
		}
	}

	s.logger.Info("pc account linked via device flow", "user", userID, "email", exchange.Email)
	writeJSON(w, map[string]any{"linked": true, "email": exchange.Email, "renewable": exchange.RefreshToken != "", "apiToken": apiToken})
}

func (s *Server) handlePCLink(w http.ResponseWriter, r *http.Request, userID int64) {
	var in struct {
		RefreshToken string `json:"refreshToken"`
		AccessToken  string `json:"accessToken"`
		// The account email as the APP knows it — used only for display when the
		// access-token path (no refresh token) gives us no identity of our own.
		Email string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || (in.RefreshToken == "" && in.AccessToken == "") {
		http.Error(w, "bad link request", http.StatusBadRequest)
		return
	}

	link := store.PCLink{RefreshToken: in.RefreshToken, AccessToken: in.AccessToken, Scope: "mobile"}
	// A refresh token is the good case: validate it with a real exchange and keep the
	// ROTATED token PC returns (the one the app sent may now be spent).
	if in.RefreshToken != "" {
		exchange, err := pc.ExchangeRefreshToken(r.Context(), in.RefreshToken, "mobile")
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
		link.Email = in.Email
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
