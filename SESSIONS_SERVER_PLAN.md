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

**Status 2026-07-28:** M1 done and deployed; M2 stage 1 (PC account link) and
stage 2 (Up Next mirror + query API) built and verified against a real account
locally — deploy pending. Next: history/podcast mirrors, then M3 write-through.

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
