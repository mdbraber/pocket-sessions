package api

import (
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
)

// The Pocket Casts API relay: the fork points its PC API base at
// /pcapi/... and PCS forwards the bytes untouched to api.pocketcasts.com,
// parsing a COPY of the interesting exchanges into the replica. This is the
// push path of the sync architecture: the app's own traffic is the event
// stream, no polling involved. Observation only — routing decisions, hooks
// and the watcher are unaffected (a parse failure can never corrupt the
// passthrough).
//
// Auth: the Authorization header is the app's own PC token and passes
// through verbatim. The relay itself is gated by X-PCS-Proxy-Token (a PCS
// device/operator token) so this is not an open proxy.

// Overridable for tests.
var relayUpstream = "https://api.pocketcasts.com"

const relayBodyCap = 64 << 20

// Hop-by-hop headers that must not be forwarded either way.
var hopHeaders = []string{
	"Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization",
	"Te", "Trailer", "Transfer-Encoding", "Upgrade",
}

func (s *Server) handleRelay(w http.ResponseWriter, r *http.Request) {
	token := r.Header.Get("X-PCS-Proxy-Token")
	userID := int64(0)
	if token != "" {
		if id, err := s.store.UserForToken(token); err == nil {
			userID = id
		}
	}
	if userID == 0 {
		// Loud on purpose: a misconfigured client shows up here, and silence
		// here plus silence at Caddy means traffic never arrived at all.
		s.logger.Warn("relay: unauthorized", "path", r.URL.Path, "hasToken", token != "")
		http.Error(w, "relay unauthorized", http.StatusUnauthorized)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/pcapi")
	if path == "" || path[0] != '/' {
		http.Error(w, "bad path", http.StatusBadRequest)
		return
	}

	reqBody, err := io.ReadAll(io.LimitReader(r.Body, relayBodyCap))
	if err != nil {
		http.Error(w, "request read failed", http.StatusBadRequest)
		return
	}

	upstreamURL := relayUpstream + path
	if r.URL.RawQuery != "" {
		upstreamURL += "?" + r.URL.RawQuery
	}
	upReq, err := http.NewRequestWithContext(r.Context(), r.Method, upstreamURL, bytes.NewReader(reqBody))
	if err != nil {
		http.Error(w, "relay build failed", http.StatusInternalServerError)
		return
	}
	upReq.Header = r.Header.Clone()
	upReq.Header.Del("X-PCS-Proxy-Token")
	// Forwarding the app's Accept-Encoding makes Go's transport hand back the
	// COMPRESSED body (it only auto-decompresses when it added the header
	// itself) — which is exactly how the observer ended up parsing gzip bytes
	// to zero records while the app decompressed the same bytes happily.
	// Dropping it lets the transport negotiate and transparently decompress;
	// the app receives plain bytes, which every client accepts.
	upReq.Header.Del("Accept-Encoding")
	for _, h := range hopHeaders {
		upReq.Header.Del(h)
	}
	upReq.Host = ""

	client := &http.Client{Timeout: 90 * time.Second}
	resp, err := client.Do(upReq)
	if err != nil {
		http.Error(w, "upstream unreachable: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, relayBodyCap))
	if err != nil {
		http.Error(w, "upstream read failed", http.StatusBadGateway)
		return
	}

	header := w.Header()
	for k, vs := range resp.Header {
		if isHopHeader(k) {
			continue
		}
		for _, v := range vs {
			header.Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(respBody)

	s.logger.Info("relay", "path", path, "status", resp.StatusCode,
		"reqBytes", len(reqBody), "respBytes", len(respBody))

	// Observation happens after the response is on the wire, off the hot path.
	if resp.StatusCode == http.StatusOK {
		go s.observeRelay(userID, path, reqBody, respBody)
	}
}

func isHopHeader(name string) bool {
	for _, h := range hopHeaders {
		if strings.EqualFold(h, name) {
			return true
		}
	}
	return false
}

// maybeGunzip transparently unpacks a gzip body (magic 1f 8b) so observation
// never parses compressed bytes, wherever they slipped through.
func maybeGunzip(body []byte) []byte {
	if len(body) < 2 || body[0] != 0x1f || body[1] != 0x8b {
		return body
	}
	zr, err := gzip.NewReader(bytes.NewReader(body))
	if err != nil {
		return body
	}
	defer zr.Close()
	plain, err := io.ReadAll(io.LimitReader(zr, relayBodyCap))
	if err != nil {
		return body
	}
	return plain
}

// observeRelay parses a copy of the exchange into the replica. Best effort:
// every failure is logged and swallowed.
func (s *Server) observeRelay(userID int64, path string, reqBody, respBody []byte) {
	defer func() {
		if r := recover(); r != nil {
			s.logger.Warn("relay observe panic", "path", path, "recover", r)
		}
	}()
	reqBody = maybeGunzip(reqBody)
	respBody = maybeGunzip(respBody)
	switch path {
	case "/user/sync/update":
		// The request carries the app's OUTGOING records — actions are visible
		// here the moment the app syncs, before any poll.
		reqSync, reqErr := pc.ParseSyncRequestRecords(reqBody)
		if reqErr == nil {
			s.feedReplica(userID, "relay-req", reqSync)
		}
		respSync, respErr := pc.ParseProgressResponseExported(respBody)
		if respErr == nil {
			s.feedReplica(userID, "relay-resp", respSync)
		}
		// Diagnosis breadcrumb: live app bodies were observed parsing to zero
		// records while synthetic ones parse fine — keep the outcome visible.
		s.logger.Info("relay observe sync",
			"reqEpisodes", len(reqSync.Episodes), "reqOthers", len(reqSync.Others), "reqErr", reqErr != nil,
			"respEpisodes", len(respSync.Episodes), "respOthers", len(respSync.Others), "respErr", respErr != nil)
		// A sync through the relay is the perfect hook trigger: the app just
		// wrote its changes (or fetched other devices'), so poll PC now and
		// let hooks fire in seconds — the 15m tick becomes pure backstop.
		s.triggerRelayPoll(userID)
	case "/history/sync":
		if history, err := pc.ParseHistoryResponse(respBody); err == nil {
			if err := s.store.UpsertHistoryLedger(userID, history.Entries); err != nil {
				s.logger.Warn("relay: ledger", "err", err)
			}
		}
	case "/user/podcast/episodes":
		podcastUUID := pc.ParseUUIDRequest(reqBody)
		if episodes, err := pc.ParseSyncEpisodesResponse(respBody, podcastUUID); err == nil {
			if err := s.store.UpsertReplicaEpisodes(userID, "relay-resp", episodes); err != nil {
				s.logger.Warn("relay: episodes", "err", err)
			}
		}
	case "/sync/update_episode":
		// The app's immediate position sync for the playing episode — the
		// hottest signal there is.
		if episode, err := pc.ParseUpdateEpisodeRequest(reqBody); err == nil && episode.EpisodeUUID != "" {
			if err := s.store.UpsertReplicaEpisodes(userID, "relay-req", []pc.EpisodeProgress{episode}); err != nil {
				s.logger.Warn("relay: update_episode", "err", err)
			}
		}
		s.triggerRelayPoll(userID)
	default:
		// Any other /sync/* endpoint (star, archive variants, …) still means
		// "episode state just changed" — poll so hooks fire, even without a
		// dedicated parser.
		if strings.HasPrefix(path, "/sync/") {
			s.triggerRelayPoll(userID)
		}
	}
}

// triggerRelayPoll runs the watcher for this user with a leading AND a
// trailing edge: poll immediately on the first sync of a session (fast hooks
// for single-action syncs), then once more after the session goes quiet — a
// sync session is several requests over seconds, and polling only at its
// START races the batches that carry the actual changes (seen live
// 2026-07-31: a mark-played in a later batch was skipped for good).
func (s *Server) triggerRelayPoll(userID int64) {
	if s.progress == nil {
		return
	}
	const quiet = 6 * time.Second

	s.relayPollMu.Lock()
	if s.relayPollLast == nil {
		s.relayPollLast = map[int64]time.Time{}
	}
	if s.relayTriggerLast == nil {
		s.relayTriggerLast = map[int64]time.Time{}
	}
	if s.relayPollPending == nil {
		s.relayPollPending = map[int64]bool{}
	}
	now := time.Now()
	s.relayTriggerLast[userID] = now
	leading := now.Sub(s.relayPollLast[userID]) >= quiet
	if leading {
		s.relayPollLast[userID] = now
	}
	scheduleTrailing := !s.relayPollPending[userID]
	if scheduleTrailing {
		s.relayPollPending[userID] = true
	}
	s.relayPollMu.Unlock()

	if leading {
		s.runRelayPoll(userID)
	}
	if scheduleTrailing {
		go func() {
			for {
				time.Sleep(quiet)
				s.relayPollMu.Lock()
				quietFor := time.Since(s.relayTriggerLast[userID])
				if quietFor >= quiet {
					s.relayPollPending[userID] = false
					s.relayPollMu.Unlock()
					break
				}
				s.relayPollMu.Unlock()
			}
			s.runRelayPoll(userID)
		}()
	}
}

func (s *Server) runRelayPoll(userID int64) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if err := s.progress.PollUser(ctx, userID); err != nil {
		s.logger.Warn("relay-triggered poll", "user", userID, "err", err)
	}
}

func (s *Server) feedReplica(userID int64, source string, sync pc.ProgressSync) {
	if err := s.store.UpsertReplicaEpisodes(userID, source, sync.Episodes); err != nil {
		s.logger.Warn("relay: replica episodes", "source", source, "err", err)
	}
	if err := s.store.UpsertReplicaRecords(userID, source, sync.Others); err != nil {
		s.logger.Warn("relay: replica records", "source", source, "err", err)
	}
}
