# Pocket Casts Sessions (PCS) — Server Design & Plan

Decided 2026-07-28 (supersedes the true-proxy shape discussed the same day).
**Architecture: side-service + server-side PC mirror + query API, one host.**
Language: **Go**. Storage: **SQLite**. Hosting: **small public VPS** (Caddy TLS).
Schema is multi-user from day one ("me now, multi-user later"); the query API
is read **and write-through**.

## Shape

The app never routes PC traffic through the server. Three relationships:

1. **App ↔ Pocket Casts, directly** — all stock sync, auth, catalog. The server
   being down never affects the app's PC behavior (no SPOF by construction).
2. **App ↔ server** — session state only (sessions, seen-ledger, offeredThrough,
   presets), device registry, APNs-push-triggered delta sync, and a cheap
   `POST /nudge` fired after each completed PC sync.
3. **Server ↔ Pocket Casts, background** — the server holds its own PC token
   per user and acts as *just another PC client device*: it pulls account
   state (up next, history, playlists, progress) into mirror tables, and
   writes through to PC for automation requests. Conflicts resolve exactly as
   a second phone would — PC's own per-field LWW semantics, nothing invented.

The **nudge** closes the mirror-freshness gap: app finishes a PC sync → nudges
server → server pulls the delta immediately → mirror is near-real-time → server
can push "changed" to the user's *other* devices, accelerating cross-device PC
sync without owning it.

One host, one Go binary (`pcsessions`), one SQLite file serves all of it. A
PC-compatible passthrough mode can still be added to the same host later if
ever wanted — nothing in this shape forecloses it.

## API surface

**Session sync (app-facing, JSON — reuses the client's Codable payloads)**
- `POST /session/v1/devices` — {deviceId, apnsToken, apnsEnv}
- `GET  /session/v1/changes?since=<cursor>` / `POST /session/v1/changes`
- `POST /session/v1/nudge` — "I just synced with PC"
- Merge semantics mirror `SessionCloudSync`: LWW per session/preset record,
  union-newest seen-ledger with retention, monotonic offeredThrough.

**Query + automation API (user-facing)**
- Reads from the mirror: `GET /api/v1/up-next`, `/history`, `/playlists`,
  `/sessions`, `/stats`, …
- Write-through: `POST /api/v1/up-next` (add/move/remove), mark played,
  archive, … — server applies to PC with its token, updates the mirror,
  nudges devices via push.

**Auth** — `users` + per-user bearer tokens table from day one; single user in
practice. All endpoints authenticated; TLS only.

## SQLite schema (sketch)

```
users(id PK, name)
tokens(token PK, user_id, label, created_at)
pc_links(user_id PK, pc_token, pc_email, last_pull_cursor, last_pull_at)
devices(device_id PK, user_id, apns_token, apns_env, last_seen)
sessions      (user_id, uuid, payload, updated_at, deleted, PK(user_id,uuid))
presets      (user_id, uuid, payload, updated_at, deleted, PK(user_id,uuid))
offered_through(user_id, podcast_uuid, date, PK(user_id,podcast_uuid))
seen_ledger(user_id PK, payload)
mirror_* tables (up_next, history, playlist, playlist_episode, episode_state)
meta(user_id PK, sync_cursor)
```

## Push

`sideshow/apns2`, token-based `.p8` key (team ABCDE12345, bundle
`com.example.podcasts`). On session-state write or mirror change: bump cursor,
debounce ~2s, silent push `{content-available:1, cursor}` to the user's other
devices (originator excluded via `X-Device-Id`). Dev-signed builds use the
APNs sandbox (per-device `apnsEnv`). Periodic pull remains the fallback.

## iOS client changes

- `SessionServerSync` behind the same seams as `SessionCloudSync` (store
  `cloudDiffHandler`s in, `applyRemote*` out) — stores unchanged. Active
  backend = server when a URL is configured, else CloudKit (kept as fallback).
- Server URL + token in a Debug settings screen. No `ServerConstants` change
  needed (PC endpoints untouched).
- APNs registration (`aps-environment` entitlement already present) +
  content-available handler → fetch `/session/v1/changes`.
- Post-sync nudge hook where a PC refresh/sync completes.

## Milestones

**Status 2026-07-28:** M1, M2 and M3 built, deployed and verified against the
real account. Live: PC account link, Up Next + listening-history mirrors,
GET /api/v1/up-next, /history, POST /api/v1/pull, POST /api/v1/up-next
(write-through: add/remove verified end-to-end). Single-episode queue actions
are MEMBERSHIP changes — play_next on an already-queued episode is a no-op by
design; reordering needs the replace action (5) with a full order list.
Remaining: optional M4 passthrough.

**Episode watcher (2026-07-29): the fork's own new-episode push.** PC's
episode pushes can never reach this fork (APNs is keyed to the bundle id;
PC only signs for theirs — they were dead all along). The server now polls
the public catalog for every subscription (PCS_EPISODE_POLL, default 10m),
diffs against a seen_episodes ledger (seeded silently, 21.8k episodes),
and pushes: a silent wake for every device plus visible alerts shaped like
PC's own (category "ep", eu, podcast_uuid — the app's notification actions
work unchanged). PCS_NOTIFY=synced|all|off. PC's synced per-podcast toggle is
empty for this account (settings sync never ran on the fork), so the app
reports its own Podcast.pushEnabled set to POST /session/v1/notify-podcasts
(full set per device, fingerprint-deduped, on launch + podcastUpdated) and
synced mode alerts on the union across devices OR'd with PC's setting.
Verified: sim reported 0 → enabled one podcast (first permission grant
flips ALL on — stock PC behavior; curate in Settings → Notifications) →
110 rows in notify_podcasts. Deployment runs PCS_NOTIFY=synced.
Verified end-to-end minus APNs delivery (devices=0 until the phone
registers a token): resurrected a fresh episode → detected, alert composed,
wake sent. Settings UI collapsed the same day: Server URL + one Pocket
Casts Account row (re-link + manual token in its action sheet).

**Follow Now Playing (2026-07-29, opt-in switch under Synchronization).**
LWW playback-pointer document in the sync channel (session type/uuid +
playing episode + device). Hard-won rules from live testing:
- Only a device that is actually PLAYING publishes (1.5 s-delayed check) —
  an idle launch republishing stale state once yanked the live leader.
- Adoption = startPlaybackSession(autoPlay:false) — the app's own session
  entry point — never a hand-rolled pointer+load.
- Foreground poll every 20 s (cursor no-op): foreground push delivery is
  best-effort and sim-flaky.
- Position: pause uploads to PC immediately but fires no sync → pause now
  NUDGES (3 s grace); the server's nudge seq (+ origin device) rides every
  changes response; a poller seeing a foreign nudge runs a forced refresh
  (main SyncTask → seekToFromSync moves the loaded-paused player).
  Nudge-triggered syncs never re-nudge (suppression) — no ping-pong.
- ForkSettingsSync yields the pointer keys to PCS in server mode.

**Podcast settings sync (2026-07-29): speed/effects/skips both ways.**
Prompted by a TestFlight report of settings lost when migrating from
stock. Root reality (verified against upstream trunk, which the fork
rebases onto weekly): upstream iOS ships this HALF-LANDED — the
Api_PodcastSettings blob, ModifiedDate machinery and full-sync
processSettings exist, but nothing converts the blob, the SJPodcast
settings column is missing on DBs that predate upstream's amendment of
shipped migration 43, and Podcast.settings never persisted (the GRDB
macro only stores @objc properties). Stock iOS uploads only legacy skip
fields — speeds/effects never leave a stock device.
The fork now completes it: blob↔struct conversion with per-field
modified_at LWW in both directions, accepted-fields-only mirror into the
legacy columns (scope: effects/skips/notification), write-through UI
setters, @objc settingsJSON persistence, idempotent column catch-up.
Verified end-to-end both ways on device against the real account.
Expect to resolve toward upstream's own version if they ever land it.

**Backlog cleared 2026-07-29:**
- **Reorder**: POST /api/v1/up-next `{action:"replace", uuids:[...]}` — PC's
  action 5 with the full ordered episode list riding in the change
  (Change{2:action,3:modified,7:repeated UpNextEpisodeRequest}). Pure
  reorder/remove (unknown uuids rejected; adds via play_next/play_last).
  Verified with a no-op replace: 200, order preserved.
- **Podcast mirror**: /user/podcast/list returns ONLY uuid + folder/sort (no
  names — verified); titles/authors are enriched from the public catalog
  (podcast-api.pocketcasts.com/podcast/full/<uuid>, one fetch per uuid,
  cached in podcast_meta). GET /api/v1/podcasts serves 110 titled podcasts
  + 12 folders.
- **APNs**: pusher implemented behind push.Pusher (sideshow/apns2, .p8
  token auth, per-device sandbox/production, 2 s debounce, silent
  {content-available, pcsCursor} payload). Activates when PCS_APNS_KEY(_ID)
  are set — LIVE since 2026-07-29 (key KEYID67890 in the host's ./data,
  PCS_APNS_KEY_ID in .env; "apns pusher active" + clean flush verified,
  devices=0 until the phone registers a token). App side: registers for
  remote notifications unconditionally (silent pushes need no permission),
  sends the hex token + env in device registration, and a pcsCursor push
  triggers a session fetch + PC refresh. Sim gets no real APNs token; the
  phone will.

**PC link v2 (2026-07-28): the server's credential is self-sufficient.**
Key findings, verified against the production API:

- `POST /user/login` (password) returns only `{token, uuid, email}` — **no
  refresh token** — so "app re-logs-in and donates a refresh token" was never
  possible. Password accounts hold no refresh token at all; the app re-runs
  `/user/login` on every access-token expiry.
- Token lineages are independent: minting a new one disturbs no existing
  session (old tokens kept working throughout).
- PC runs a full **OAuth device-code flow** in production (TV pairing):
  `POST /device/authorize` (scope `tv` — the only accepted scope) →
  authenticated `POST /device/approve` → `POST /user/token` with the
  device_code grant → access token (1 h) **plus a rotating refresh token**.
  tv-scoped tokens read AND write `/up_next/sync` and read `/history/sync`;
  refresh exchanges must reuse the lineage's own scope (`pc_scope` column).

The link is now that flow end-to-end: app taps Link → server
`/session/v1/pc-link/start` (returns userCode) → app approves the code with
its own PC session (`deviceApproveRequest`) → `/session/v1/pc-link/complete`
redeems it. No password and no token ever leaves the device. A successful
link also mints a per-device **PCS API token** (`pcs_…`) which the app stores
automatically — the typed bootstrap token (PCS_AUTH_TOKEN) is now operator-only
and the Access Token row is read-only status with manual entry as escape hatch.
The binary is renamed **`pcs`** with `serve` (Docker entrypoint) and `link`
subcommands; `pcs link` is the operator fallback (device flow by default,
`-password` for a one-shot login that yields an expiring access-token link).

**Enrollment v2 (same day): no bootstrap token for devices.** `/pc-link/start`
+ `/complete` are unauthenticated and keyed by a `linkId`; approving the code
with an allowed PC account IS the credential (gate: `PCS_ALLOWED_EMAILS`, else
the already-linked email, else trust-on-first-link on a fresh server; pending
links capped + pruned). In the app, saving the Server URL runs the whole
enrollment automatically — the only manual step left. The Link row remains as
status/manual re-link. The client-side "keep the link alive" re-post was
removed, and the legacy donate-a-token endpoint now refuses to downgrade a
renewable lineage (old builds — the phone — would clobber it otherwise).
`PCS_AUTH_TOKEN` is an operator credential only. Verified end-to-end on the
simulator against a fresh local server (TOFU, tv lineage, minted pcs_ token
auto-stored).

- **M1 (= v1)** — Go skeleton, session sync API, device registry, APNs push;
  `SessionServerSync` + nudge hook in the app; CloudKit demoted to fallback.
  Zero protobuf. Ships the simulator fix and cross-device session sync.
- **M2** — PC link: Go protobuf client for PC's api endpoints (regenerate
  `.proto` from the checked-in `*.pb.swift`), mirror puller + nudge-triggered
  pulls, read-only query API.
- **M3** — write-through automation endpoints + cross-device nudge
  acceleration for PC data.
- **M4** *(optional)* — PC-compatible passthrough mode on the same host.

## Trade-offs accepted

- The server stores a PC token per user (needed for mirror + write-through) —
  but never sees passwords in-flight for app logins, unlike the true proxy.
- Mirror freshness depends on nudges + pull cadence rather than in-line
  observation; considered acceptable, and write-through operations always act
  on PC directly (not the mirror), so staleness never corrupts writes.
