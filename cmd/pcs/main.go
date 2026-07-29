// pcs — the Pocket Casts Sessions (PCS) server binary (see SESSIONS_SERVER_PLAN.md
// in the pocket-casts-ios fork).
//
//	pcs serve   run the HTTP server (the Docker entrypoint)
//	pcs link    operator fallback: link a Pocket Casts account into the database
//
// Local development: `make run` serves plain HTTP on :8080 — the iOS simulator
// reaches it at http://localhost:8080 (loopback is ATS-exempt). TLS is the
// reverse proxy's job in deployment, never this binary's.
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"golang.org/x/term"

	"github.com/mdbraber/pocket-sessions-server/internal/api"
	"github.com/mdbraber/pocket-sessions-server/internal/config"
	"github.com/mdbraber/pocket-sessions-server/internal/pc"
	"github.com/mdbraber/pocket-sessions-server/internal/push"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "serve":
		serve()
	case "link":
		link(os.Args[2:])
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "pcs: unknown command %q\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `usage: pcs <command>

  serve         run the HTTP server (config via PCS_* env vars)
  link          link a Pocket Casts account into the database (operator fallback;
                the normal path is the app's Link button)

link flags:
  -db path      SQLite database (default from PCS_DB, else pcsessions.db)
  -user id      PCS user to link (default 1)
  -password     use a one-shot email+password login instead of the device flow.
                The password is used for a single /user/login call and never
                stored — but this path yields only an expiring access token
                (PC's password login returns no refresh token), so the device
                flow (default) is strongly preferred.
`)
}

func serve() {
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

	// APNs when a .p8 key is configured; the log pusher otherwise (local dev).
	var pusher push.Pusher = push.NewLogPusher(logger)
	apnsCfg := push.APNSConfig{KeyPath: cfg.APNSKey, KeyID: cfg.APNSKeyID, TeamID: cfg.APNSTeamID, Topic: cfg.APNSTopic}
	if apnsCfg.Configured() {
		if apns, err := push.NewAPNSPusher(apnsCfg, logger); err == nil {
			pusher = apns
			logger.Info("apns pusher active", "topic", cfg.APNSTopic, "keyId", cfg.APNSKeyID)
		} else {
			logger.Error("apns setup failed, falling back to log pusher", "err", err)
		}
	}

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           api.New(st, pusher, logger, cfg.AllowedEmails),
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

// link is the operator fallback for connecting a Pocket Casts account when the
// app's Link button can't be used. Default is the same device-code flow the app
// drives — approve the printed code in any browser at pocketcasts.com/pair —
// which yields a renewable refresh-token lineage.
func link(args []string) {
	fs := flag.NewFlagSet("link", flag.ExitOnError)
	dbPath := fs.String("db", envOr("PCS_DB", "pcsessions.db"), "SQLite database path")
	userID := fs.Int64("user", 1, "PCS user id to link")
	usePassword := fs.Bool("password", false, "one-shot email+password login (expiring access token)")
	_ = fs.Parse(args)

	st, err := store.Open(*dbPath)
	if err != nil {
		fatal("open %s: %v", *dbPath, err)
	}
	defer st.Close()

	ctx := context.Background()
	var exchange pc.TokenExchange
	scope := pc.DeviceScope

	if *usePassword {
		exchange, scope = passwordLink(ctx)
	} else {
		exchange = deviceLink(ctx)
	}

	if err := st.SetPCLink(*userID, store.PCLink{
		Email:        exchange.Email,
		AccessToken:  exchange.AccessToken,
		RefreshToken: exchange.RefreshToken,
		Scope:        scope,
	}); err != nil {
		fatal("store link: %v", err)
	}

	who := exchange.Email
	if who == "" {
		who = "(email unknown)"
	}
	if exchange.RefreshToken != "" {
		fmt.Printf("Linked %s for user %d — renewable refresh-token lineage.\n", who, *userID)
	} else {
		fmt.Printf("Linked %s for user %d — ACCESS TOKEN ONLY: this link expires and\n"+
			"will need re-linking. Prefer the device flow (run without -password).\n", who, *userID)
	}
}

func deviceLink(ctx context.Context) pc.TokenExchange {
	auth, err := pc.DeviceAuthorize(ctx)
	if err != nil {
		fatal("device authorize: %v", err)
	}
	target := auth.VerificationURIComplete
	if target == "" {
		target = auth.VerificationURI
	}
	fmt.Printf("Open %s and approve code %s\n", target, auth.UserCode)
	fmt.Printf("(sign in with the Pocket Casts account to link; code expires in %d min)\n", auth.ExpiresIn/60)

	interval := auth.Interval
	if interval < 2 {
		interval = 5
	}
	deadline := time.Now().Add(time.Duration(auth.ExpiresIn) * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(time.Duration(interval) * time.Second)
		exchange, err := pc.RedeemDeviceCode(ctx, auth.DeviceCode)
		if err == nil {
			fmt.Println()
			return exchange
		}
		if err != pc.ErrAuthorizationPending {
			fatal("redeem device code: %v", err)
		}
		fmt.Print(".")
	}
	fatal("device code expired before it was approved")
	return pc.TokenExchange{}
}

func passwordLink(ctx context.Context) (pc.TokenExchange, string) {
	reader := bufio.NewReader(os.Stdin)
	fmt.Print("Pocket Casts email: ")
	email, err := reader.ReadString('\n')
	if err != nil {
		fatal("read email: %v", err)
	}
	email = strings.TrimSpace(email)

	fmt.Print("Password (not echoed, used once, never stored): ")
	pwBytes, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Println()
	if err != nil {
		fatal("read password: %v", err)
	}

	exchange, err := pc.PasswordLogin(ctx, email, string(pwBytes))
	for i := range pwBytes {
		pwBytes[i] = 0
	}
	if err != nil {
		fatal("pocket casts login: %v", err)
	}
	if exchange.Email == "" {
		exchange.Email = email
	}
	return exchange, "mobile"
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "pcs: "+format+"\n", args...)
	os.Exit(1)
}
