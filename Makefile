.PHONY: run test build build-linux deploy wireguard-scaffold clean

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

# WIREGUARD=1 deploys the variant that runs PCS inside a WireGuard client's
# network namespace, so hooks can reach a LAN-only service. Opt-in on purpose:
# a broken tunnel config takes the whole server offline with it, since Caddy
# then routes through that container.
COMPOSE_SRC = $(if $(WIREGUARD),docker-compose.wireguard.yml,docker-compose.yml)

deploy:
	@test -n "$(DEPLOY_HOST)" -a -n "$(DEPLOY_DIR)" || { echo "create deploy.env with DEPLOY_HOST=... and DEPLOY_DIR=..."; exit 1; }
	@$(if $(WIREGUARD),ssh $(DEPLOY_HOST) "ls $(DEPLOY_DIR)/wireguard-config/wg_confs/*.conf >/dev/null 2>&1" || { echo "no tunnel config on the host — run 'make wireguard-scaffold' and paste one into wireguard-config/wg_confs/wg0.conf first"; exit 1; },true)
	rsync -a --delete --exclude .git --exclude bin --exclude '*.db*' --exclude deploy.env --exclude CLAUDE.md ./ $(DEPLOY_HOST):$(DEPLOY_DIR)/src/
	ssh $(DEPLOY_HOST) "cp $(DEPLOY_DIR)/src/deploy/$(COMPOSE_SRC) $(DEPLOY_DIR)/docker-compose.yml && cd $(DEPLOY_DIR) && docker compose up -d --build"

# One-time host prep for the WireGuard variant: the config directory the
# tunnel reads, and the hooks directory PCS runs scripts from.
wireguard-scaffold:
	@test -n "$(DEPLOY_HOST)" -a -n "$(DEPLOY_DIR)" || { echo "create deploy.env with DEPLOY_HOST=... and DEPLOY_DIR=..."; exit 1; }
	ssh $(DEPLOY_HOST) "mkdir -p $(DEPLOY_DIR)/wireguard-config/wg_confs $(DEPLOY_DIR)/data/hooks && chown -R 1000:1000 $(DEPLOY_DIR)/wireguard-config && chmod 700 $(DEPLOY_DIR)/wireguard-config/wg_confs"
	scp hooks/owntube.sh $(DEPLOY_HOST):$(DEPLOY_DIR)/data/hooks/owntube.sh
	ssh $(DEPLOY_HOST) "chmod +x $(DEPLOY_DIR)/data/hooks/owntube.sh && chown 1000:1000 $(DEPLOY_DIR)/data/hooks/owntube.sh"
	@echo
	@echo "Scaffolded. Next:"
	@echo "  1. paste your client config into $(DEPLOY_DIR)/wireguard-config/wg_confs/wg0.conf"
	@echo "     (AllowedIPs = home subnet only, so only home traffic takes the tunnel)"
	@echo "  2. add OWNTUBE_URL and OWNTUBE_TOKEN to $(DEPLOY_DIR)/.env"
	@echo "  3. make deploy WIREGUARD=1"

clean:
	rm -rf bin *.db *.db-wal *.db-shm
