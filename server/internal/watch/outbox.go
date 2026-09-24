package watch

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/hooks"
	"github.com/mdbraber/pocket-sessions-server/internal/pc"
)

// Hook delivery. Polls queue events in the same transaction that advances
// the baseline (store.CommitProgressPoll); the dispatcher delivers them on
// its own context — never a poll's or a request's deadline — and retries a
// failure with exponential backoff, so an n8n restart or an expired OwnTube
// token delays events instead of losing them.

const (
	dispatchInterval = 30 * time.Second
	dispatchBatch    = 500
	retryBase        = 30 * time.Second
	retryMax         = time.Hour
	// 30 attempts at the capped backoff span roughly a day.
	maxDeliveryAttempts = 30
)

// Kick wakes the dispatcher (non-blocking).
func (w *ProgressWatcher) Kick() {
	select {
	case w.kick <- struct{}{}:
	default:
	}
}

// RunDispatcher delivers queued hook events until ctx ends.
func (w *ProgressWatcher) RunDispatcher(ctx context.Context) {
	if w.hooks == nil {
		return
	}
	ticker := time.NewTicker(dispatchInterval)
	defer ticker.Stop()
	for {
		w.dispatch(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-w.kick:
		}
	}
}

// dispatch makes one pass over the queue, oldest first. Events for one
// episode are delivered in order: once an episode's event is waiting for a
// retry, its later events wait too, so a stale "progress" can't overtake an
// "archived" still being retried.
func (w *ProgressWatcher) dispatch(ctx context.Context) {
	pending, err := w.store.PendingHookEvents(dispatchBatch)
	if err != nil {
		w.logger.Warn("hook queue: read", "err", err)
		return
	}
	now := time.Now()
	blocked := map[string]bool{}
	catalogs := map[string]pc.CatalogPodcast{}
	for _, queued := range pending {
		if ctx.Err() != nil {
			return
		}
		key := fmt.Sprintf("%d/%s", queued.UserID, queued.EpisodeUUID)
		if blocked[key] {
			continue
		}
		if queued.NextAttempt > now.Unix() {
			blocked[key] = true
			continue
		}
		var event hooks.Event
		if err := json.Unmarshal(queued.Payload, &event); err != nil {
			w.logger.Warn("hook queue: dropping unreadable event", "id", queued.ID, "err", err)
			_ = w.store.DeleteHookEvent(queued.ID)
			continue
		}

		err := w.enrich(ctx, &event, catalogs)
		if err == nil {
			err = w.hooks.Fire(ctx, event)
		}
		if ctx.Err() != nil {
			return // shutting down: leave it queued, untouched
		}
		if err == nil {
			if dErr := w.store.DeleteHookEvent(queued.ID); dErr != nil {
				w.logger.Warn("hook queue: delete", "id", queued.ID, "err", dErr)
			}
			continue
		}

		blocked[key] = true
		attempts := queued.Attempts + 1
		if attempts >= maxDeliveryAttempts {
			w.logger.Error("hook queue: giving up on event", "event", event.Event,
				"episode", event.EpisodeUUID, "attempts", attempts, "err", err)
			_ = w.store.DeleteHookEvent(queued.ID)
			continue
		}
		next := now.Add(retryDelay(attempts))
		w.logger.Warn("hook queue: delivery failed, will retry", "event", event.Event,
			"episode", event.EpisodeUUID, "attempt", attempts, "retryAt", next.Format(time.RFC3339), "err", err)
		if rErr := w.store.RescheduleHookEvent(queued.ID, attempts, next, err.Error()); rErr != nil {
			w.logger.Warn("hook queue: reschedule", "id", queued.ID, "err", rErr)
		}
	}
}

func retryDelay(attempts int) time.Duration {
	delay := retryBase
	for i := 1; i < attempts && delay < retryMax; i++ {
		delay *= 2
	}
	if delay > retryMax {
		delay = retryMax
	}
	return delay
}
