package watch

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
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

// How far behind the cursor each poll re-fetches (client-stamp tolerance).
const cursorOverlapMS = 10 * 60 * 1000

// ProgressWatcher polls one user's episode progress and fires hooks.
type ProgressWatcher struct {
	store  *store.Store
	hooks  *hooks.Runner
	logger *slog.Logger
	// Minimum playedUpTo movement (seconds) that counts as progress worth
	// reporting — without it a single listen would emit an event per sync.
	minDelta int64
	// Substring identifying first-party feed enclosures (PCS_FEED_MATCH) —
	// scopes burst exemption and replay to our own feeds rather than every
	// subscribed podcast the enclosure index knows.
	feedMatch string

	// One lock per user serialises everything that reads the baseline, talks
	// to PC and writes the baseline back: the ticker, nudge- and
	// relay-triggered polls, and playback write-through (WithUserLock).
	// Without it two overlapping polls both fire the same transition, and the
	// slower one can save an older baseline over a newer one.
	locksMu sync.Mutex
	locks   map[int64]*sync.Mutex

	// Wakes the delivery dispatcher when a poll queued events (outbox.go).
	kick chan struct{}
}

func NewProgressWatcher(st *store.Store, runner *hooks.Runner, logger *slog.Logger, minDelta int64, feedMatch string) *ProgressWatcher {
	if minDelta <= 0 {
		minDelta = 30
	}
	return &ProgressWatcher{
		store: st, hooks: runner, logger: logger, minDelta: minDelta, feedMatch: feedMatch,
		locks: map[int64]*sync.Mutex{}, kick: make(chan struct{}, 1),
	}
}

// WithUserLock runs fn while holding the user's poll lock (see locks).
func (w *ProgressWatcher) WithUserLock(userID int64, fn func() error) error {
	w.locksMu.Lock()
	lock, ok := w.locks[userID]
	if !ok {
		lock = &sync.Mutex{}
		w.locks[userID] = lock
	}
	w.locksMu.Unlock()
	lock.Lock()
	defer lock.Unlock()
	return fn()
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

// PollUser fetches changes since the stored cursor, queues hook events for
// material changes, and advances the cursor. The very first poll (cursor 0)
// returns the whole account, so it only seeds the baseline — replaying a
// lifetime of listening as "just completed" would be worse than useless.
func (w *ProgressWatcher) PollUser(ctx context.Context, userID int64) error {
	return w.WithUserLock(userID, func() error { return w.pollUser(ctx, userID) })
}

func (w *ProgressWatcher) pollUser(ctx context.Context, userID int64) error {
	link, linked, err := w.store.PCLink(userID)
	if err != nil || !linked {
		return err
	}
	cursor, err := w.store.ProgressCursor(userID)
	if err != nil {
		return err
	}

	// Fetch with an overlap window: sync records carry CLIENT-side modified
	// stamps, so an action taken minutes before the app synced can sit behind
	// an up-to-date cursor and be skipped forever (seen live 2026-07-31, the
	// relay's frequent polls made cursors too fresh). Re-fetching the last 10
	// minutes is free of double-fires — the baseline diff classifies known
	// state to no event.
	fetchFrom := cursor
	if fetchFrom > cursorOverlapMS {
		fetchFrom -= cursorOverlapMS
	}

	sync, err := pc.FetchProgress(ctx, link.AccessToken, "pcs-server", fetchFrom)
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
		sync, err = pc.FetchProgress(ctx, link.AccessToken, "pcs-server", fetchFrom)
	}
	if err != nil {
		return err
	}
	if len(sync.Episodes) == 0 {
		if err := w.store.UpsertReplicaRecords(userID, "poll", sync.Others); err != nil {
			w.logger.Warn("replica: poll records", "err", err)
		}
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
	toSave, events := w.diffEpisodes(userID, baseline, sync.Episodes, seeding)
	events = w.capBurst(userID, events)

	// Baseline, queued events and cursor commit together; delivery happens
	// in the dispatcher (outbox.go), off this poll's deadline and with retries.
	queued := w.outboxEvents(events)
	if err := w.store.CommitProgressPoll(userID, toSave, queued, sync.LastModified); err != nil {
		return err
	}
	// The replica rides along on every poll — same records, richer store.
	if err := w.store.UpsertReplicaEpisodes(userID, "poll", sync.Episodes); err != nil {
		w.logger.Warn("replica: poll episodes", "err", err)
	}
	if err := w.store.UpsertReplicaRecords(userID, "poll", sync.Others); err != nil {
		w.logger.Warn("replica: poll records", "err", err)
	}
	if seeding {
		w.logger.Info("progress watcher seeded", "user", userID, "episodes", len(toSave))
		return nil
	}
	if len(queued) > 0 {
		w.logger.Info("progress changes", "user", userID, "events", len(queued))
		w.Kick()
	}
	return nil
}

// diffEpisodes merges incoming records into the baseline and classifies each
// change. baseline is updated in place, so a record repeated within one batch
// compares against what was just derived rather than re-firing.
func (w *ProgressWatcher) diffEpisodes(userID int64, baseline map[string]store.EpisodeProgress, episodes []pc.EpisodeProgress, seeding bool) ([]store.EpisodeProgress, []hooks.Event) {
	var toSave []store.EpisodeProgress
	var events []hooks.Event
	now := time.Now().Unix()
	for _, incoming := range episodes {
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
			Reopened: previous.Reopened,
		}
		// An explicit 0 ("mark unplayed") is a real position, not an omission.
		if incoming.HasPlayedUpTo {
			merged.PlayedUpTo = incoming.PlayedUpTo
		}
		if incoming.Archived >= 0 {
			merged.Archived = incoming.Archived
		}
		kind := ""
		if !seeding {
			kind = classify(known, previous, merged, w.minDelta)
		}
		switch {
		case merged.PlayingStatus == pc.StatusCompleted:
			merged.Reopened = 0
		case kind == hooks.EventReopened:
			merged.Reopened = 1
		}
		toSave = append(toSave, merged)
		baseline[merged.EpisodeUUID] = merged

		if kind != "" {
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

	return toSave, events
}

// capBurst applies the bulk-burst cap. The seed only covers the episodes PC
// returns for a fresh sync (a few
// thousand of a much larger account), so a bulk operation that touches old
// episodes — a mass archive, a re-sync — can present hundreds of long-since
// finished episodes as first sightings. Real listening never looks like
// that, so a burst this size is mostly dropped rather than replayed —
// EXCEPT for first-party feed episodes (PCS_FEED_MATCH, looked up in the
// enclosure index): their hooks are idempotent and losing their events is
// exactly the outage-recovery gap, so they always deliver. A catch-up
// after downtime keeps its meaningful events; the mass-archive noise stays
// quiet. Without PCS_FEED_MATCH nothing is exempt — "every subscribed
// podcast" would make the cap meaningless.
func (w *ProgressWatcher) capBurst(userID int64, events []hooks.Event) []hooks.Event {
	if len(events) <= maxEventsPerPoll {
		return events
	}
	indexed := map[string]string{}
	if w.feedMatch != "" {
		var err error
		indexed, err = w.store.EnclosureEpisodes(userID, w.feedMatch)
		if err != nil {
			w.logger.Warn("progress: enclosure index for burst filter", "err", err)
			indexed = map[string]string{}
		}
	}
	var kept []hooks.Event
	for _, event := range events {
		if _, ok := indexed[event.EpisodeUUID]; ok {
			kept = append(kept, event)
		}
	}
	w.logger.Warn("progress: bulk burst — delivering only feed-episode events",
		"user", userID, "events", len(events), "kept", len(kept), "limit", maxEventsPerPoll)
	return kept
}

// ObserveAppRecords classifies the app's OWN outgoing sync records, seen by
// the /pcapi relay before Pocket Casts has them. PC filters polls by the
// records' client-side modified stamps, so an action taken offline and synced
// much later sits behind the cursor (and its overlap window) and a poll never
// returns it; the app's upload is the only place it is certain to appear.
// Events are queued exactly as a poll queues them; the cursor is untouched.
func (w *ProgressWatcher) ObserveAppRecords(userID int64, episodes []pc.EpisodeProgress) error {
	if len(episodes) == 0 {
		return nil
	}
	return w.WithUserLock(userID, func() error {
		cursor, err := w.store.ProgressCursor(userID)
		if err != nil || cursor == 0 {
			return err // not seeded yet: the first poll will seed
		}
		baseline, err := w.store.AllEpisodeProgress(userID)
		if err != nil {
			return err
		}
		toSave, events := w.diffEpisodes(userID, baseline, episodes, false)
		queued := w.outboxEvents(w.capBurst(userID, events))
		if err := w.store.CommitProgressPoll(userID, toSave, queued, 0); err != nil {
			return err
		}
		if len(queued) > 0 {
			w.logger.Info("progress changes (app upload)", "user", userID, "events", len(queued))
			w.Kick()
		}
		return nil
	})
}

// outboxEvents serialises events for the delivery queue. Nothing is queued
// when no hooks or webhooks are configured — the queue would only grow.
func (w *ProgressWatcher) outboxEvents(events []hooks.Event) []store.OutboxEvent {
	if w.hooks == nil {
		return nil
	}
	out := make([]store.OutboxEvent, 0, len(events))
	for _, event := range events {
		payload, err := json.Marshal(event)
		if err != nil {
			continue
		}
		out = append(out, store.OutboxEvent{UserID: event.UserID, EpisodeUUID: event.EpisodeUUID, Payload: payload})
	}
	return out
}

// enrich adds the episode's title and enclosure URL from the public catalog —
// PC's sync records carry neither, and the URL is what lets a hook tell its
// own content apart from everything else. Catalogs are cached per dispatch
// round (a replay sweep would otherwise download one feed hundreds of
// times); the enclosure index is the fallback for the URL. The error is only
// returned when the URL is still unknown and the catalog could not be read,
// which is worth a retry.
func (w *ProgressWatcher) enrich(ctx context.Context, event *hooks.Event, catalogs map[string]pc.CatalogPodcast) error {
	var fetchErr error
	if event.PodcastUUID != "" {
		catalog, ok := catalogs[event.PodcastUUID]
		if !ok {
			var err error
			catalog, err = pc.FetchCatalog(ctx, event.PodcastUUID)
			if err != nil {
				w.logger.Debug("progress enrich: catalog", "podcast", event.PodcastUUID, "err", err)
				fetchErr = err
			} else {
				catalogs[event.PodcastUUID] = catalog
				ok = true
			}
		}
		if ok {
			event.PodcastTitle = catalog.Title
			for _, episode := range catalog.Episodes {
				if episode.UUID == event.EpisodeUUID {
					event.EpisodeTitle = episode.Title
					event.EpisodeURL = episode.URL
					break
				}
			}
		}
	}
	if event.EpisodeURL == "" {
		if url, err := w.store.EnclosureURL(event.UserID, event.EpisodeUUID); err == nil {
			event.EpisodeURL = url
		}
	}
	if event.EpisodeURL == "" && fetchErr != nil {
		return fetchErr
	}
	return nil
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

// ReplayIndexed queues the CURRENT replica state of every first-party feed
// episode as one synthetic hook event each — the recovery tool for events
// lost to downtime (the reverse of suppression: nothing here depends on a
// transition, so it is safe to run any time; hooks are idempotent, and
// sticky completion on the receiving side makes over-delivery harmless).
// Archived beats completed beats progress, mirroring classify's ranking.
// Delivery runs through the queue, so this returns as soon as the events are
// queued and a slow sweep can't be cut short by the caller disconnecting.
func (w *ProgressWatcher) ReplayIndexed(ctx context.Context, userID int64) (int, error) {
	if w.hooks == nil {
		return 0, nil
	}
	states, err := w.store.ReplicaIndexedEpisodes(userID, w.feedMatch)
	if err != nil {
		return 0, err
	}
	now := time.Now().Unix()
	var events []hooks.Event
	for _, st := range states {
		var kind string
		switch {
		case st.Archived == 1:
			kind = hooks.EventArchived
		case st.PlayingStatus == pc.StatusCompleted:
			kind = hooks.EventCompleted
		case st.PlayedUpTo > 0:
			kind = hooks.EventProgress
		default:
			continue
		}
		events = append(events, hooks.Event{
			Event:         kind,
			UserID:        userID,
			EpisodeUUID:   st.EpisodeUUID,
			PodcastUUID:   st.PodcastUUID,
			PlayedUpTo:    st.PlayedUpTo,
			Duration:      st.Duration,
			PlayingStatus: st.PlayingStatus,
			At:            now,
		})
	}
	if err := w.store.EnqueueHookEvents(userID, w.outboxEvents(events)); err != nil {
		return 0, err
	}
	w.Kick()
	w.logger.Info("replay: indexed episodes queued", "user", userID, "events", len(events))
	return len(events), nil
}
