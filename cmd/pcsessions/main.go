// pcsessions — the Pocket Sessions server (see SESSIONS_SERVER_PLAN.md in the
// pocket-casts-ios fork). M1: session-state sync + device registry + push stub.
//
// Local development: `make run` serves plain HTTP on :8080 — the iOS simulator
// reaches it at http://localhost:8080 (loopback is ATS-exempt). TLS is the
// reverse proxy's job in deployment, never this binary's.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/api"
	"github.com/mdbraber/pocket-sessions-server/internal/config"
	"github.com/mdbraber/pocket-sessions-server/internal/push"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

func main() {
	cfg := config.FromEnv()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: cfg.LogLevel}))

	st, err := store.Open(cfg.DBPath)
	if err != nil {
		logger.Error("open store", "path", cfg.DBPath, "err", err)
		os.Exit(1)
	}
	defer st.Close()

	if err := st.EnsureBootstrapUser(cfg.AuthToken); err != nil {
		logger.Error("bootstrap user", "err", err)
		os.Exit(1)
	}

	// M1 ships with the log pusher; the APNs implementation slots in behind the
	// same interface once a .p8 key is configured (deployment concern).
	var pusher push.Pusher = push.NewLogPusher(logger)

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           api.New(st, pusher, logger),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		logger.Info("listening", "addr", cfg.Listen, "db", cfg.DBPath)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("serve", "err", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
