package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

// POST /api/v1/playback — an external player (OwnTube, or any service the
// account also watches through) reports playback state, and PCS writes it
// through to Pocket Casts as a sync record. The episode is identified by an
// enclosure-URL fragment (for OwnTube feeds: the videoId), resolved against
// an index of the subscribed podcasts' public catalogs.
//
// The echo guard keeps the PC→PCS→hook→OwnTube→here loop from oscillating:
// state that is not ahead of what PCS already knows from its watcher baseline
// is dropped, and the baseline is advanced on every accepted write so the
// watcher's next poll sees its own change as no-op (no hooks re-fired).
type playbackReport struct {
	EnclosureContains string `json:"enclosureContains"`
	PositionSeconds   int64  `json:"positionSeconds"`
	DurationSeconds   int64  `json:"durationSeconds,omitempty"`
	Completed         bool   `json:"completed"`
}

type playbackResult struct {
	Applied bool   `json:"applied"`
	Reason  string `json:"reason,omitempty"`
	Episode string `json:"episodeUuid,omitempty"`
}

// applyPlayback decides whether an external report is ahead of the known
// Pocket Casts state. Pure so the loop-prevention rules are testable.
func applyPlayback(prev store.EpisodeProgress, known bool, report playbackReport) (bool, string) {
	if report.Completed {
		if known && prev.PlayingStatus == pc.StatusCompleted {
			return false, "already-completed"
		}
		return true, ""
	}
	// Completion is sticky on both sides: a position-only report never
	// un-finishes an episode PC already considers done.
	if known && prev.PlayingStatus == pc.StatusCompleted {
		return false, "pc-completed"
	}
	if known && report.PositionSeconds <= prev.PlayedUpTo {
		return false, "behind"
	}
	return true, ""
}

func (s *Server) handlePlaybackReport(w http.ResponseWriter, r *http.Request, userID int64) {
	var in playbackReport
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	in.EnclosureContains = strings.TrimSpace(in.EnclosureContains)
	// A too-short fragment would substring-match unrelated enclosures.
	if len(in.EnclosureContains) < 6 || in.PositionSeconds < 0 {
		http.Error(w, "bad request: need {enclosureContains (>=6 chars), positionSeconds}", http.StatusBadRequest)
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

	episode, found, err := s.store.FindEpisodeByEnclosure(userID, in.EnclosureContains)
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	if !found {
		// Cold or stale index — rebuild from the subscribed podcasts' catalogs
		// (public CDN JSON) and retry once.
		if err := s.refreshEnclosureIndex(r.Context(), userID, &link); err != nil {
			s.logger.Warn("playback report: enclosure index", "err", err)
		}
		episode, found, err = s.store.FindEpisodeByEnclosure(userID, in.EnclosureContains)
		if err != nil {
			http.Error(w, "store failed", http.StatusInternalServerError)
			return
		}
	}
	if !found {
		writeJSON(w, playbackResult{Applied: false, Reason: "unknown-episode"})
		return
	}

	baseline, err := s.store.AllEpisodeProgress(userID)
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	prev, known := baseline[episode.EpisodeUUID]
	ok, reason := applyPlayback(prev, known, in)
	if !ok {
		writeJSON(w, playbackResult{Applied: false, Reason: reason, Episode: episode.EpisodeUUID})
		return
	}

	status := int64(pc.StatusInProgress)
	if in.Completed {
		status = pc.StatusCompleted
	}
	duration := in.DurationSeconds
	if duration == 0 {
		duration = prev.Duration
	}
	next := pc.EpisodeProgress{
		EpisodeUUID:   episode.EpisodeUUID,
		PodcastUUID:   episode.PodcastUUID,
		PlayedUpTo:    in.PositionSeconds,
		PlayingStatus: status,
		Duration:      duration,
	}

	cursor, _ := s.store.ProgressCursor(userID)
	_, err = pc.PushProgress(r.Context(), link.AccessToken, "pcs-server", next, cursor)
	if err != nil && link.RefreshToken != "" {
		if exchange, exErr := pc.ExchangeRefreshToken(r.Context(), link.RefreshToken, link.Scope); exErr == nil {
			link.AccessToken = exchange.AccessToken
			if exchange.RefreshToken != "" {
				link.RefreshToken = exchange.RefreshToken
			}
			_ = s.store.SetPCLink(userID, link)
			_, err = pc.PushProgress(r.Context(), link.AccessToken, "pcs-server", next, cursor)
		}
	}
	if err != nil {
		s.logger.Error("playback write-through", "episode", episode.EpisodeUUID, "err", err)
		http.Error(w, "pocket casts write failed: "+err.Error(), http.StatusBadGateway)
		return
	}

	// Advance the baseline to what we just wrote so the watcher's next poll
	// treats PC's echo of this change as already-known — no hooks fire, and
	// the report can't bounce back to its origin.
	saved := store.EpisodeProgress{
		EpisodeUUID:   next.EpisodeUUID,
		PodcastUUID:   next.PodcastUUID,
		PlayedUpTo:    next.PlayedUpTo,
		PlayingStatus: next.PlayingStatus,
		Duration:      next.Duration,
		// Not part of the report; keep the flag the watcher knows about.
		Archived: prev.Archived,
	}
	if err := s.store.SaveEpisodeProgress(userID, []store.EpisodeProgress{saved}); err != nil {
		s.logger.Warn("playback report: baseline save", "err", err)
	}

	s.logger.Info("playback write-through",
		"user", userID, "episode", episode.EpisodeUUID,
		"playedUpTo", next.PlayedUpTo, "status", next.PlayingStatus)

	// Tell the user's devices something changed upstream so the app re-syncs.
	if changes, cErr := s.store.ChangesSince(userID, 0); cErr == nil {
		s.fanOut(userID, changes.Cursor, r.Header.Get("X-Device-Id"))
	}
	writeJSON(w, playbackResult{Applied: true, Episode: episode.EpisodeUUID})
}

// refreshEnclosureIndex rebuilds the enclosure-URL index from the subscribed
// podcasts' public catalogs. Sequential on purpose: it runs on a lookup miss,
// which is rare (new feed, new episode), and the catalog is CDN-cached.
func (s *Server) refreshEnclosureIndex(ctx context.Context, userID int64, link *store.PCLink) error {
	list, err := pc.FetchPodcasts(ctx, link.AccessToken)
	if err != nil && link.RefreshToken != "" {
		if exchange, exErr := pc.ExchangeRefreshToken(ctx, link.RefreshToken, link.Scope); exErr == nil {
			link.AccessToken = exchange.AccessToken
			if exchange.RefreshToken != "" {
				link.RefreshToken = exchange.RefreshToken
			}
			_ = s.store.SetPCLink(userID, *link)
			list, err = pc.FetchPodcasts(ctx, link.AccessToken)
		}
	}
	if err != nil {
		return err
	}
	var entries []store.EpisodeEnclosure
	for _, podcast := range list.Podcasts {
		catalog, err := pc.FetchCatalog(ctx, podcast.UUID)
		if err != nil {
			s.logger.Debug("enclosure index: catalog", "podcast", podcast.UUID, "err", err)
			continue
		}
		for _, ep := range catalog.Episodes {
			entries = append(entries, store.EpisodeEnclosure{
				EpisodeUUID: ep.UUID,
				PodcastUUID: podcast.UUID,
				URL:         ep.URL,
			})
		}
	}
	return s.store.SaveEpisodeEnclosures(userID, entries)
}
