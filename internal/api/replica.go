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
	if s.seeder.Running() {
		writeJSON(w, map[string]any{"started": false, "reason": "already-running"})
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
	// Refresh up front: the seed can run for minutes and retries poorly.
	if link.RefreshToken != "" {
		if exchange, exErr := pc.ExchangeRefreshToken(r.Context(), link.RefreshToken, link.Scope); exErr == nil {
			link.AccessToken = exchange.AccessToken
			if exchange.RefreshToken != "" {
				link.RefreshToken = exchange.RefreshToken
			}
			_ = s.store.SetPCLink(userID, link)
		}
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
		defer cancel()
		if result, ran := s.seeder.Seed(ctx, userID, link.AccessToken); ran {
			s.logger.Info("replica seed finished", "user", userID, "result", result)
		}
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
