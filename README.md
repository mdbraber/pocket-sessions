# Pocket Casts Sessions (PCS)

The Pocket Casts Sessions (PCS) server (`pcs`) — companion to the Pocket Casts iOS
fork's Sessions feature: session-state sync (sessions, seen-ledger,
offeredThrough, filter presets) with push-based sync between devices, a
background Pocket Casts mirror (M2), and a query / automation API (M2/M3).
Full design: `SESSIONS_SERVER_PLAN.md` in the `pocket-casts-ios` fork.

The binary has two subcommands: `pcs serve` (the Docker entrypoint) and
`pcs link`, an operator fallback that links a Pocket Casts account straight
into the database. `pcs link` uses PC's device-pairing flow by default (approve
the printed code at pocketcasts.com/pair — yields a self-renewing refresh-token
lineage); `pcs link -password` does a one-shot email+password login instead,
which never stores the password but only yields an expiring access token. The
normal path is neither: the app's Settings → Synchronization → Link Pocket
Casts drives the same device flow end-to-end, approval included.

The app never routes Pocket Casts traffic through this server — it is a
side-service, and the app keeps working with stock PC when no server is
configured.

## Local development

```
make run        # plain HTTP on :8080, SQLite in ./pcsessions.db
make test
```

No TLS in the binary (that's Caddy's job at deployment) and no APNs key needed
locally — the push layer logs what it would send. With no `PCS_AUTH_TOKEN` set
and no tokens in the database, the API runs open as user 1; the moment any
token exists, auth is required.

The iOS **simulator** reaches the server at `http://localhost:8080` out of the
box (loopback is ATS-exempt). A **physical iPhone** on the same LAN uses
`http://<mac-ip>:8080` and needs `NSAllowsLocalNetworking` in the app's ATS
settings (Debug builds only).

Smoke test:

```
curl -s localhost:8080/healthz
curl -s -X POST localhost:8080/session/v1/changes -H 'X-Device-Id: dev-a' \
  -d '{"sessions":[{"uuid":"s1","updatedAt":1000,"payload":{"name":"Test"}}]}'
curl -s 'localhost:8080/session/v1/changes?since=0'
```

## Configuration (environment)

| Variable         | Default          | Purpose                                   |
|------------------|------------------|-------------------------------------------|
| `PCS_LISTEN`     | `:8080`          | Listen address                             |
| `PCS_DB`         | `pcsessions.db`  | SQLite path                                |
| `PCS_AUTH_TOKEN` | *(empty)*        | Bootstrap bearer token for user 1          |
| `PCS_DEBUG`      | *(empty)*        | Debug logging when set                     |

## Deployment

Any Docker host running [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy)
with an external `caddy` network works: `deploy/docker-compose.yml` builds the
image and labels it for TLS + routing.

One-time host setup (a deploy directory the SSH user can write, plus secrets):

```
mkdir -p <deploy-dir>/data
cat > <deploy-dir>/.env <<EOF
PCS_DOMAIN=sessions.example.com
PCS_AUTH_TOKEN=$(openssl rand -hex 24)
EOF
```

Then locally, create a gitignored `deploy.env` with `DEPLOY_HOST=<ssh-host>` and
`DEPLOY_DIR=<deploy-dir>`, and:

```
make deploy   # rsync source + docker compose up -d --build
```

The token in the host `.env` is the bootstrap credential: the first device
authenticates with it once, and a successful Link Pocket Casts hands the app
its own server-issued `pcs_…` token, which it stores automatically. Manual
token entry in the app remains as an escape hatch. APNs (token-based `.p8`
key) slots in behind `push.Pusher` next.
