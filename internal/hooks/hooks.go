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
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"time"
)

// Event kinds.
const (
	EventProgress  = "progress"  // playedUpTo moved materially
	EventCompleted = "completed" // playingStatus became "played"
	EventReopened  = "reopened"  // a completed episode went back to unplayed/in-progress
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
}

// New returns nil when no hooks directory is configured — callers treat a nil
// runner as "no hooks", so the feature costs nothing when unused.
func New(dir string, timeout time.Duration, logger *slog.Logger) *Runner {
	if dir == "" {
		return nil
	}
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	return &Runner{dir: dir, timeout: timeout, logger: logger}
}

// Fire runs every executable in the hooks directory for this event. Hooks are
// independent: one failing (or timing out) never blocks the others, and never
// fails the caller — playback events are informational, not transactional.
func (r *Runner) Fire(ctx context.Context, event Event) {
	if r == nil {
		return
	}
	scripts, err := r.scripts()
	if err != nil {
		r.logger.Warn("hooks: reading directory", "dir", r.dir, "err", err)
		return
	}
	if len(scripts) == 0 {
		return
	}
	payload, err := json.Marshal(event)
	if err != nil {
		return
	}
	env := append(os.Environ(),
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
		r.run(ctx, script, payload, env, event)
	}
}

func (r *Runner) run(ctx context.Context, script string, payload []byte, env []string, event Event) {
	runCtx, cancel := context.WithTimeout(ctx, r.timeout)
	defer cancel()

	cmd := exec.CommandContext(runCtx, script)
	cmd.Env = env
	cmd.Stdin = bytes.NewReader(payload)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out

	err := cmd.Run()
	name := filepath.Base(script)
	output := trim(out.String())
	if err != nil {
		r.logger.Warn("hook failed", "hook", name, "event", event.Event,
			"episode", event.EpisodeUUID, "err", err, "output", output)
		return
	}
	if output != "" {
		r.logger.Info("hook ran", "hook", name, "event", event.Event, "output", output)
	} else {
		r.logger.Debug("hook ran", "hook", name, "event", event.Event)
	}
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
