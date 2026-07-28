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

clean:
	rm -rf bin *.db *.db-wal *.db-shm
