# Architecture & usage: the Pocket Casts ↔ OwnTube mesh

*The canonical map of the whole system as of 2026-07-31. Component detail
lives in the per-repo docs; this document is the one that explains how the
pieces fit and how to operate them. Related reading: `README.md` (PCS server
basics), `hooks/README.md` (hook contract + owntube.sh), 
`SYNC-ARCHITECTURE.md` (the design analysis this architecture implements),
`docs/OWNTUBE-UPSTREAM-PLAN.md` in the owntube repo (the media-source
future), and `feeds/server/README.md` in the owntube repo (the public feeds
server).*

## 1. What this system is

Four components let one person watch YouTube through a podcast app with
full, bidirectional, near-real-time state sync:

| Component | Runs on | Authoritative for |
|---|---|---|
| **Pocket Casts** (cloud + iOS fork) | Automattic + the phone | podcast subscriptions, episode playback state |
| **OwnTube** | homeserver (home) | the video library: queue, playlists, saved, watch history |
| **feeds server** (`owntube/feeds/server`) | vps, `owntube.example.com` | nothing — a public, credentialed mirror of pushed feed snapshots |
| **PCS** (this repo) | vps, `pcs.example.com` | nothing upstream — the broker: replica, relay, hooks, guards |

The deliberate authority model: PCS and the feeds server own no domain
state. OwnTube stays the source of truth for the library; Pocket Casts for
podcast state. PCS holds a *replica* of PC state and the *mapping* between
worlds (videoId ↔ episode UUIDs ↔ feeds), routes events, and guarantees
loops terminate.

```
                       ┌────────────────────────────┐
                       │  Pocket Casts cloud (PC)   │
                       └───────▲──────────┬─────────┘
              sync writes /    │          │  \ watcher pull (overlap window)
              relayed traffic  │          ▼
   ┌────────┐   /pcapi   ┌────┴──────────────────┐    hooks (owntube.sh)
   │ iOS    ├───────────►│  PCS  pcs.example.com│──────────────────┐
   │ fork   │◄───────────┤  relay·replica·guards │◄───────────┐     │
   └───┬────┘  responses └───────────▲───────────┘  webhook   │     ▼
       │ plays media                 │ publish payload   ┌────┴─────────┐
       ▼                             │ (via feeds srv)   │   OwnTube    │
  owntube-media.home ◄───────────────┼───────────────────┤   (homeserver)   │
  (enclosures, HLS)      ┌───────────┴───────────┐       └──────▲───────┘
                         │ feeds server (vps)  │  pushed by   │
                         │ owntube.example.com  │◄─────────────┘
                         └───────────────────────┘   feeds pusher (30m)
```

Network: vps (Hetzner VPS) reaches the home LAN over a host-level
site-to-site WireGuard tunnel; PCS joins the `seg15-media` tier network
(default route, split DNS, `NET_RAW` dropped). Media never leaves home:
feed *metadata* is public behind auth, enclosures/HLS resolve only on the
LAN or over the phone's own VPN.

## 2. The feeds pipeline (OwnTube → podcast app)

**Publish.** The feeds pusher (`owntube/feeds/pusher`, a container on homeserver
looping every 30 min) builds a snapshot of every user's library — playlists,
queue, saved, merged subscriptions, per-tag and per-channel uploads — and
POSTs it to the feeds server (`Bearer OWNTUBE_PUBLISH_SECRET`, IP
allow-listed). Full-set semantics: whatever is absent from a push is pruned.

**Serve.** The feeds server renders podcast RSS per feed in two variants:
`/rss/<kind>/<slug>.audio.xml` (m4a) and `.video.xml` (mp4). Also:
`/opml.xml` (all your feeds), `/` (HTML index), `/chapters/<videoId>.json`
(Podcasting 2.0 chapters, public — YouTube-derived data), `/icon.png`
(stable cover art, public).

**Identity & auth.** Basic Auth is per user: username = full account email,
password = generated per user, shown under OwnTube → Settings → Podcast
feeds (regenerate there; takes effect next push, then update apps). Only
SHA-256 hashes ever leave home. Feed routes serve only the authenticated
owner's feeds, so two users can both have `queue`.

**Subscribe in Pocket Casts** — paste into Discover search:

```
https://<email-urlencoded>:<rss-pass>@owntube.example.com/rss/queue/queue.audio.xml
```

(`@` in the email becomes `%40`; the server also accepts the un-decoded
form some clients forward.) Or use the **Copy RSS URL** buttons in OwnTube:
subscriptions header, playlist pages, and the ⋯ menu on Queue/Saved — each
offers audio/video. Slugs come from the `published_feeds` ledger the pusher
records, so the UI always matches what was actually published.

**Content details.** Item artwork: public `i.ytimg.com` thumbnails (LAN
URLs would be unreachable for podcast apps). Feed covers: the OwnTube icon
(stable; channel feeds keep their channel avatar). Chapters: parsed from
video descriptions at publish time, served as JSON, referenced with
`<podcast:chapters>`. Enclosure quality: audio = best AAC (~128k); video =
best *progressive* mp4 YouTube still offers (720p sometimes, usually 360p) —
which is why the fork **derives HLS**: for our enclosures it streams
`https://<media-host>/hls/<videoId>/master.m3u8` (H.264 ladder to 1080p +
AAC), falling back to the mp4; downloads always use the mp4.

## 3. The playback signal mesh

Every arrow is guarded so that echoes terminate; see §5.

| Signal | Mechanism | Latency |
|---|---|---|
| action in the fork | app syncs через `/pcapi` relay → observation + triggered poll | seconds |
| action on another PC device | 15-min watcher tick (backstop) | ≤15 min |
| PCS → OwnTube | hook scripts (`owntube.sh`) per event | instant after detection |
| watch/archive in OwnTube | OwnTube hook (`pcs.sh`) → `POST /api/v1/playback` → sync-record write to PC | seconds |
| library edits → feeds | pusher cycle + PC crawler | tens of minutes |

**Event kinds** (watcher classification): `progress` (≥30s movement),
`completed`, `reopened`, `archived` (PC's `is_deleted`; fires even on first
sight — archiving an unplayed episode is still deliberate — and outranks a
simultaneous completion).

**The action mirror** as implemented:

| You do | Result |
|---|---|
| play/scrub in PC | OwnTube position updates |
| finish in PC | OwnTube marks watched + dequeues |
| **archive in PC** | OwnTube marks watched **and** removes from the source collection (queue/saved/that playlist), resolved by feed title via the published ledger |
| watch in OwnTube | PC position updates (ahead-only) |
| finish in OwnTube | PC marks played |
| reopen in PC / remove in OwnTube | *not mirrored* (deliberate gaps — see SYNC-ARCHITECTURE §2) |

The same video can exist as several PC episodes (audio + video feed
variants); state converges across variants via the write-through path.

## 4. PCS internals

### The relay (`/pcapi/*`)

A transparent byte-forwarding proxy to `api.pocketcasts.com`, gated by an
`X-PCS-Proxy-Token` header (any PCS device/operator token — it is not an
open proxy; the PC `Authorization` header passes through untouched). The
fork enables it with the "route via session server" toggle and falls back
to direct PC on relay failure.

*Encoding contract:* upstream negotiation is constrained to `gzip` (the one
encoding PCS can decode); the compressed response passes through
byte-identical; the **observer decompresses only its own copy**
(`Content-Encoding`-guided, magic-byte fallback). Caddy adds
`encode zstd gzip` toward clients for anything upstream left plain.

*Observation:* parsed copies of `/user/sync/update` (both directions — the
request carries the app's outgoing records), `/sync/update_episode` (the
hot single-episode position sync), `/history/sync`, and
`/user/podcast/episodes` feed the replica. Any `/sync/*` mutation also
triggers the watcher with a **leading + trailing debounce**: one poll
immediately, one after 6s of session quiet (a sync session is many requests;
polling only at its start races the batches that matter).

### The replica

`pc_replica` holds every sync record seen — indexed columns plus the **raw
bytes exactly as PC sent them** (wire concatenation is field-wise proto
merge; capped 8KB per episode, columns preserve merged state regardless), so
parser gaps never lose data. `pc_history_ledger` accumulates listening
history forever (PC serves only the newest 100).

Seeding (`POST /api/v1/replica/seed`) runs three passes, each covering
another's blind spot (all measured live): cursor-0 sync (active state,
including unsubscribed shows — but **archived records are excluded** by PC),
the history ledger (played regardless of archive — but capped), and a
per-podcast `/user/podcast/episodes` sweep over every known podcast UUID
(the deep-history workhorse; note its response is the *flat*
`EpisodeSyncResponse`, not wrapper-based `SyncUserEpisode`). Afterwards the
watcher's polls and relay observation keep it current.

### The watcher

Polls `/user/sync/update` as a sync device, diffs against the baseline,
fires hooks on material change. Two hard-won subtleties: polls re-fetch a
**10-minute overlap window** behind the cursor (sync records carry
*client-side* action timestamps, so a fresh cursor can permanently skip an
action taken minutes before the app synced — the baseline diff makes the
overlap free of duplicate events); and the **bulk-burst cap** (25 events)
suppresses mass-operation noise but always delivers events for first-party
feed episodes (`PCS_FEED_MATCH` scopes "first-party" by enclosure
substring).

### Reverse write-through (`POST /api/v1/playback`)

An external player reports `{enclosureContains, positionSeconds, completed,
durationSeconds}`. PCS resolves the episode via the enclosure index
(lazily built from subscribed podcasts' catalogs; misses negative-cached
6h; rebuilds rate-limited to 1/10min), applies the **ahead-only guard**
(nothing ≤ known state applies; completion is sticky both ways), writes a
sync record to PC (per-field modified stamps, like the app), advances the
baseline so the watcher sees PC's echo as a no-op, and nudges devices.

### Hooks — symmetric on both sides

PCS side: scripts in `PCS_HOOKS_DIR`, one run per event, `PCS_*` env
contract (see `hooks/README.md`). `owntube.sh` maps events onto OwnTube
tRPC mutations; it self-selects by enclosure host so it is safe alongside
other hooks.

OwnTube side (mirror design, `owntube/hooks/README.md`): history writes
fire `watched`/`progress` events through every executable in
`OWNTUBE_HOOKS_DIR` (`OT_*` env + JSON on stdin), and the feeds pusher
re-fires the last 48h with `OT_SOURCE=replay` each cycle — the reverse
direction's outage recovery. `pcs.sh` is the only PCS-aware piece: it
POSTs to `/api/v1/playback`. Neither server knows its receivers; all hook
effects are idempotent by contract.

## 5. Loop termination (why this can't oscillate)

- **Ahead-only:** inbound reports not strictly ahead of the watcher
  baseline drop (`behind` / `already-completed`).
- **Sticky completion, both sides:** a position update never un-finishes.
- **Baseline advance on write:** every accepted write-through updates the
  baseline, so the watcher classifies PC's echo as no-change → no hook.
- **Hook idempotency:** re-delivery (replay, re-report) is harmless by
  construction; OwnTube upserts one history row per video.

Verified end-to-end in production: archive → mark-watched → webhook →
write-through to the sibling variant → echo dropped, all state equal.

## 6. Outage behavior and recovery

If PCS is down: the app falls back to direct PC (nothing user-visible);
playback of feeds continues (media resolves at home, not via PCS). On
recovery, state converges automatically:

- the watcher's cursor fetch catches the window's PC changes; feed-episode
  events survive even a bulk burst;
- the feeds pusher **re-fires the last 48h of watch history through the
  OwnTube hooks** every cycle (`OT_SOURCE=replay`) — receivers dedupe (the
  ahead-only guard makes steady state free) and a dead window heals within
  one cycle;
- `POST /api/v1/hooks/replay` re-delivers every feed episode's *current*
  replica state as one synthetic event each (archived > completed >
  progress) — the manual big hammer, safe any time.

## 7. API reference (PCS)

Auth: `Authorization: Bearer <token>` (operator `PCS_AUTH_TOKEN` or any
device token) unless noted.

| Endpoint | Purpose |
|---|---|
| `POST /api/v1/playback` | external playback report (see §4) |
| `POST /api/v1/hooks/replay` | re-deliver feed episodes' current state |
| `POST /api/v1/replica/seed` | run the three-pass seed (async, single-flight) |
| `GET /api/v1/replica/status` | counts: episodes/played/archived/records/ledger |
| `GET /api/v1/replica/history` | the accumulated listening ledger (`?limit=`) |
| `ANY /pcapi/<pc-path>` | the relay (gate: `X-PCS-Proxy-Token`) |
| `POST /session/v1/nudge` | "I just synced" — triggers mirror refresh + poll |
| `GET/POST /session/v1/*`, `/api/v1/up-next`, `/api/v1/history`, `/api/v1/podcasts` | session sync + PC mirror (pre-existing; see README) |

## 8. Configuration reference

**PCS (vps `/var/docker/pocket-sessions/.env`)** — beyond README's table:
`PCS_FEED_MATCH` (enclosure substring naming first-party feeds; scopes
burst exemption + replay; here: `owntube-media`), `OWNTUBE_URL`,
`OWNTUBE_MEDIA_HOST`, `OWNTUBE_TOKEN` (hook credentials; the device token
expires every 30 days — re-pair via `auth.startDevicePairing`).

**OwnTube (homeserver compose)** — `OWNTUBE_HOOKS_DIR`
(`/app/apps/web/data/hooks`, bind-mounted) on both the app service (live
events) and the feeds-pusher service (replay sweep); `PCS_PLAYBACK_URL` +
`PCS_PLAYBACK_TOKEN` consumed by `hooks/pcs.sh`, not the server;
`OWNTUBE_PUBLISH_TARGET`/`SECRET` for the pusher and the settings UI.

**Feeds server (vps `/var/docker/owntube-companion/.env`)** —
`PUBLISH_SECRET`, optional `PUBLISH_ALLOW_HOSTS`/`IPS`. No feed
credentials in env: they arrive with each publish.

**iOS fork** — Settings: session server URL + the *route via session
server* toggle (adds `X-PCS-Proxy-Token`, falls back to direct);
`SJVideoChaptersBase` (UserDefaults) overrides the chapters host.

## 9. Operations

```sh
# Deploy PCS (from this repo; ControlMaster/agent quirks: add
#   -o IdentityAgent=none -i ~/.ssh/id_ed25519 if the agent is wedged)
make deploy          # rsync + rebuild container
make hooks           # ship hook scripts (deploy never touches data/hooks)

# Deploy OwnTube (homeserver)
ssh homeserver 'cd /usr/local/src/owntube && git pull &&
  cd /var/data/config/owntube && docker compose build owntube owntube-publisher &&
  docker compose up -d owntube owntube-publisher'

# Deploy feeds server (vps; source lives in owntube repo)
rsync -az --delete --exclude node_modules --exclude data --exclude '*.db*' \
  --exclude '.env' ~/src/owntube/feeds/server/ \
  root@vps.example.com:/var/docker/owntube-companion/
ssh vps 'cd /var/docker/owntube-companion && docker compose up -d --build'

# One-shot feeds push (+ history re-report)
ssh homeserver 'docker exec owntube-publisher pnpm push:feeds'

# Health checks
curl https://pcs.example.com/healthz
curl https://owntube.example.com/health
ssh vps 'docker logs --since 10m pocket-sessions | \
  grep -E "msg=relay|relay observe|progress changes|hook ran|WARN"'
curl -H "Authorization: Bearer $PCS_TOKEN" \
  https://pcs.example.com/api/v1/replica/status
```

Log lines that matter: `relay observe sync` (per-sync parse outcomes —
`respErr=true` or all-zero counts means the encoding contract broke),
`progress changes` + `hook ran` (the delivery chain), `bulk burst` (kept vs
suppressed), `playback write-through` (reverse direction), `relay:
unauthorized` (a client without the proxy token).

## 10. Known edges

- PC's cursor-0 sync **excludes archived episodes** and `/history/sync`
  caps at 100 — the replica exists precisely because of this; never assume
  either is complete.
- `/user/podcast/episodes` responses are the flat `EpisodeSyncResponse`
  message — different field numbers from `SyncUserEpisode`.
- OwnTube's device token (hooks) expires every 30 days.
- Regenerating the RSS password breaks existing app subscriptions after the
  next push (by design; the settings UI warns).
- The generated protobuf in the fork (`api.pb.swift`) is the authoritative
  wire reference for every PC message — transcribe from it, never guess.
