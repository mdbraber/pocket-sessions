// Package hooks runs local scripts on playback events. Deliberately generic:
// PCS reports what happened (with enough context to identify the episode) and
// each script decides whether it cares — that keeps third-party credentials
// and per-service mapping logic out of the server.
//
// Each executable in the hooks directory is run once per event with the event
// JSON on stdin and the same fields as PCS_* environment variables, so a hook
// can be a two-line shell script with no JSON parser.
package hooks

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Event kinds.
const (
	EventProgress  = "progress"  // playedUpTo moved materially
	EventCompleted = "completed" // playingStatus became "played"
	EventReopened  = "reopened"  // a completed episode went back to unplayed/in-progress
	EventArchived  = "archived"  // the app archived the episode (sync is_deleted)
)

type Event struct {
	Event         string `json:"event"`
	UserID        int64  `json:"userId"`
	EpisodeUUID   string `json:"episodeUuid"`
	PodcastUUID   string `json:"podcastUuid"`
	EpisodeURL    string `json:"episodeUrl,omitempty"`
	EpisodeTitle  string `json:"episodeTitle,omitempty"`
	PodcastTitle  string `json:"podcastTitle,omitempty"`
	PlayedUpTo    int64  `json:"playedUpTo"`
	Duration      int64  `json:"duration"`
	PlayingStatus int64  `json:"playingStatus"`
	At            int64  `json:"at"`
}

type Runner struct {
	dir     string
	timeout time.Duration
	logger  *slog.Logger
	// Webhook sinks: the same event JSON scripts get on stdin, POSTed to each
	// URL — the Todoist shape: receivers (an n8n flow, anything) subscribe by
	// URL and the server knows nothing about them. Failed deliveries are
	// retried from the watcher's delivery queue and replay sweeps re-fire
	// through the same path, so receivers get at-least-once delivery and must
	// be idempotent — the standing hook contract.
	webhookURLs  []string
	webhookToken string
}

// New returns nil when neither a hooks directory nor webhook sinks are
// configured — callers treat a nil runner as "no hooks", so the feature
// costs nothing when unused.
func New(dir string, timeout time.Duration, logger *slog.Logger, webhookURLs []string, webhookToken string) *Runner {
	if dir == "" && len(webhookURLs) == 0 {
		return nil
	}
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	return &Runner{dir: dir, timeout: timeout, logger: logger, webhookURLs: webhookURLs, webhookToken: webhookToken}
}

// Fire delivers the event to every webhook sink and runs every executable in
// the hooks directory. Sinks and hooks are independent: one failing (or timing
// out) never blocks the others. The returned error joins every failure, so the
// caller (the delivery queue in internal/watch) can retry the event — hooks
// and receivers are idempotent by contract, so re-delivering to the ones that
// already succeeded is harmless.
func (r *Runner) Fire(ctx context.Context, event Event) error {
	if r == nil {
		return nil
	}
	payload, err := json.Marshal(event)
	if err != nil {
		return err
	}
	errs := r.postWebhooks(ctx, event, payload)

	if r.dir == "" {
		return errors.Join(errs...)
	}
	scripts, err := r.scripts()
	if err != nil {
		r.logger.Warn("hooks: reading directory", "dir", r.dir, "err", err)
		return errors.Join(append(errs, err)...)
	}
	if len(scripts) == 0 {
		return errors.Join(errs...)
	}
	env := append(hookEnviron(),
		"PCS_EVENT="+event.Event,
		"PCS_USER_ID="+strconv.FormatInt(event.UserID, 10),
		"PCS_EPISODE_UUID="+event.EpisodeUUID,
		"PCS_PODCAST_UUID="+event.PodcastUUID,
		"PCS_EPISODE_URL="+event.EpisodeURL,
		"PCS_EPISODE_TITLE="+event.EpisodeTitle,
		"PCS_PODCAST_TITLE="+event.PodcastTitle,
		"PCS_PLAYED_UP_TO="+strconv.FormatInt(event.PlayedUpTo, 10),
		"PCS_DURATION="+strconv.FormatInt(event.Duration, 10),
		"PCS_PLAYING_STATUS="+strconv.FormatInt(event.PlayingStatus, 10),
		"PCS_AT="+strconv.FormatInt(event.At, 10),
	)

	for _, script := range scripts {
		if err := r.run(ctx, script, payload, env, event); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// hookEnviron is the server's environment minus its own PCS_* configuration —
// that holds the operator token, the webhook token and the APNs key paths,
// none of which a hook needs. A hook's own credentials (OWNTUBE_TOKEN, …) pass
// through; the event itself is added back as PCS_* variables.
func hookEnviron() []string {
	var env []string
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "PCS_") {
			continue
		}
		env = append(env, kv)
	}
	return env
}

// How long a timed-out hook's children may keep its output pipes open before
// PCS stops waiting for them (exec kills only the script itself).
const hookWaitDelay = 2 * time.Second

func (r *Runner) run(ctx context.Context, script string, payload []byte, env []string, event Event) error {
	runCtx, cancel := context.WithTimeout(ctx, r.timeout)
	defer cancel()

	cmd := exec.CommandContext(runCtx, script)
	cmd.Env = env
	cmd.Stdin = bytes.NewReader(payload)
	cmd.WaitDelay = hookWaitDelay
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out

	err := cmd.Run()
	name := filepath.Base(script)
	output := trim(out.String())
	if err != nil {
		r.logger.Warn("hook failed", "hook", name, "event", event.Event,
			"episode", event.EpisodeUUID, "err", err, "output", output)
		return fmt.Errorf("hook %s: %w", name, err)
	}
	if output != "" {
		r.logger.Info("hook ran", "hook", name, "event", event.Event, "output", output)
	} else {
		r.logger.Debug("hook ran", "hook", name, "event", event.Event)
	}
	return nil
}

// webhookClient never follows redirects: a 301/302 would turn the POST into a
// body-less GET (and carry X-Webhook-Token to wherever it points), and a 2xx
// from that would look like a delivery. A redirect is reported as a failure.
var webhookClient = &http.Client{
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// postWebhooks delivers the event to every configured sink, independently:
// one slow or failing receiver never blocks another.
func (r *Runner) postWebhooks(ctx context.Context, event Event, payload []byte) []error {
	var errs []error
	for _, url := range r.webhookURLs {
		if err := r.postWebhook(ctx, url, payload); err != nil {
			// Log the host only: for n8n the URL path is the capability.
			r.logger.Warn("webhook failed", "host", webhookHost(url), "event", event.Event, "err", err)
			errs = append(errs, fmt.Errorf("webhook %s: %w", webhookHost(url), err))
			continue
		}
		r.logger.Debug("webhook delivered", "host", webhookHost(url), "event", event.Event)
	}
	return errs
}

func (r *Runner) postWebhook(ctx context.Context, url string, payload []byte) error {
	postCtx, cancel := context.WithTimeout(ctx, r.timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(postCtx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if r.webhookToken != "" {
		req.Header.Set("X-Webhook-Token", r.webhookToken)
	}
	resp, err := webhookClient.Do(req)
	if err != nil {
		return err
	}
	// Drain so the connection is reused.
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	_ = resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

func webhookHost(raw string) string {
	if u, err := neturl.Parse(raw); err == nil && u.Host != "" {
		return u.Host
	}
	return "(unparseable url)"
}

// scripts lists executable regular files, in lexical order so operators can
// sequence them by name (10-foo, 20-bar).
func (r *Runner) scripts() ([]string, error) {
	entries, err := os.ReadDir(r.dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil || info.Mode()&0o111 == 0 {
			continue
		}
		out = append(out, filepath.Join(r.dir, entry.Name()))
	}
	sort.Strings(out)
	return out, nil
}

func trim(s string) string {
	const max = 500
	s = string(bytes.TrimSpace([]byte(s)))
	if len(s) > max {
		return s[:max] + fmt.Sprintf("… (%d bytes)", len(s))
	}
	return s
}
