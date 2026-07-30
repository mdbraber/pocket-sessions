// Package api wires the HTTP surface: /session/v1/* (app-facing sync) now; the
// query/automation API (/api/v1/*) arrives with the PC mirror in M2.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/push"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

type Server struct {
	store  *store.Store
	pusher push.Pusher
	logger *slog.Logger

	// PC accounts allowed to enroll through the unauthenticated pc-link flow
	// (PCS_ALLOWED_EMAILS); empty means "the already-linked account" (or anyone,
	// on a completely fresh server).
	allowedEmails []string

	// Polled on nudge so a just-finished episode reaches its hooks in seconds.
	progress progressPoller

	// Device-code links awaiting approval, keyed by linkId. In-memory on purpose:
	// codes live 30 minutes and a lost pending link just means re-tapping Link.
	pendingMu    sync.Mutex
	pendingLinks map[string]pendingLink
}

type pendingLink struct {
	deviceCode string
	expires    time.Time
}

// progressPoller is the playback-progress watcher, as the API needs it.
type progressPoller interface {
	PollUser(ctx context.Context, userID int64) error
}

func New(st *store.Store, pusher push.Pusher, logger *slog.Logger, allowedEmails []string, progress progressPoller) http.Handler {
	s := &Server{store: st, pusher: pusher, logger: logger, allowedEmails: allowedEmails, progress: progress, pendingLinks: map[string]pendingLink{}}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.Handle("POST /session/v1/devices", s.authed(s.handleRegisterDevice))
	mux.Handle("GET /session/v1/changes", s.authed(s.handleGetChanges))
	mux.Handle("POST /session/v1/changes", s.authed(s.handlePostChanges))
	mux.Handle("POST /session/v1/nudge", s.authed(s.handleNudge))
	mux.Handle("POST /session/v1/notify-podcasts", s.authed(s.handleNotifyPodcasts))
	mux.Handle("GET /session/v1/pc-link", s.authed(s.handlePCLinkStatus))
	mux.Handle("POST /session/v1/pc-link", s.authed(s.handlePCLink))
	// Enrollment is unauthenticated by design: approving the pairing code with an
	// allowed Pocket Casts account IS the credential (see handlePCLinkComplete).
	mux.HandleFunc("POST /session/v1/pc-link/start", s.handlePCLinkStart)
	mux.HandleFunc("POST /session/v1/pc-link/complete", s.handlePCLinkComplete)
	mux.Handle("DELETE /session/v1/pc-link", s.authed(s.handlePCUnlink))
	mux.Handle("GET /api/v1/up-next", s.authed(s.handleUpNext))
	mux.Handle("POST /api/v1/pull", s.authed(s.handlePullMirror))
	mux.Handle("POST /api/v1/up-next", s.authed(s.handleUpNextChange))
	mux.Handle("GET /api/v1/history", s.authed(s.handleHistory))
	mux.Handle("GET /api/v1/podcasts", s.authed(s.handlePodcasts))

	return s.logged(mux)
}

// authed resolves the bearer token to a user. A database with NO tokens at
// all (fresh local dev, no PCS_AUTH_TOKEN) runs open as user 1 — the moment
// any token exists, auth is required everywhere.
func (s *Server) authed(next func(http.ResponseWriter, *http.Request, int64)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if token != "" {
			userID, err := s.store.UserForToken(token)
			if err != nil {
				http.Error(w, "auth lookup failed", http.StatusInternalServerError)
				return
			}
			if userID != 0 {
				next(w, r, userID)
				return
			}
		}
		hasTokens, err := s.store.HasTokens()
		if err != nil {
			http.Error(w, "auth lookup failed", http.StatusInternalServerError)
			return
		}
		if !hasTokens {
			next(w, r, 1) // open local-dev mode
			return
		}
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	})
}

func (s *Server) logged(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		s.logger.Debug("request", "method", r.Method, "path", r.URL.Path, "ms", time.Since(start).Milliseconds())
	})
}

type deviceRegistration struct {
	DeviceID  string `json:"deviceId"`
	APNSToken string `json:"apnsToken"`
	APNSEnv   string `json:"apnsEnv"` // "sandbox" (dev-signed builds) or "production"
}

// handleNotifyPodcasts stores a device's per-podcast notification toggles —
// the app reports its full set on launch and whenever a toggle changes, and
// the episode watcher alerts on the union across devices (PCS_NOTIFY=synced).
func (s *Server) handleNotifyPodcasts(w http.ResponseWriter, r *http.Request, userID int64) {
	var in struct {
		UUIDs []string `json:"uuids"`
		// The app's GLOBAL "New Episodes" switch. A pointer so an older build that
		// omits it keeps its previous meaning (enabled) instead of being silenced.
		Enabled *bool `json:"enabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, "bad request: need {uuids: [...]}", http.StatusBadRequest)
		return
	}
	deviceID := r.Header.Get("X-Device-Id")
	if deviceID == "" {
		http.Error(w, "X-Device-Id header required", http.StatusBadRequest)
		return
	}
	if err := s.store.SetNotifyPodcasts(userID, deviceID, in.UUIDs); err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	if in.Enabled != nil {
		if err := s.store.SetNotifyEnabled(userID, deviceID, *in.Enabled); err != nil {
			http.Error(w, "store failed", http.StatusInternalServerError)
			return
		}
	}
	s.logger.Info("notify toggles updated", "user", userID, "device", deviceID,
		"podcasts", len(in.UUIDs), "enabled", in.Enabled)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleRegisterDevice(w http.ResponseWriter, r *http.Request, userID int64) {
	var reg deviceRegistration
	if err := json.NewDecoder(r.Body).Decode(&reg); err != nil || reg.DeviceID == "" {
		http.Error(w, "bad registration", http.StatusBadRequest)
		return
	}
	if reg.APNSEnv == "" {
		reg.APNSEnv = "sandbox"
	}
	if err := s.store.RegisterDevice(userID, reg.DeviceID, reg.APNSToken, reg.APNSEnv); err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetChanges(w http.ResponseWriter, r *http.Request, userID int64) {
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	changes, err := s.store.ChangesSince(userID, since)
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	writeJSON(w, changes)
}

func (s *Server) handlePostChanges(w http.ResponseWriter, r *http.Request, userID int64) {
	var in store.Changes
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, "bad changes", http.StatusBadRequest)
		return
	}
	cursor, changed, err := s.store.ApplyChanges(userID, in)
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	if changed {
		s.fanOut(userID, cursor, r.Header.Get("X-Device-Id"))
	}
	writeJSON(w, map[string]int64{"cursor": cursor})
}

// handleNudge — "I just finished a PC sync." In M1 this only wakes the user's
// OTHER devices (they may want to refresh from PC too); in M2 it will also
// trigger a mirror pull from PC.
func (s *Server) handleNudge(w http.ResponseWriter, r *http.Request, userID int64) {
	if err := s.store.BumpNudge(userID, r.Header.Get("X-Device-Id")); err != nil {
		s.logger.Warn("nudge bump", "err", err)
	}
	changes, err := s.store.ChangesSince(userID, 0)
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	s.fanOut(userID, changes.Cursor, r.Header.Get("X-Device-Id"))
	// The app just synced with PC, so our mirror is stale — refresh it in the
	// background (best effort; the nudge itself must stay instant).
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		if err := s.refreshMirror(ctx, userID); err != nil && !errors.Is(err, errNotLinked) {
			s.logger.Warn("mirror refresh after nudge", "err", err)
		}
		// The app nudges right after finishing a PC sync, so this is the moment
		// fresh playback progress exists — poll it and let the hooks run.
		if s.progress != nil {
			if err := s.progress.PollUser(ctx, userID); err != nil {
				s.logger.Warn("progress poll after nudge", "err", err)
			}
		}
	}()
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) fanOut(userID, cursor int64, originDeviceID string) {
	devices, err := s.store.DevicesExcept(userID, originDeviceID)
	if err != nil {
		s.logger.Error("device fan-out lookup", "err", err)
		return
	}
	if len(devices) > 0 {
		s.pusher.NotifyChanged(userID, cursor, devices)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
