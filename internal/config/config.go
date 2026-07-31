package config

import (
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config comes entirely from the environment — the same binary runs on a
// laptop (plain HTTP, no push key) and on the VPS (behind Caddy, APNs key set).
type Config struct {
	Listen    string // PCS_LISTEN, default ":8080"
	DBPath    string // PCS_DB, default "pcsessions.db"
	AuthToken string // PCS_AUTH_TOKEN — operator bearer token for user 1 (curl, scripts); devices enroll via the PC link instead
	// PCS_ALLOWED_EMAILS — comma-separated PC account emails allowed to enroll
	// through the unauthenticated device-pairing link. Empty list = the email
	// already linked counts; a completely fresh server trusts the first link.
	AllowedEmails []string
	// APNs (silent-push fan-out). Unset = the log pusher runs instead. Keys can
	// be environment-restricted, so sandbox may use its own key; one key with
	// both environments needs only the first pair.
	APNSKey          string // PCS_APNS_KEY — production (or both-envs) AuthKey_<KEYID>.p8
	APNSKeyID        string // PCS_APNS_KEY_ID
	APNSSandboxKey   string // PCS_APNS_KEY_SANDBOX — sandbox-restricted key (optional)
	APNSSandboxKeyID string // PCS_APNS_KEY_ID_SANDBOX
	APNSTeamID       string // PCS_APNS_TEAM_ID, default ABCDE12345
	APNSTopic        string // PCS_APNS_TOPIC, default com.example.podcasts
	// Episode watcher: poll the public catalog for new episodes and push.
	EpisodePoll time.Duration // PCS_EPISODE_POLL, default 10m; "off"/"0" disables
	NotifyMode  string        // PCS_NOTIFY: "synced" (per-podcast toggle, default), "all", "off"
	// Playback-progress watcher + local hook scripts.
	ProgressPoll     time.Duration // PCS_PROGRESS_POLL, default 15m; "off" disables
	ProgressMinDelta int64         // PCS_PROGRESS_MIN_DELTA seconds, default 30
	FeedMatch        string        // PCS_FEED_MATCH — substring identifying first-party feed enclosures
	HooksDir         string        // PCS_HOOKS_DIR — executables run per playback event
	HookTimeout      time.Duration // PCS_HOOK_TIMEOUT, default 30s
	LogLevel         slog.Level
}

func FromEnv() Config {
	cfg := Config{
		Listen:           envOr("PCS_LISTEN", ":8080"),
		DBPath:           envOr("PCS_DB", "pcsessions.db"),
		AuthToken:        os.Getenv("PCS_AUTH_TOKEN"),
		AllowedEmails:    splitList(os.Getenv("PCS_ALLOWED_EMAILS")),
		APNSKey:          os.Getenv("PCS_APNS_KEY"),
		APNSKeyID:        os.Getenv("PCS_APNS_KEY_ID"),
		APNSSandboxKey:   os.Getenv("PCS_APNS_KEY_SANDBOX"),
		APNSSandboxKeyID: os.Getenv("PCS_APNS_KEY_ID_SANDBOX"),
		APNSTeamID:       envOr("PCS_APNS_TEAM_ID", "ABCDE12345"),
		APNSTopic:        envOr("PCS_APNS_TOPIC", "com.example.podcasts"),
		EpisodePoll:      parsePoll(envOr("PCS_EPISODE_POLL", "10m")),
		NotifyMode:       envOr("PCS_NOTIFY", "synced"),
		ProgressPoll:     parsePoll(envOr("PCS_PROGRESS_POLL", "15m")),
		ProgressMinDelta: parseInt(os.Getenv("PCS_PROGRESS_MIN_DELTA"), 30),
		FeedMatch:        strings.TrimSpace(os.Getenv("PCS_FEED_MATCH")),
		HooksDir:         os.Getenv("PCS_HOOKS_DIR"),
		HookTimeout:      parsePoll(envOr("PCS_HOOK_TIMEOUT", "30s")),
		LogLevel:         slog.LevelInfo,
	}
	if os.Getenv("PCS_DEBUG") != "" {
		cfg.LogLevel = slog.LevelDebug
	}
	return cfg
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// parsePoll turns PCS_EPISODE_POLL into a duration; "off"/"0"/garbage → 0
// (watcher disabled). A floor of 1m protects the catalog from typo-hammering.
func parsePoll(v string) time.Duration {
	if v == "off" || v == "0" {
		return 0
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
		return 0
	}
	if d < time.Minute {
		return time.Minute
	}
	return d
}

func parseInt(v string, fallback int64) int64 {
	if v == "" {
		return fallback
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n < 0 {
		return fallback
	}
	return n
}

func splitList(v string) []string {
	var out []string
	for _, part := range strings.Split(v, ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}
