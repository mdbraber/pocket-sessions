.PHONY: run test build build-linux deploy hooks clean

# Local dev: plain HTTP on :8080, database in ./pcsessions.db, no auth token
# (open mode as user 1 — set PCS_AUTH_TOKEN to require auth, which is what
# deployment does).
run:
	PCS_DEBUG=1 PCS_DB=pcsessions.db go run ./cmd/pcs serve

test:
	go test ./...

build:
	CGO_ENABLED=0 go build -o bin/pcs ./cmd/pcs

# Cross-compile for a linux/amd64 VPS — pure-Go SQLite makes this a one-liner.
build-linux:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o bin/pcs-linux ./cmd/pcs

# Deploy over SSH: rsync the source next to the host's compose file, then rebuild.
# Host + path come from the gitignored deploy.env (DEPLOY_HOST, DEPLOY_DIR);
# one-time host setup is in the README.
-include deploy.env

# The WireGuard sidecar variant is retired: hooks reach LAN-only services over
# the host's site-to-site tunnel (the compose joins the external seg15-media
# tier network). Its OPNsense peer no longer exists, so fail loudly instead of
# deploying a stack whose tunnel can never connect.
ifdef WIREGUARD
$(error the WireGuard sidecar variant is retired — plain 'make deploy' uses the host site-to-site tunnel)
endif

deploy:
	@test -n "$(DEPLOY_HOST)" -a -n "$(DEPLOY_DIR)" || { echo "create deploy.env with DEPLOY_HOST=... and DEPLOY_DIR=..."; exit 1; }
	rsync -a --delete --exclude .git --exclude bin --exclude '*.db*' --exclude deploy.env --exclude CLAUDE.md ./ $(DEPLOY_HOST):$(DEPLOY_DIR)/src/
	ssh $(DEPLOY_HOST) "cp $(DEPLOY_DIR)/src/deploy/docker-compose.yml $(DEPLOY_DIR)/docker-compose.yml && cd $(DEPLOY_DIR) && docker compose up -d --build"

# Hooks are data, not source: `make deploy` never touches data/hooks, so this
# is how hook scripts get installed — and updated, after any change to one.
# The n8n flows run the OwnTube bridge now, so the script is shipped
# NON-executable (PCS skips it) unless HOOKS_ENABLE=1 — running both would
# deliver every event twice. Re-running this leaves the mode as chosen here.
hooks:
	@test -n "$(DEPLOY_HOST)" -a -n "$(DEPLOY_DIR)" || { echo "create deploy.env with DEPLOY_HOST=... and DEPLOY_DIR=..."; exit 1; }
	ssh $(DEPLOY_HOST) "mkdir -p $(DEPLOY_DIR)/data/hooks"
	scp hooks/owntube.sh $(DEPLOY_HOST):$(DEPLOY_DIR)/data/hooks/owntube.sh
	ssh $(DEPLOY_HOST) "chmod $(if $(HOOKS_ENABLE),755,644) $(DEPLOY_DIR)/data/hooks/owntube.sh && chown 1000:1000 $(DEPLOY_DIR)/data/hooks/owntube.sh"

clean:
	rm -rf bin *.db *.db-wal *.db-shm
