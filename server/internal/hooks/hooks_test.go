package hooks

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeScript(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

var discard = slog.New(slog.NewTextHandler(io.Discard, nil))

// Hooks see their own credentials but not the server's PCS_* configuration.
func TestHookEnvironmentExcludesServerSecrets(t *testing.T) {
	t.Setenv("PCS_AUTH_TOKEN", "operator-secret")
	t.Setenv("OWNTUBE_TOKEN", "hook-credential")
	dir := t.TempDir()
	writeScript(t, dir, "check", `[ -z "$PCS_AUTH_TOKEN" ] && [ "$OWNTUBE_TOKEN" = hook-credential ] && [ "$PCS_EVENT" = completed ]`)
	runner := New(dir, 5*time.Second, discard, nil, "")
	if err := runner.Fire(context.Background(), Event{Event: EventCompleted}); err != nil {
		t.Fatalf("Fire = %v, want nil", err)
	}
}

// A failing hook is reported to the caller, so the event can be retried.
func TestFireReportsFailures(t *testing.T) {
	dir := t.TempDir()
	writeScript(t, dir, "fail", "exit 1")
	runner := New(dir, 5*time.Second, discard, nil, "")
	if err := runner.Fire(context.Background(), Event{Event: EventProgress}); err == nil {
		t.Fatal("Fire = nil, want the hook's failure")
	}
}

// A timed-out hook whose child still holds its output open must not block
// Fire for as long as the child runs.
func TestTimeoutDoesNotWaitForChildren(t *testing.T) {
	dir := t.TempDir()
	writeScript(t, dir, "slow", "sleep 20 & wait")
	runner := New(dir, 500*time.Millisecond, discard, nil, "")
	start := time.Now()
	if err := runner.Fire(context.Background(), Event{Event: EventProgress}); err == nil {
		t.Fatal("Fire = nil, want a timeout error")
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("Fire took %v; the timeout should end it within a few seconds", elapsed)
	}
}

// A redirect is a failed delivery, not a silent body-less GET.
func TestWebhookRedirectIsAFailure(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusFound)
	}))
	defer redirect.Close()
	runner := New("", time.Second, discard, []string{redirect.URL}, "")
	if err := runner.Fire(context.Background(), Event{Event: EventProgress}); err == nil {
		t.Fatal("Fire = nil, want the redirect reported as a failure")
	}
}
