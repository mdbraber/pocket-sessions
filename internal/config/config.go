package config

import (
	"log/slog"
	"os"
)

// Config comes entirely from the environment — the same binary runs on a
// laptop (plain HTTP, no push key) and on the VPS (behind Caddy, APNs key set).
type Config struct {
	Listen    string // PCS_LISTEN, default ":8080"
	DBPath    string // PCS_DB, default "pcsessions.db"
	AuthToken string // PCS_AUTH_TOKEN — bootstrap bearer token for user 1; empty = open (local dev only)
	LogLevel  slog.Level
}

func FromEnv() Config {
	cfg := Config{
		Listen:    envOr("PCS_LISTEN", ":8080"),
		DBPath:    envOr("PCS_DB", "pcsessions.db"),
		AuthToken: os.Getenv("PCS_AUTH_TOKEN"),
		LogLevel:  slog.LevelInfo,
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
