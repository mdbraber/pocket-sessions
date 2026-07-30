// Package watch is the new-episode watcher: PC's own episode pushes can never
// reach this fork (APNs delivery is keyed to the bundle id, and PC only signs
// for theirs), so the server polls the public catalog for every subscription,
// diffs against the seen_episodes ledger, and pushes — a silent wake so devices
// refresh, plus visible alerts for podcasts whose synced notification toggle
// is on.
package watch

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
	"github.com/mdbraber/pocket-sessions-server/internal/push"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

const (
	concurrency          = 6
	maxAlertsPerFeed     = 3                  // a feed glitch must not become a notification storm
	alertFreshnessWindow = 7 * 24 * time.Hour // never alert for back-catalog episodes
)

// Run polls until ctx ends. notifyMode: "synced" (per-podcast toggle), "all",
// or "off" (silent wakes only).
func Run(ctx context.Context, st *store.Store, pusher push.Pusher, logger *slog.Logger, interval time.Duration, notifyMode string) {
	logger.Info("episode watcher running", "interval", interval, "notify", notifyMode)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		cycle(ctx, st, pusher, logger, notifyMode)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func cycle(ctx context.Context, st *store.Store, pusher push.Pusher, logger *slog.Logger, notifyMode string) {
	userIDs, err := st.LinkedUserIDs()
	if err != nil {
		logger.Warn("watcher: linked users", "err", err)
		return
	}
	for _, userID := range userIDs {
		if err := cycleUser(ctx, st, pusher, logger, notifyMode, userID); err != nil {
			logger.Warn("watcher cycle", "user", userID, "err", err)
		}
	}
}

func cycleUser(ctx context.Context, st *store.Store, pusher push.Pusher, logger *slog.Logger, notifyMode string, userID int64) error {
	link, linked, err := st.PCLink(userID)
	if err != nil || !linked {
		return err
	}

	list, err := pc.FetchPodcasts(ctx, link.AccessToken)
	if err != nil && link.RefreshToken != "" {
		// Access token expired — renew on the lineage's own scope and retry once.
		exchange, exErr := pc.ExchangeRefreshToken(ctx, link.RefreshToken, link.Scope)
		if exErr != nil {
			return err
		}
		link.AccessToken = exchange.AccessToken
		if exchange.RefreshToken != "" {
			link.RefreshToken = exchange.RefreshToken
		}
		_ = st.SetPCLink(userID, link)
		list, err = pc.FetchPodcasts(ctx, link.AccessToken)
	}
	if err != nil {
		return err
	}

	seenEpisodes, seededPodcasts, err := st.SeenEpisodes(userID)
	if err != nil {
		return err
	}
	// "synced" alerts on either signal: PC's synced per-podcast setting (empty
	// on accounts that never ran settings-sync) or the toggles the app reports
	// through /session/v1/notify-podcasts.
	appToggles, err := st.NotifyPodcastUUIDs(userID)
	if err != nil {
		return err
	}

	type feedResult struct {
		podcast pc.Podcast
		fresh   []pc.CatalogEpisode // unseen, newest feed entries
		seeded  bool                // first sight of this podcast: seed silently
		title   string
	}
	sem := make(chan struct{}, concurrency)
	var wg sync.WaitGroup
	var mu sync.Mutex
	var results []feedResult
	for _, podcast := range list.Podcasts {
		wg.Add(1)
		go func(podcast pc.Podcast) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			catalog, err := pc.FetchCatalog(ctx, podcast.UUID)
			if err != nil {
				logger.Warn("watcher: catalog", "uuid", podcast.UUID, "err", err)
				return
			}
			res := feedResult{podcast: podcast, seeded: !seededPodcasts[podcast.UUID], title: catalog.Title}
			for _, ep := range catalog.Episodes {
				if !seenEpisodes[ep.UUID] {
					res.fresh = append(res.fresh, ep)
				}
			}
			if len(res.fresh) > 0 {
				mu.Lock()
				results = append(results, res)
				mu.Unlock()
			}
		}(podcast)
	}
	wg.Wait()

	var alerts []push.EpisodeAlert
	// Every fresh episode, alert-worthy or not: recovery repairs the app's DATA, so it is not
	// gated on notification settings the way `alerts` is.
	var recovery []push.EpisodeRef
	newCount := 0
	for _, res := range results {
		uuids := make([]string, 0, len(res.fresh))
		for _, ep := range res.fresh {
			uuids = append(uuids, ep.UUID)
		}
		if err := st.MarkEpisodesSeen(userID, res.podcast.UUID, uuids); err != nil {
			logger.Warn("watcher: mark seen", "err", err)
			continue // do NOT alert what we couldn't record — it would repeat forever
		}
		if res.seeded {
			continue // first sight of this podcast: current episodes are old news
		}
		newCount += len(res.fresh)
		for _, ep := range res.fresh {
			// Same freshness bound as the alerts: a back-catalog episode surfacing is not a
			// delivery the app can have missed, so there is nothing to recover.
			if time.Since(ep.Published) > alertFreshnessWindow {
				continue
			}
			recovery = append(recovery, push.EpisodeRef{PodcastUUID: res.podcast.UUID, EpisodeUUID: ep.UUID})
		}

		notify := notifyMode == "all" || (notifyMode == "synced" && (res.podcast.NotifyEnabled || appToggles[res.podcast.UUID]))
		if !notify {
			continue
		}
		count := 0
		for _, ep := range res.fresh {
			if time.Since(ep.Published) > alertFreshnessWindow || count >= maxAlertsPerFeed {
				continue
			}
			title := res.podcast.Title
			if title == "" {
				title = res.title
			}
			alerts = append(alerts, push.EpisodeAlert{
				PodcastUUID:  res.podcast.UUID,
				PodcastTitle: title,
				EpisodeUUID:  ep.UUID,
				EpisodeTitle: ep.Title,
			})
			count++
		}
	}

	if newCount == 0 && len(alerts) == 0 {
		return nil
	}
	devices, err := st.DevicesExcept(userID, "") // no originator — everyone gets woken
	if err != nil {
		return err
	}
	logger.Info("watcher: new episodes", "user", userID, "episodes", newCount, "alerts", len(alerts))
	// Silent wake first: EVERY device refreshes so the Inbox fills, whatever each one has
	// chosen about visible alerts. The cursor value is unused by the handler.
	pusher.NotifyChanged(userID, 0, devices)
	// Then the silent recovery signal, to EVERY device: it carries the uuids the visible alert
	// carries but cannot deliver in the background, and it repairs data rather than notifying,
	// so the per-device "New Episodes" switch does not apply to it.
	pusher.NotifyEpisodeRecovery(userID, recovery, devices)
	if len(alerts) > 0 {
		// The "New Episodes" switch is per device — turning it off on one silences that one
		// and says nothing about the others, so the ALERT fan-out is filtered while the
		// silent wake above is not.
		alertDevices, err := st.NotifyEnabledDevices(userID, devices)
		if err != nil {
			logger.Warn("watcher: notify settings", "err", err)
			alertDevices = devices
		}
		if len(alertDevices) > 0 {
			pusher.NotifyNewEpisodes(userID, alerts, alertDevices)
		}
	}
	return nil
}
