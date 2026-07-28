# Pocket Sessions

The Pocket Sessions server (`pcsessions`) — companion to the Pocket Casts iOS
fork's Sessions feature: session-state sync (sessions, seen-ledger,
offeredThrough, filter presets) with push-based sync between devices, a
background Pocket Casts mirror (M2), and a query / automation API (M2/M3).
Full design: `SESSIONS_SERVER_PLAN.md` in the `pocket-casts-ios` fork.

The app never routes Pocket Casts traffic through this server — it is a
side-service, and the app keeps working with stock PC when no server is
configured.

## Local development

```
make run        # plain HTTP on :8080, SQLite in ./pcsessions.db
make test
```

No TLS in the binary (that's Caddy's job at deployment) and no APNs key needed
locally — the push layer logs what it would send. With no `PCC_AUTH_TOKEN` set
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
| `PCC_LISTEN`     | `:8080`          | Listen address                             |
| `PCC_DB`         | `pcsessions.db`  | SQLite path                                |
| `PCC_AUTH_TOKEN` | *(empty)*        | Bootstrap bearer token for user 1          |
| `PCC_DEBUG`      | *(empty)*        | Debug logging when set                     |

## Deployment

Any Docker host running [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy)
with an external `caddy` network works: `deploy/docker-compose.yml` builds the
image and labels it for TLS + routing.

One-time host setup (a deploy directory the SSH user can write, plus secrets):

```
mkdir -p <deploy-dir>/data
cat > <deploy-dir>/.env <<EOF
PCC_DOMAIN=sessions.example.com
PCC_AUTH_TOKEN=$(openssl rand -hex 24)
EOF
```

Then locally, create a gitignored `deploy.env` with `DEPLOY_HOST=<ssh-host>` and
`DEPLOY_DIR=<deploy-dir>`, and:

```
make deploy   # rsync source + docker compose up -d --build
```

The token in the host `.env` is what the app's Settings → Synchronization →
Access Token expects. APNs (token-based `.p8` key) slots in behind
`push.Pusher` next.
