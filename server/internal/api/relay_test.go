package api

import (
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

func relayTestServer(t *testing.T) (*Server, *store.Store) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.EnsureBootstrapUser("tok-relay"); err != nil {
		t.Fatal(err)
	}
	return &Server{store: st, logger: slog.Default()}, st
}

// The relay must gate on X-PCS-Proxy-Token, forward bytes untouched, and
// observe /user/sync/update request records into the replica.
func TestRelayGateForwardObserve(t *testing.T) {
	var upstreamSaw []byte
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamSaw, _ = io.ReadAll(r.Body)
		if r.Header.Get("X-PCS-Proxy-Token") != "" {
			t.Error("proxy token leaked upstream")
		}
		if r.Header.Get("Authorization") != "Bearer pc-token" {
			t.Errorf("authorization not forwarded: %q", r.Header.Get("Authorization"))
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write([]byte("upstream-response"))
	}))
	defer upstream.Close()
	oldUpstream := relayUpstream
	relayUpstream = upstream.URL
	defer func() { relayUpstream = oldUpstream }()

	s, st := relayTestServer(t)

	// A real SyncUpdateRequest body with one episode record attached.
	body := pc.BuildProgressPushForTest("dev", pc.EpisodeProgress{
		EpisodeUUID: "ep-1", PodcastUUID: "pod-1",
		PlayedUpTo: 77, PlayingStatus: 2, Duration: 500,
	}, 1_700_000_000_000, 9)

	// No proxy token → 401, nothing forwarded.
	req := httptest.NewRequest(http.MethodPost, "/pcapi/user/sync/update", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	s.handleRelay(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("no token: status %d", rec.Code)
	}

	// Valid token → forwarded verbatim, response relayed, records observed.
	req = httptest.NewRequest(http.MethodPost, "/pcapi/user/sync/update", bytes.NewReader(body))
	req.Header.Set("X-PCS-Proxy-Token", "tok-relay")
	req.Header.Set("Authorization", "Bearer pc-token")
	rec = httptest.NewRecorder()
	s.handleRelay(rec, req)
	if rec.Code != http.StatusOK || rec.Body.String() != "upstream-response" {
		t.Fatalf("relay: status %d body %q", rec.Code, rec.Body.String())
	}
	if !bytes.Equal(upstreamSaw, body) {
		t.Error("request bytes not forwarded verbatim")
	}

	// Observation is async; poll briefly for the replica row.
	deadline := time.Now().Add(2 * time.Second)
	for {
		status, err := st.ReplicaStatus(1)
		if err != nil {
			t.Fatal(err)
		}
		if status.Episodes == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("replica not fed from relay request: %+v", status)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

type pollRecorder struct {
	mu    sync.Mutex
	calls int
}

func (p *pollRecorder) PollUser(ctx context.Context, userID int64) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.calls++
	return nil
}

func (p *pollRecorder) ReplayIndexed(ctx context.Context, userID int64) (int, error) {
	return 0, nil
}

func (p *pollRecorder) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.calls
}

// A relayed sync must trigger exactly one watcher poll per debounce window —
// that's what makes hooks push-driven when the app routes through the relay.
func TestRelayTriggersDebouncedPoll(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()
	oldUpstream := relayUpstream
	relayUpstream = upstream.URL
	defer func() { relayUpstream = oldUpstream }()

	s, _ := relayTestServer(t)
	poller := &pollRecorder{}
	s.progress = poller

	for range 3 {
		req := httptest.NewRequest(http.MethodPost, "/pcapi/user/sync/update", bytes.NewReader(nil))
		req.Header.Set("X-PCS-Proxy-Token", "tok-relay")
		rec := httptest.NewRecorder()
		s.handleRelay(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("relay status %d", rec.Code)
		}
	}

	deadline := time.Now().Add(2 * time.Second)
	for poller.count() == 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	// The leading edge fires once, immediately.
	if got := poller.count(); got != 1 {
		t.Fatalf("leading polls = %d, want 1", got)
	}
	// After the session goes quiet, the trailing sweep fires exactly once —
	// three rapid syncs total two polls, and the trailing one is what sees
	// the batches the leading poll raced.
	deadline = time.Now().Add(9 * time.Second)
	for poller.count() < 2 && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if got := poller.count(); got != 2 {
		t.Errorf("total polls = %d, want 2 (leading + trailing)", got)
	}
}

// The passthrough must stay compressed for the client while observation
// parses plain: an upstream gzip response reaches the app byte-identical
// (with its Content-Encoding header) AND lands in the replica decoded.
func TestRelayCompressedPassthroughPlainObservation(t *testing.T) {
	// A minimal SyncUpdateResponse: {1: lastModified, 2: Record{2: SyncUserEpisode{1: uuid}}}
	episode := []byte{0x0a, 0x05, 'e', 'p', '-', 'g', 'z'} // field1 uuid "ep-gz"
	record := append([]byte{0x12, byte(len(episode))}, episode...)
	plain := append([]byte{0x08, 0x2a}, append([]byte{0x12, byte(len(record))}, record...)...)

	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	if _, err := zw.Write(plain); err != nil {
		t.Fatal(err)
	}
	zw.Close()

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept-Encoding") != "gzip" {
			t.Errorf("upstream negotiation not constrained to gzip: %q", r.Header.Get("Accept-Encoding"))
		}
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write(gz.Bytes())
	}))
	defer upstream.Close()
	oldUpstream := relayUpstream
	relayUpstream = upstream.URL
	defer func() { relayUpstream = oldUpstream }()

	s, st := relayTestServer(t)

	req := httptest.NewRequest(http.MethodPost, "/pcapi/user/sync/update", bytes.NewReader(nil))
	req.Header.Set("X-PCS-Proxy-Token", "tok-relay")
	req.Header.Set("Accept-Encoding", "gzip, deflate, br")
	rec := httptest.NewRecorder()
	s.handleRelay(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	if rec.Header().Get("Content-Encoding") != "gzip" {
		t.Error("Content-Encoding not forwarded to client")
	}
	if !bytes.Equal(rec.Body.Bytes(), gz.Bytes()) {
		t.Error("compressed body not byte-identical through the relay")
	}

	deadline := time.Now().Add(2 * time.Second)
	for {
		if found, _ := st.ReplicaEpisode(1, "ep-gz"); found {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("gzip response was not observed into the replica")
		}
		time.Sleep(20 * time.Millisecond)
	}
}
