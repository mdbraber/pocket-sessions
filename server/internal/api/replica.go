package api

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
)

// Replica management: seed (async, single-flight), status, and the
// accumulated history ledger — the listening history PC itself caps at 100.

func (s *Server) handleReplicaSeed(w http.ResponseWriter, r *http.Request, userID int64) {
	// Claim the single seed slot first: checking and claiming separately let
	// two requests both refresh the (rotating) PC token and both answer
	// "started".
	if !s.seeder.Claim() {
		writeJSON(w, map[string]any{"started": false, "reason": "already-running"})
		return
	}
	link, linked, err := s.store.PCLink(userID)
	if err != nil {
		s.seeder.Release()
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	if !linked {
		s.seeder.Release()
		http.Error(w, errNotLinked.Error(), http.StatusPreconditionRequired)
		return
	}
	// Refresh up front: the seed can run for minutes and retries poorly. Under
	// the user lock, so a concurrent poll can't spend the same refresh token.
	refresh := func() error {
		if link.RefreshToken == "" {
			return nil
		}
		if exchange, exErr := pc.ExchangeRefreshToken(r.Context(), link.RefreshToken, link.Scope); exErr == nil {
			link.AccessToken = exchange.AccessToken
			if exchange.RefreshToken != "" {
				link.RefreshToken = exchange.RefreshToken
			}
			_ = s.store.SetPCLink(userID, link)
		}
		return nil
	}
	if s.progress != nil {
		_ = s.progress.WithUserLock(userID, func() error {
			// Re-read: a poll may have rotated the token while we waited.
			if current, ok, err := s.store.PCLink(userID); err == nil && ok {
				link = current
			}
			return refresh()
		})
	} else {
		_ = refresh()
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
		defer cancel()
		result := s.seeder.Run(ctx, userID, link.AccessToken)
		s.logger.Info("replica seed finished", "user", userID, "result", result)
	}()
	writeJSON(w, map[string]any{"started": true})
}

func (s *Server) handleReplicaStatus(w http.ResponseWriter, r *http.Request, userID int64) {
	status, err := s.store.ReplicaStatus(userID)
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"seedRunning": s.seeder.Running(), "replica": status})
}

func (s *Server) handleReplicaHistory(w http.ResponseWriter, r *http.Request, userID int64) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	entries, err := s.store.HistoryLedger(userID, limit)
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"entries": entries, "count": len(entries)})
}

// POST /api/v1/hooks/replay — queue every feed episode's current state for
// delivery through the hooks, once each. The recovery tool after downtime:
// hooks are idempotent, so over-delivery is harmless and under-delivery
// (the thing an outage causes) is what this repairs.
func (s *Server) handleHooksReplay(w http.ResponseWriter, r *http.Request, userID int64) {
	if s.progress == nil {
		http.Error(w, "watcher unavailable", http.StatusServiceUnavailable)
		return
	}
	fired, err := s.progress.ReplayIndexed(r.Context(), userID)
	if err != nil {
		http.Error(w, "replay failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"replayed": fired})
}
