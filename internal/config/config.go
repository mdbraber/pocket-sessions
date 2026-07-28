package config

import (
	"log/slog"
	"os"
	"strings"
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
	LogLevel      slog.Level
}

func FromEnv() Config {
	cfg := Config{
		Listen:        envOr("PCS_LISTEN", ":8080"),
		DBPath:        envOr("PCS_DB", "pcsessions.db"),
		AuthToken:     os.Getenv("PCS_AUTH_TOKEN"),
		AllowedEmails: splitList(os.Getenv("PCS_ALLOWED_EMAILS")),
		LogLevel:      slog.LevelInfo,
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

func splitList(v string) []string {
	var out []string
	for _, part := range strings.Split(v, ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}
