package api

import (
	"context"
	"errors"
	"net/http"
	"sync"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
)

var errNotLinked = errors.New("no Pocket Casts account linked")

// The query API (/api/v1) — read access to what the server mirrored from Pocket
// Casts, for scripts, Shortcuts and dashboards. Reads are served from the mirror;
// /pull refreshes it on demand (the nudge does the same automatically).

func (s *Server) handlePullMirror(w http.ResponseWriter, r *http.Request, userID int64) {
	if err := s.refreshMirror(r.Context(), userID); err != nil {
		s.logger.Error("mirror pull", "err", err)
		http.Error(w, "mirror pull failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	s.handleUpNext(w, r, userID)
}

func (s *Server) handleUpNext(w http.ResponseWriter, r *http.Request, userID int64) {
	payload, fetchedAt, err := s.store.Mirror(userID, "up_next")
	if err != nil {
		http.Error(w, "no mirrored queue yet — POST /api/v1/pull first", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Mirror-Fetched-At", fetchedAt)
	_, _ = w.Write(payload)
}

// refreshMirror pulls the linked account's state from Pocket Casts into the
// mirror. Called by /api/v1/pull and by the session nudge (the app telling us it
// just synced), which is what keeps the mirror near-real-time.
func (s *Server) refreshMirror(ctx context.Context, userID int64) error {
	link, linked, err := s.store.PCLink(userID)
	if err != nil {
		return err
	}
	if !linked {
		return errNotLinked
	}
	upNext, err := pc.FetchUpNext(ctx, link.AccessToken, "pcs-server")
	if err != nil {
		// The access token may have expired — renew via the refresh token and retry once.
		if link.RefreshToken == "" {
			return err
		}
		exchange, exErr := pc.ExchangeRefreshToken(ctx, link.RefreshToken, link.Scope)
		if exErr != nil {
			return err
		}
		link.AccessToken = exchange.AccessToken
		if exchange.RefreshToken != "" {
			link.RefreshToken = exchange.RefreshToken
		}
		if exchange.Email != "" {
			link.Email = exchange.Email
		}
		_ = s.store.SetPCLink(userID, link)
		upNext, err = pc.FetchUpNext(ctx, link.AccessToken, "pcs-server")
		if err != nil {
			return err
		}
	}
	if err := s.store.SaveMirror(userID, "up_next", upNext); err != nil {
		return err
	}
	// History and the podcast list are bigger and change more slowly; a failure
	// there must not lose the queue we just stored, so they only warn.
	if history, hErr := pc.FetchHistory(ctx, link.AccessToken); hErr == nil {
		if sErr := s.store.SaveMirror(userID, "history", history); sErr != nil {
			s.logger.Warn("mirror save (history)", "err", sErr)
		}
	} else {
		s.logger.Warn("mirror fetch (history)", "err", hErr)
	}
	if podcasts, pErr := pc.FetchPodcasts(ctx, link.AccessToken); pErr == nil {
		s.enrichPodcasts(ctx, &podcasts)
		if sErr := s.store.SaveMirror(userID, "podcasts", podcasts); sErr != nil {
			s.logger.Warn("mirror save (podcasts)", "err", sErr)
		}
	} else {
		s.logger.Warn("mirror fetch (podcasts)", "err", pErr)
	}
	return nil
}

// enrichPodcasts fills titles/authors: PC's sync list carries only uuids, so
// names come from the public catalog — fetched once per uuid, cached in
// podcast_meta. Failures leave the entry uuid-only (warn, never fail the pull).
func (s *Server) enrichPodcasts(ctx context.Context, list *pc.PodcastList) {
	cached, err := s.store.AllPodcastMeta()
	if err != nil {
		s.logger.Warn("podcast meta cache read", "err", err)
		cached = map[string][2]string{}
	}
	var missing []int
	for i := range list.Podcasts {
		if meta, ok := cached[list.Podcasts[i].UUID]; ok {
			list.Podcasts[i].Title = meta[0]
			list.Podcasts[i].Author = meta[1]
		} else {
			missing = append(missing, i)
		}
	}
	if len(missing) == 0 {
		return
	}

	// First pull resolves the whole library (~a few seconds); afterwards only
	// new subscriptions miss the cache.
	sem := make(chan struct{}, 6)
	var wg sync.WaitGroup
	var mu sync.Mutex
	for _, i := range missing {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			uuid := list.Podcasts[i].UUID
			catalog, err := pc.FetchCatalog(ctx, uuid)
			if err != nil || catalog.Title == "" {
				s.logger.Warn("podcast catalog lookup", "uuid", uuid, "err", err)
				return
			}
			mu.Lock()
			list.Podcasts[i].Title = catalog.Title
			list.Podcasts[i].Author = catalog.Author
			mu.Unlock()
			if err := s.store.SavePodcastMeta(uuid, catalog.Title, catalog.Author); err != nil {
				s.logger.Warn("podcast meta cache write", "uuid", uuid, "err", err)
			}
		}(i)
	}
	wg.Wait()
}

func (s *Server) handlePodcasts(w http.ResponseWriter, r *http.Request, userID int64) {
	payload, fetchedAt, err := s.store.Mirror(userID, "podcasts")
	if err != nil {
		http.Error(w, "no mirrored podcast list yet — POST /api/v1/pull first", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Mirror-Fetched-At", fetchedAt)
	_, _ = w.Write(payload)
}

func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request, userID int64) {
	payload, fetchedAt, err := s.store.Mirror(userID, "history")
	if err != nil {
		http.Error(w, "no mirrored history yet — POST /api/v1/pull first", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Mirror-Fetched-At", fetchedAt)
	_, _ = w.Write(payload)
}
