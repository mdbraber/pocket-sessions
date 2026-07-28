.PHONY: run test build clean

# Local dev: plain HTTP on :8080, database in ./pcsessions.db, no auth token
# (open mode as user 1 — set PCC_AUTH_TOKEN to require auth, which is what
# deployment does).
run:
	PCC_DEBUG=1 PCC_DB=pcsessions.db go run ./cmd/pcsessions

test:
	go test ./...

build:
	CGO_ENABLED=0 go build -o bin/pcsessions ./cmd/pcsessions

# Cross-compile for a linux/amd64 VPS — pure-Go SQLite makes this a one-liner.
build-linux:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o bin/pcsessions-linux ./cmd/pcsessions

# Deploy over SSH: rsync the source next to the host's compose file, then rebuild.
# Host + path come from the gitignored deploy.env (DEPLOY_HOST, DEPLOY_DIR);
# one-time host setup is in the README.
-include deploy.env

deploy:
	@test -n "$(DEPLOY_HOST)" -a -n "$(DEPLOY_DIR)" || { echo "create deploy.env with DEPLOY_HOST=... and DEPLOY_DIR=..."; exit 1; }
	rsync -a --delete --exclude .git --exclude bin --exclude '*.db*' --exclude deploy.env --exclude CLAUDE.md ./ $(DEPLOY_HOST):$(DEPLOY_DIR)/src/
	ssh $(DEPLOY_HOST) "cp $(DEPLOY_DIR)/src/deploy/docker-compose.yml $(DEPLOY_DIR)/docker-compose.yml && cd $(DEPLOY_DIR) && docker compose up -d --build"

clean:
	rm -rf bin *.db *.db-wal *.db-shm
