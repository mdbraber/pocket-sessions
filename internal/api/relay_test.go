package api

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
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
