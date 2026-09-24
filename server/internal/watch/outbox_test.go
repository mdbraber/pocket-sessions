package watch

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/hooks"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

// A failed delivery stays queued and is retried; while it waits, later events
// for the same episode wait behind it, and other episodes are unaffected.
func TestDispatchRetriesInOrder(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })

	var mu sync.Mutex
	failArchived := true
	var delivered []string
	sink := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var event hooks.Event
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &event)
		mu.Lock()
		defer mu.Unlock()
		if event.Event == hooks.EventArchived && failArchived {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		delivered = append(delivered, event.EpisodeUUID+":"+event.Event)
	}))
	defer sink.Close()

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	runner := hooks.New("", time.Second, logger, []string{sink.URL}, "")
	w := NewProgressWatcher(st, runner, logger, 30, "")

	queue := w.outboxEvents([]hooks.Event{
		{Event: hooks.EventArchived, UserID: 1, EpisodeUUID: "e1"},
		{Event: hooks.EventProgress, UserID: 1, EpisodeUUID: "e1"},
		{Event: hooks.EventCompleted, UserID: 1, EpisodeUUID: "e2"},
	})
	if err := st.EnqueueHookEvents(1, queue); err != nil {
		t.Fatal(err)
	}

	w.dispatch(context.Background())
	if got := delivered; len(got) != 1 || got[0] != "e2:completed" {
		t.Fatalf("first pass delivered %v, want only e2:completed", got)
	}
	pending, _ := st.PendingHookEvents(10)
	if len(pending) != 2 || pending[0].Attempts != 1 || pending[1].Attempts != 0 {
		t.Fatalf("pending after failure = %+v, want e1's two events, the first with one attempt", pending)
	}

	// Not due yet: nothing moves, even though the receiver is back.
	mu.Lock()
	failArchived = false
	mu.Unlock()
	w.dispatch(context.Background())
	if len(delivered) != 1 {
		t.Fatalf("delivered before the retry was due: %v", delivered)
	}

	// Due: both e1 events go out, in their original order.
	if err := st.RescheduleHookEvent(pending[0].ID, 1, time.Now().Add(-time.Second), ""); err != nil {
		t.Fatal(err)
	}
	w.dispatch(context.Background())
	want := []string{"e2:completed", "e1:archived", "e1:progress"}
	if len(delivered) != len(want) {
		t.Fatalf("delivered %v, want %v", delivered, want)
	}
	for i := range want {
		if delivered[i] != want[i] {
			t.Fatalf("delivered %v, want %v", delivered, want)
		}
	}
	if pending, _ := st.PendingHookEvents(10); len(pending) != 0 {
		t.Fatalf("queue not drained: %+v", pending)
	}
}

func TestRetryDelay(t *testing.T) {
	if got := retryDelay(1); got != 30*time.Second {
		t.Errorf("retryDelay(1) = %v, want 30s", got)
	}
	if got := retryDelay(3); got != 2*time.Minute {
		t.Errorf("retryDelay(3) = %v, want 2m", got)
	}
	if got := retryDelay(20); got != time.Hour {
		t.Errorf("retryDelay(20) = %v, want the 1h cap", got)
	}
}
