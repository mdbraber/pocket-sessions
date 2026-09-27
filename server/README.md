# Pocket Casts Sessions (PCS)

The Pocket Casts Sessions (PCS) server (`pcs`) — companion to the Pocket Casts iOS
fork's Sessions feature. It provides:

- **Session-state sync** (sessions, seen-ledger, offeredThrough, filter
  presets) between devices, with APNs pushes so other devices fetch
  straight away, and the *Follow Now Playing* pointer that lets an idle
  device pick up what another one is playing.
- **A Pocket Casts replica**: every sync record the account produces, kept
  as Pocket Casts sent it, plus the full listening history (Pocket Casts
  itself keeps only the newest 100), behind a query / automation API.
- **New-episode alerts**: a watcher that checks subscribed podcasts and pushes
  alerts, honouring the app's per-podcast and global notification switches.
- **The playback mesh**: playback events (progress, played, archived) run
  local hook scripts and webhook sinks such as n8n, delivered from a retrying
  outbox; external players report back through `POST /api/v1/playback`,
  which writes to Pocket Casts. Loop guards stop the two sides echoing.
- **An optional `/pcapi` relay** that carries the app's Pocket Casts traffic,
  so the server sees changes the moment they happen.

Full design: `ios/SESSIONS_SERVER_PLAN.md` in this monorepo.
The complete system map — feeds, relay, replica, hooks, guards, operations —
is in `ARCHITECTURE.md`; the design analysis behind it in
`SYNC-ARCHITECTURE.md`.

The binary has two subcommands: `pcs serve` (the Docker entrypoint) and
`pcs link`, an operator fallback that links a Pocket Casts account straight
into the database. `pcs link` uses PC's device-pairing flow by default (approve
the printed code at pocketcasts.com/pair — yields a self-renewing refresh-token
lineage); `pcs link -password` does a one-shot email+password login instead,
which never stores the password but only yields an expiring access token. The
normal path is neither: saving the server URL in the app's Settings →
Synchronization drives the same device flow end-to-end, approval included.

By default the app does not route Pocket Casts traffic through this server —
it is a side-service, and the app keeps working with stock PC when no server
is configured. The fork's opt-in *route via session server* toggle changes
that: PC API traffic then flows through the `/pcapi` relay (transparent
byte passthrough with observation; direct-PC fallback on relay failure) —
see `ARCHITECTURE.md` §4.

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

| Variable             | Default          | Purpose                                                        |
|----------------------|------------------|----------------------------------------------------------------|
| `PCS_LISTEN`         | `:8080`          | Listen address                                                  |
| `PCS_DB`             | `pcsessions.db`  | SQLite path                                                     |
| `PCS_AUTH_TOKEN`     | *(empty)*        | Operator bearer token for user 1 (curl/scripts; devices don't need it) |
| `PCS_ALLOWED_EMAILS` | *(empty)*        | PC accounts allowed to enroll (comma-separated); empty = the already-linked account, or anyone on a fresh server |
| `PCS_APNS_KEY`       | *(empty)*        | Path to the APNs `AuthKey_<KEYID>.p8` (production, or both environments); unset = log pusher |
| `PCS_APNS_KEY_ID`    | *(empty)*        | The key's 10-char id                                            |
| `PCS_APNS_KEY_SANDBOX` | *(empty)*      | Optional second key for the sandbox environment (Debug builds), for portal keys restricted to one environment |
| `PCS_APNS_KEY_ID_SANDBOX` | *(empty)*   | That key's id                                                   |
| `PCS_APNS_TEAM_ID`   | *(empty)*        | Apple developer team id; unset = log pusher                     |
| `PCS_APNS_TOPIC`     | *(empty)*        | App bundle id (the push topic); unset = log pusher              |
| `PCS_EPISODE_POLL`   | `10m`            | New-episode watcher cadence (`off` disables; 1m floor)          |
| `PCS_NOTIFY`         | `synced`         | Visible new-episode alerts: `synced` (per-podcast toggle), `all`, `off` |
| `PCS_PROGRESS_POLL`  | `15m`            | Playback watcher cadence (`off` disables); relayed syncs also trigger it |
| `PCS_PROGRESS_MIN_DELTA` | `30`         | Seconds playback must move before a `progress` event fires     |
| `PCS_FEED_MATCH`     | *(empty)*        | Enclosure substring naming first-party feeds; scopes outage burst exemption and hook replay |
| `PCS_HOOKS_DIR`      | *(empty)*        | Directory of executables run per playback event (see `hooks/README.md`) |
| `PCS_HOOK_TIMEOUT`   | `30s`            | Time limit for each hook run                                    |
| `PCS_WEBHOOK_URLS`   | *(empty)*        | Comma-separated webhook sinks for playback events (e.g. n8n; see `n8n/README.md`) |
| `PCS_WEBHOOK_TOKEN`  | *(empty)*        | Sent to webhook sinks as `X-Webhook-Token`                      |
| `PCS_DEBUG`          | *(empty)*        | Debug logging when set                                          |

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
make hooks    # install/update playback hook scripts (deploy never touches them)
```

The compose also joins an external tier network — `PCS_TIER_NETWORK` in the
host `.env`, default `seg15-media` — a tier of this host's site-to-site
tunnel home, which is how playback hooks reach LAN-only services (see
`hooks/README.md`); `PCS_DNS` is that segment's resolver. Set both in `.env`
rather than editing the compose file on the host: `make deploy` overwrites
it. On a host without that setup, drop the `tier`/`dns:` entries and keep
just the `caddy` network.

Devices never need a typed token: enrollment is PC-identity based. A device
POSTs `/session/v1/pc-link/start` (unauthenticated), approves the pairing
code with its own Pocket Casts session, and `/pc-link/complete` both links
the account and issues the device its own `pcs_…` bearer token — in the app
this all happens automatically when the server URL is saved. The gate is
`PCS_ALLOWED_EMAILS` (or, unset: the already-linked account; a fresh server
trusts its first link). `PCS_AUTH_TOKEN` remains as an operator credential
for curl and scripts.

APNs uses a token-based `.p8` key: put `AuthKey_<KEYID>.p8` in the deploy
directory's `data/`, set `PCS_APNS_KEY_ID`, `PCS_APNS_TEAM_ID` and
`PCS_APNS_TOPIC` in `.env` (plus `PCS_APNS_KEY_ID_SANDBOX` for a sandbox-only
key), and redeploy. Without them the server logs
the pushes it would have sent.
