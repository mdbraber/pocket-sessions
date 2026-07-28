package api

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

// maxPendingLinks caps outstanding unauthenticated enrollments — each start
// costs an outbound call to PC, so a stranger can't use us as a code fountain.
const maxPendingLinks = 32

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

// handlePCLinkStart begins a device-code enrollment. Deliberately UNAUTHENTICATED:
// a new device has no PCS token yet — proving control of an allowed Pocket Casts
// account (by approving the code) IS the credential. Start only hands out a
// pairing code, so the gate lives in complete.
func (s *Server) handlePCLinkStart(w http.ResponseWriter, r *http.Request) {
	s.pendingMu.Lock()
	for id, p := range s.pendingLinks {
		if time.Now().After(p.expires) {
			delete(s.pendingLinks, id)
		}
	}
	full := len(s.pendingLinks) >= maxPendingLinks
	s.pendingMu.Unlock()
	if full {
		http.Error(w, "too many pending links", http.StatusTooManyRequests)
		return
	}

	auth, err := pc.DeviceAuthorize(r.Context())
	if err != nil {
		s.logger.Error("pc link start", "err", err)
		http.Error(w, "pocket casts device authorize failed", http.StatusBadGateway)
		return
	}
	linkID := newLinkID()
	s.pendingMu.Lock()
	s.pendingLinks[linkID] = pendingLink{deviceCode: auth.DeviceCode, expires: time.Now().Add(time.Duration(auth.ExpiresIn) * time.Second)}
	s.pendingMu.Unlock()
	writeJSON(w, map[string]any{
		"linkId":                  linkID,
		"userCode":                auth.UserCode,
		"verificationUri":         auth.VerificationURI,
		"verificationUriComplete": auth.VerificationURIComplete,
		"expiresIn":               auth.ExpiresIn,
		"interval":                auth.Interval,
	})
}

// handlePCLinkComplete redeems a pending device code. Until the code is approved
// PC answers authorization_pending, surfaced as 202 so the caller can retry.
// Success proves the caller controls the PC account PC reports back; if that
// account is welcome here (enrollmentAllowed), the lineage is stored and the
// device gets its own PCS API token — no bootstrap token involved.
func (s *Server) handlePCLinkComplete(w http.ResponseWriter, r *http.Request) {
	var in struct {
		LinkID string `json:"linkId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.LinkID == "" {
		http.Error(w, "bad request — send the linkId from /pc-link/start", http.StatusBadRequest)
		return
	}
	s.pendingMu.Lock()
	pending, ok := s.pendingLinks[in.LinkID]
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

	allowed, err := s.enrollmentAllowed(exchange.Email)
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	if !allowed {
		s.logger.Warn("pc link: enrollment rejected", "email", exchange.Email)
		http.Error(w, "this Pocket Casts account is not allowed on this server", http.StatusForbidden)
		return
	}

	// Single-user server: every enrollment lands on user 1. (Multi-user later:
	// resolve or create the user by PC email here.)
	const userID = int64(1)
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
	delete(s.pendingLinks, in.LinkID)
	s.pendingMu.Unlock()

	// The minted token is the device's real credential from here on. Enrollment
	// without a token in hand is the whole point, so a mint failure fails the call.
	label := "pc-link"
	if deviceID := r.Header.Get("X-Device-Id"); deviceID != "" {
		label = "device:" + deviceID
	}
	apiToken, err := s.store.CreateToken(userID, label)
	if err != nil {
		s.logger.Error("pc link: token mint failed", "err", err)
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}

	s.logger.Info("device enrolled via pc link", "user", userID, "email", exchange.Email, "label", label)
	writeJSON(w, map[string]any{"linked": true, "email": exchange.Email, "renewable": exchange.RefreshToken != "", "apiToken": apiToken})
}

// enrollmentAllowed decides whether an approved PC account may enroll: it's on
// the PCS_ALLOWED_EMAILS list, it's the account already linked, or the server is
// completely fresh (nothing to protect yet — trust the first link).
func (s *Server) enrollmentAllowed(email string) (bool, error) {
	if email == "" {
		return false, nil
	}
	for _, allowed := range s.allowedEmails {
		if strings.EqualFold(allowed, email) {
			return true, nil
		}
	}
	if exists, err := s.store.PCLinkEmailExists(email); err != nil || exists {
		return exists, err
	}
	if len(s.allowedEmails) > 0 {
		return false, nil
	}
	hasAny, err := s.store.HasPCLinks()
	return !hasAny, err
}

func newLinkID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
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

	// Never let a donated token DOWNGRADE a renewable lineage: older app builds
	// re-post their (refresh-token-less) credentials after every PC sync, which
	// would silently replace a self-renewing device-flow link with an expiring one.
	if existing, linked, err := s.store.PCLink(userID); err == nil && linked && existing.RefreshToken != "" && in.RefreshToken == "" {
		writeJSON(w, map[string]any{"linked": true, "email": existing.Email})
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
