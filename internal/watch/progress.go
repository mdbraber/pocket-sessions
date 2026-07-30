package watch

import (
	"context"
	"log/slog"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/hooks"
	"github.com/mdbraber/pocket-sessions-server/internal/pc"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

// The playback-progress watcher: PC is polled as another sync device, changes
// are diffed against the stored baseline, and each material change becomes a
// hook event. PCS stays generic — it reports "this episode reached this point"
// with enough context (the enclosure URL) for a hook to recognise its own
// content and act on it.

// Above this many events in a single poll, the batch is treated as a bulk
// account operation rather than listening, and no hooks run (see PollUser).
const maxEventsPerPoll = 25

// ProgressWatcher polls one user's episode progress and fires hooks.
type ProgressWatcher struct {
	store  *store.Store
	hooks  *hooks.Runner
	logger *slog.Logger
	// Minimum playedUpTo movement (seconds) that counts as progress worth
	// reporting — without it a single listen would emit an event per sync.
	minDelta int64
}

func NewProgressWatcher(st *store.Store, runner *hooks.Runner, logger *slog.Logger, minDelta int64) *ProgressWatcher {
	if minDelta <= 0 {
		minDelta = 30
	}
	return &ProgressWatcher{store: st, hooks: runner, logger: logger, minDelta: minDelta}
}

// Run polls until ctx ends. The nudge path calls PollUser directly, so this is
// the backstop for devices that never nudge.
func (w *ProgressWatcher) Run(ctx context.Context, interval time.Duration) {
	w.logger.Info("progress watcher running", "interval", interval, "minDelta", w.minDelta)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		w.PollAll(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (w *ProgressWatcher) PollAll(ctx context.Context) {
	userIDs, err := w.store.LinkedUserIDs()
	if err != nil {
		w.logger.Warn("progress watcher: linked users", "err", err)
		return
	}
	for _, userID := range userIDs {
		if err := w.PollUser(ctx, userID); err != nil {
			w.logger.Warn("progress poll", "user", userID, "err", err)
		}
	}
}

// PollUser fetches changes since the stored cursor, fires hooks for material
// changes, and advances the cursor. The very first poll (cursor 0) returns the
// whole account, so it only seeds the baseline — replaying a lifetime of
// listening as "just completed" would be worse than useless.
func (w *ProgressWatcher) PollUser(ctx context.Context, userID int64) error {
	link, linked, err := w.store.PCLink(userID)
	if err != nil || !linked {
		return err
	}
	cursor, err := w.store.ProgressCursor(userID)
	if err != nil {
		return err
	}

	sync, err := pc.FetchProgress(ctx, link.AccessToken, "pcs-server", cursor)
	if err != nil && link.RefreshToken != "" {
		exchange, exErr := pc.ExchangeRefreshToken(ctx, link.RefreshToken, link.Scope)
		if exErr != nil {
			return err
		}
		link.AccessToken = exchange.AccessToken
		if exchange.RefreshToken != "" {
			link.RefreshToken = exchange.RefreshToken
		}
		_ = w.store.SetPCLink(userID, link)
		sync, err = pc.FetchProgress(ctx, link.AccessToken, "pcs-server", cursor)
	}
	if err != nil {
		return err
	}
	if len(sync.Episodes) == 0 {
		if sync.LastModified > cursor {
			return w.store.SetProgressCursor(userID, sync.LastModified)
		}
		return nil
	}

	baseline, err := w.store.AllEpisodeProgress(userID)
	if err != nil {
		return err
	}
	seeding := cursor == 0

	var toSave []store.EpisodeProgress
	var events []hooks.Event
	now := time.Now().Unix()
	for _, incoming := range sync.Episodes {
		previous, known := baseline[incoming.EpisodeUUID]
		// One response can carry the same episode more than once; keep the
		// running state so a repeat compares against what we just derived
		// rather than re-firing against the stale row.
		// PC omits fields it has nothing new to say about; keep what we knew.
		merged := store.EpisodeProgress{
			EpisodeUUID:   incoming.EpisodeUUID,
			PodcastUUID:   firstNonEmpty(incoming.PodcastUUID, previous.PodcastUUID),
			PlayedUpTo:    orPrevious(incoming.PlayedUpTo, previous.PlayedUpTo),
			PlayingStatus: orPrevious(incoming.PlayingStatus, previous.PlayingStatus),
			Duration:      orPrevious(incoming.Duration, previous.Duration),
			// -1 = the record didn't carry the flag; keep what we knew.
			Archived: previous.Archived,
		}
		if incoming.Archived >= 0 {
			merged.Archived = incoming.Archived
		}
		toSave = append(toSave, merged)
		baseline[merged.EpisodeUUID] = merged
		if seeding {
			continue
		}

		if kind := classify(known, previous, merged, w.minDelta); kind != "" {
			events = append(events, hooks.Event{
				Event:         kind,
				UserID:        userID,
				EpisodeUUID:   merged.EpisodeUUID,
				PodcastUUID:   merged.PodcastUUID,
				PlayedUpTo:    merged.PlayedUpTo,
				Duration:      merged.Duration,
				PlayingStatus: merged.PlayingStatus,
				At:            now,
			})
		}
	}

	if err := w.store.SaveEpisodeProgress(userID, toSave); err != nil {
		return err
	}
	if err := w.store.SetProgressCursor(userID, sync.LastModified); err != nil {
		return err
	}
	if seeding {
		w.logger.Info("progress watcher seeded", "user", userID, "episodes", len(toSave))
		return nil
	}
	if len(events) == 0 {
		return nil
	}
	// The seed only covers the episodes PC returns for a fresh sync (a few
	// thousand of a much larger account), so a bulk operation that touches old
	// episodes — a mass archive, a re-sync — can present hundreds of long-since
	// finished episodes as first sightings. Real listening never looks like
	// that, so a burst this size is dropped rather than replayed to hooks.
	if len(events) > maxEventsPerPoll {
		w.logger.Warn("progress: suppressing bulk change burst (not replayed to hooks)",
			"user", userID, "events", len(events), "limit", maxEventsPerPoll)
		return nil
	}

	w.logger.Info("progress changes", "user", userID, "events", len(events))
	for _, event := range events {
		w.enrich(ctx, &event)
		w.hooks.Fire(ctx, event)
	}
	return nil
}

// enrich adds the episode's title and enclosure URL from the public catalog —
// PC's sync records carry neither, and the URL is what lets a hook tell its
// own content apart from everything else.
func (w *ProgressWatcher) enrich(ctx context.Context, event *hooks.Event) {
	if event.PodcastUUID == "" {
		return
	}
	catalog, err := pc.FetchCatalog(ctx, event.PodcastUUID)
	if err != nil {
		w.logger.Debug("progress enrich: catalog", "podcast", event.PodcastUUID, "err", err)
		return
	}
	event.PodcastTitle = catalog.Title
	for _, episode := range catalog.Episodes {
		if episode.UUID == event.EpisodeUUID {
			event.EpisodeTitle = episode.Title
			event.EpisodeURL = episode.URL
			return
		}
	}
}

// classify decides what (if anything) changed enough to report.
func classify(known bool, previous, current store.EpisodeProgress, minDelta int64) string {
	if !known {
		// First sight: only worth reporting if it arrives already finished,
		// meaningfully played, or archived — an untouched new episode is not an
		// event. Archived first sights ARE events: an episode can be archived
		// without ever being played (that's still a deliberate act, and the
		// cursor-0 seed plus the bulk-burst cap already keep history quiet).
		switch {
		case current.Archived == 1:
			return hooks.EventArchived
		case current.PlayingStatus == pc.StatusCompleted:
			return hooks.EventCompleted
		case current.PlayedUpTo >= minDelta:
			return hooks.EventProgress
		}
		return ""
	}
	// Archiving is a deliberate act — report it even when the same sync also
	// carries a status change. Un-archiving alone is not an event.
	if current.Archived == 1 && previous.Archived != 1 {
		return hooks.EventArchived
	}
	if current.PlayingStatus == pc.StatusCompleted && previous.PlayingStatus != pc.StatusCompleted {
		return hooks.EventCompleted
	}
	if previous.PlayingStatus == pc.StatusCompleted && current.PlayingStatus != pc.StatusCompleted {
		return hooks.EventReopened
	}
	if abs(current.PlayedUpTo-previous.PlayedUpTo) >= minDelta {
		return hooks.EventProgress
	}
	return ""
}

func orPrevious(incoming, previous int64) int64 {
	if incoming == 0 {
		return previous
	}
	return incoming
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func abs(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}
