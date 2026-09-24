package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

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
	// Every episode the report resolved to (audio/video variants, the same
	// video in several feeds), each with its own outcome.
	Episodes []episodeOutcome `json:"episodes,omitempty"`
}

type episodeOutcome struct {
	Episode string `json:"episodeUuid"`
	Applied bool   `json:"applied"`
	Reason  string `json:"reason,omitempty"`
}

// Positions beyond this are rejected outright: one bogus value would
// otherwise make every real report "behind" until the episode completes.
const maxReportSeconds = 30 * 24 * 60 * 60

// applyPlayback decides whether an external report is ahead of the known
// Pocket Casts state, and whether it completes the episode. Pure so the
// loop-prevention rules are testable.
func applyPlayback(prev store.EpisodeProgress, known bool, report playbackReport) (apply bool, reason string, completed bool) {
	completed = report.Completed
	// OwnTube's "watched" flag is sticky: once a video is watched, every later
	// report says completed. If PC has since reopened the episode (mark
	// unplayed, or listening again), that flag is an echo of the old state —
	// honour it only when the report really is at the end.
	if completed && known && prev.Reopened == 1 &&
		!nearEnd(report.PositionSeconds, firstPositive(report.DurationSeconds, prev.Duration)) {
		completed = false
	}
	if completed {
		if known && prev.PlayingStatus == pc.StatusCompleted {
			return false, "already-completed", true
		}
		return true, "", true
	}
	// Completion is sticky on both sides: a position-only report never
	// un-finishes an episode PC already considers done.
	if known && prev.PlayingStatus == pc.StatusCompleted {
		return false, "pc-completed", false
	}
	if known && report.PositionSeconds <= prev.PlayedUpTo {
		return false, "behind", false
	}
	return true, "", false
}

// nearEnd: within the last 5% (at least 30s) of a known duration.
func nearEnd(position, duration int64) bool {
	if duration <= 0 {
		return false
	}
	margin := max(duration/20, 30)
	return position >= duration-margin
}

func firstPositive(values ...int64) int64 {
	for _, v := range values {
		if v > 0 {
			return v
		}
	}
	return 0
}

func (s *Server) handlePlaybackReport(w http.ResponseWriter, r *http.Request, userID int64) {
	var in playbackReport
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	in.EnclosureContains = strings.TrimSpace(in.EnclosureContains)
	// A too-short fragment would substring-match unrelated enclosures.
	if len(in.EnclosureContains) < 6 || in.PositionSeconds < 0 || in.DurationSeconds < 0 ||
		in.PositionSeconds > maxReportSeconds || in.DurationSeconds > maxReportSeconds {
		http.Error(w, "bad request: need {enclosureContains (>=6 chars), positionSeconds}", http.StatusBadRequest)
		return
	}
	if in.DurationSeconds > 0 && in.PositionSeconds > in.DurationSeconds {
		in.PositionSeconds = in.DurationSeconds
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

	// The work below must not die with the request: a reporter that gives up
	// (n8n's 30s timeout) would otherwise cut an index rebuild short, save a
	// partial index and poison the miss cache for its retry.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 3*time.Minute)
	defer cancel()

	// A remembered miss answers instantly — re-reported non-feed videos must
	// not trigger a catalog sweep every cycle.
	if s.encMiss.hit(userID, in.EnclosureContains) {
		writeJSON(w, playbackResult{Applied: false, Reason: "unknown-episode"})
		return
	}
	episodes, err := s.store.FindEpisodesByEnclosure(userID, in.EnclosureContains)
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}
	if len(episodes) == 0 && s.encRefreshLim.allow(userID) {
		// The episode watcher keeps the index fresh; a miss here is a feed
		// episode newer than its last cycle. Rebuild (at most once per
		// cooldown) and retry once. Only a completed rebuild may cache a miss
		// — and it resets the user's old misses, which may be hits now.
		rebuildErr := s.refreshEnclosureIndex(ctx, userID, &link)
		if rebuildErr != nil {
			s.logger.Warn("playback report: enclosure index", "err", rebuildErr)
		} else {
			s.encMiss.clear(userID)
		}
		episodes, err = s.store.FindEpisodesByEnclosure(userID, in.EnclosureContains)
		if err != nil {
			http.Error(w, "store failed", http.StatusInternalServerError)
			return
		}
		if len(episodes) == 0 && rebuildErr == nil {
			s.encMiss.add(userID, in.EnclosureContains)
		}
	}
	if len(episodes) == 0 {
		writeJSON(w, playbackResult{Applied: false, Reason: "unknown-episode"})
		return
	}

	var result playbackResult
	var writeErr error
	apply := func() error {
		baseline, err := s.store.AllEpisodeProgress(userID)
		if err != nil {
			return err
		}
		for _, episode := range episodes {
			outcome, err := s.applyToEpisode(ctx, userID, &link, baseline, episode, in)
			if err != nil {
				writeErr = err
				outcome = episodeOutcome{Episode: episode.EpisodeUUID, Reason: "write-failed"}
			}
			result.Episodes = append(result.Episodes, outcome)
		}
		return nil
	}
	// Serialised with the watcher's polls: a poll that fetched PC before this
	// write must not save its older state over the baseline written here.
	if s.progress != nil {
		err = s.progress.WithUserLock(userID, apply)
	} else {
		err = apply()
	}
	if err != nil {
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}

	for _, outcome := range result.Episodes {
		if outcome.Applied && !result.Applied {
			result.Applied = true
			result.Episode = outcome.Episode
		}
	}
	if !result.Applied {
		if writeErr != nil {
			http.Error(w, "pocket casts write failed: "+writeErr.Error(), http.StatusBadGateway)
			return
		}
		result.Episode = result.Episodes[0].Episode
		result.Reason = result.Episodes[0].Reason
		writeJSON(w, result)
		return
	}

	// Tell the user's devices something changed upstream so the app re-syncs.
	if changes, cErr := s.store.ChangesSince(userID, 0); cErr == nil {
		s.fanOut(userID, changes.Cursor, r.Header.Get("X-Device-Id"))
	}
	writeJSON(w, result)
}

// applyToEpisode applies one report to one episode: the echo guard, the sync
// record write to PC, and the baseline advance. Callers hold the user lock.
func (s *Server) applyToEpisode(ctx context.Context, userID int64, link *store.PCLink,
	baseline map[string]store.EpisodeProgress, episode store.EpisodeEnclosure, in playbackReport) (episodeOutcome, error) {

	prev, known := baseline[episode.EpisodeUUID]
	if !known {
		// The watcher baseline only knows episodes PC returned to its polls
		// (its seed excludes archived ones); the replica's deep sweep covers
		// the rest. Without this, an old finished episode would read as
		// "unknown" and a stray position report would un-complete it.
		if st, found, err := s.store.LoadReplicaEpisode(userID, episode.EpisodeUUID); err == nil && found {
			prev = store.EpisodeProgress{
				EpisodeUUID: st.EpisodeUUID, PodcastUUID: st.PodcastUUID,
				PlayedUpTo: st.PlayedUpTo, PlayingStatus: st.PlayingStatus,
				Duration: st.Duration, Archived: st.Archived,
			}
			known = true
		}
	}
	ok, reason, completed := applyPlayback(prev, known, in)
	if !ok {
		return episodeOutcome{Episode: episode.EpisodeUUID, Reason: reason}, nil
	}

	status := int64(pc.StatusInProgress)
	if completed {
		status = pc.StatusCompleted
	}
	next := pc.EpisodeProgress{
		EpisodeUUID:   episode.EpisodeUUID,
		PodcastUUID:   episode.PodcastUUID,
		PlayedUpTo:    in.PositionSeconds,
		PlayingStatus: status,
		Duration:      firstPositive(in.DurationSeconds, prev.Duration),
	}

	cursor, _ := s.store.ProgressCursor(userID)
	_, err := pc.PushProgress(ctx, link.AccessToken, "pcs-server", next, cursor)
	if err != nil && link.RefreshToken != "" {
		if exchange, exErr := pc.ExchangeRefreshToken(ctx, link.RefreshToken, link.Scope); exErr == nil {
			link.AccessToken = exchange.AccessToken
			if exchange.RefreshToken != "" {
				link.RefreshToken = exchange.RefreshToken
			}
			_ = s.store.SetPCLink(userID, *link)
			_, err = pc.PushProgress(ctx, link.AccessToken, "pcs-server", next, cursor)
		}
	}
	if err != nil {
		s.logger.Error("playback write-through", "episode", episode.EpisodeUUID, "err", err)
		return episodeOutcome{}, err
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
		// Not part of the report; keep the flags the watcher knows about.
		Archived: prev.Archived,
		Reopened: prev.Reopened,
	}
	if completed {
		saved.Reopened = 0
	}
	if err := s.store.SaveEpisodeProgress(userID, []store.EpisodeProgress{saved}); err != nil {
		s.logger.Warn("playback report: baseline save", "err", err)
	}

	s.logger.Info("playback write-through",
		"user", userID, "episode", episode.EpisodeUUID,
		"playedUpTo", next.PlayedUpTo, "status", next.PlayingStatus)
	return episodeOutcome{Episode: episode.EpisodeUUID, Applied: true}, nil
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
	entries := map[string][]store.EpisodeEnclosure{}
	var failed int
	for _, podcast := range list.Podcasts {
		catalog, err := pc.FetchCatalog(ctx, podcast.UUID)
		if err != nil {
			s.logger.Debug("enclosure index: catalog", "podcast", podcast.UUID, "err", err)
			failed++
			continue
		}
		for _, ep := range catalog.Episodes {
			entries[podcast.UUID] = append(entries[podcast.UUID], store.EpisodeEnclosure{
				EpisodeUUID: ep.UUID,
				PodcastUUID: podcast.UUID,
				URL:         ep.URL,
			})
		}
	}
	if err := s.store.SaveEpisodeEnclosures(userID, entries); err != nil {
		return err
	}
	// A rebuild that missed podcasts must not be trusted to cache misses.
	if failed > 0 {
		return fmt.Errorf("enclosure index: %d of %d catalogs failed", failed, len(list.Podcasts))
	}
	return nil
}
