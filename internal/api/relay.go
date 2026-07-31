package api

import (
	"bytes"
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

// observeRelay parses a copy of the exchange into the replica. Best effort:
// every failure is logged and swallowed.
func (s *Server) observeRelay(userID int64, path string, reqBody, respBody []byte) {
	defer func() {
		if r := recover(); r != nil {
			s.logger.Warn("relay observe panic", "path", path, "recover", r)
		}
	}()
	switch path {
	case "/user/sync/update":
		// The request carries the app's OUTGOING records — actions are visible
		// here the moment the app syncs, before any poll.
		if reqSync, err := pc.ParseSyncRequestRecords(reqBody); err == nil {
			s.feedReplica(userID, "relay-req", reqSync)
		}
		if respSync, err := pc.ParseProgressResponseExported(respBody); err == nil {
			s.feedReplica(userID, "relay-resp", respSync)
		}
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
	}
}

// triggerRelayPoll runs the watcher for this user, debounced: one sync
// session can hit /user/sync/update several times in a burst, and one poll
// covers them all.
func (s *Server) triggerRelayPoll(userID int64) {
	if s.progress == nil {
		return
	}
	s.relayPollMu.Lock()
	last := s.relayPollLast[userID]
	now := time.Now()
	if now.Sub(last) < 5*time.Second {
		s.relayPollMu.Unlock()
		return
	}
	if s.relayPollLast == nil {
		s.relayPollLast = map[int64]time.Time{}
	}
	s.relayPollLast[userID] = now
	s.relayPollMu.Unlock()

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
