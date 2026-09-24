package replica

import (
	"context"
	"log/slog"
	"sync/atomic"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

// Seeding the Pocket Casts replica. Three passes, because each source has a
// blind spot (measured 2026-07-31 against a real account):
//
//   1. cursor-0 sync — all ACTIVE episode state, subscribed and unsubscribed
//      podcasts alike, but archived episodes are excluded entirely;
//   2. the history ledger — played episodes regardless of archive state, but
//      capped at the newest 100 by PC's server;
//   3. per-podcast /user/podcast/episodes over every podcast uuid the first
//      two passes surfaced — the deep-history pass that recovers archived
//      state (the app relies on the same call for played marks on old
//      episodes).
//
// After the seed, the watcher's polls and the /pcapi relay keep the replica
// current, and the ledger accumulates past PC's window forever.

type Seeder struct {
	store   *store.Store
	logger  *slog.Logger
	running atomic.Bool
}

func NewSeeder(st *store.Store, logger *slog.Logger) *Seeder {
	return &Seeder{store: st, logger: logger}
}

func (s *Seeder) Running() bool { return s.running.Load() }

type SeedResult struct {
	SyncEpisodes  int `json:"syncEpisodes"`
	OtherRecords  int `json:"otherRecords"`
	LedgerEntries int `json:"ledgerEntries"`
	PodcastsSwept int `json:"podcastsSwept"`
	SweepEpisodes int `json:"sweepEpisodes"`
	SweepFailures int `json:"sweepFailures"`
}

// Seed runs the three passes. Callers handle token refresh before invoking;
// a second concurrent seed returns immediately.
func (s *Seeder) Seed(ctx context.Context, userID int64, accessToken string) (SeedResult, bool) {
	if !s.running.CompareAndSwap(false, true) {
		return SeedResult{}, false
	}
	defer s.running.Store(false)
	var result SeedResult

	// Pass 1: full active state.
	sync, err := pc.FetchProgress(ctx, accessToken, "pcs-server", 0)
	if err != nil {
		s.logger.Warn("replica seed: cursor-0", "err", err)
	} else {
		if err := s.store.UpsertReplicaEpisodes(userID, "seed-sync", sync.Episodes); err != nil {
			s.logger.Warn("replica seed: store episodes", "err", err)
		}
		if err := s.store.UpsertReplicaRecords(userID, "seed-sync", sync.Others); err != nil {
			s.logger.Warn("replica seed: store records", "err", err)
		}
		result.SyncEpisodes = len(sync.Episodes)
		result.OtherRecords = len(sync.Others)
	}

	// Pass 2: the (capped) history ledger.
	history, err := pc.FetchHistory(ctx, accessToken)
	if err != nil {
		s.logger.Warn("replica seed: history", "err", err)
	} else {
		if err := s.store.UpsertHistoryLedger(userID, history.Entries); err != nil {
			s.logger.Warn("replica seed: ledger", "err", err)
		}
		result.LedgerEntries = len(history.Entries)
	}

	// The subscription list contributes podcast uuids (podcasts with zero
	// active episode records would otherwise hide from the sweep).
	uuidSet := map[string]bool{}
	if list, err := pc.FetchPodcasts(ctx, accessToken); err != nil {
		s.logger.Warn("replica seed: podcast list", "err", err)
	} else {
		for _, p := range list.Podcasts {
			uuidSet[p.UUID] = true
		}
	}
	if known, err := s.store.ReplicaPodcastUUIDs(userID); err == nil {
		for _, uuid := range known {
			uuidSet[uuid] = true
		}
	}

	// Pass 3: deep history, one podcast at a time (sequential on purpose —
	// this is a background backfill, not a latency-sensitive path).
	for uuid := range uuidSet {
		if ctx.Err() != nil {
			break
		}
		episodes, err := pc.FetchPodcastEpisodes(ctx, accessToken, uuid)
		if err != nil {
			result.SweepFailures++
			s.logger.Debug("replica seed: podcast sweep", "podcast", uuid, "err", err)
			continue
		}
		if err := s.store.UpsertReplicaEpisodes(userID, "seed-podcast", episodes); err != nil {
			s.logger.Warn("replica seed: store sweep", "podcast", uuid, "err", err)
			continue
		}
		result.PodcastsSwept++
		result.SweepEpisodes += len(episodes)
		if result.PodcastsSwept%25 == 0 {
			s.logger.Info("replica seed: sweeping", "podcasts", result.PodcastsSwept, "episodes", result.SweepEpisodes)
		}
	}

	s.logger.Info("replica seed done",
		"user", userID,
		"syncEpisodes", result.SyncEpisodes,
		"otherRecords", result.OtherRecords,
		"ledger", result.LedgerEntries,
		"podcastsSwept", result.PodcastsSwept,
		"sweepEpisodes", result.SweepEpisodes,
		"sweepFailures", result.SweepFailures)
	return result, true
}
