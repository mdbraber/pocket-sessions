# Playback hooks

PCS watches what you actually listened to and runs local scripts when it
changes. The server stays generic: it reports the event with enough context to
identify the episode, and each script decides whether it cares. Credentials for
other services live in the script's environment, never in PCS.

## How it works

The watcher polls Pocket Casts as another sync device (`/user/sync/update`),
which returns per-episode `playedUpTo`, `playingStatus` and `duration`. Changes
are diffed against the stored baseline, so a hook fires on *change*, not on
every poll. Events are also polled right after a **nudge** — the app tells PCS
"I just synced with PC" — so finishing an episode reaches a hook in seconds
rather than at the next tick.

The first poll only seeds the baseline; a lifetime of listening is never
replayed as fresh events.

## Events

| Event | When |
|-------|------|
| `progress`  | `playedUpTo` moved by at least `PCS_PROGRESS_MIN_DELTA` seconds (default 30) |
| `completed` | the episode became "played" |
| `reopened`  | a played episode went back to unplayed / in progress |

## The hook contract

Every executable in `PCS_HOOKS_DIR` runs once per event, in lexical order, with
the event as JSON on **stdin** and as environment variables (so a hook needs no
JSON parser):

```
PCS_EVENT           progress | completed | reopened
PCS_USER_ID
PCS_EPISODE_UUID    PCS_PODCAST_UUID
PCS_EPISODE_URL     the enclosure — how a hook recognises its own content
PCS_EPISODE_TITLE   PCS_PODCAST_TITLE
PCS_PLAYED_UP_TO    seconds
PCS_DURATION        seconds (0 = unknown)
PCS_PLAYING_STATUS  1 unplayed · 2 in progress · 3 played
PCS_AT              unix seconds
```

Title and URL are resolved from Pocket Casts' public catalog — its sync records
carry neither. A hook's exit status is logged; a failure never blocks other
hooks or the watcher.

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `PCS_HOOKS_DIR` | *(unset — hooks off)* | Directory of executables |
| `PCS_PROGRESS_POLL` | `15m` | Backstop cadence (`off` disables the watcher) |
| `PCS_PROGRESS_MIN_DELTA` | `30` | Seconds of movement before a `progress` event |
| `PCS_HOOK_TIMEOUT` | `30s` | Per-hook time limit |

## owntube.sh

Marks videos watched (and syncs the resume position) in a self-hosted
[OwnTube](https://github.com/mdbraber/owntube) instance when you listen to them
through Pocket Casts. It ignores episodes whose enclosure isn't served by the
configured OwnTube host, so it's safe alongside other hooks.

```
OWNTUBE_URL=https://owntube.home.example.com
OWNTUBE_MEDIA_HOST=owntube-media.home.example.com
OWNTUBE_TOKEN=<device token — auth.deviceLogin or the device-pairing flow>
```

`OWNTUBE_MEDIA_HOST` is the enclosure origin: the companion's podcast feeds
point enclosures at the media host, not the app host, and the hook accepts
either. Leave it unset if feeds enclose from `OWNTUBE_URL` itself.

It resolves the video's `channelId` via `video.detail`, then calls
`history.upsertEvent` with `positionSeconds` = `playedUpTo` and `completed` =
(status is played). OwnTube keeps one history row per video and treats
`completed` as sticky, so repeated events are safe.

**The token expires after 30 days** (OwnTube's `DEVICE_TOKEN_MAX_AGE`), so this
needs re-pairing monthly: `auth.startDevicePairing` → approve at
`/tv/pair?code=<userCode>` → `auth.pollDevicePairing` returns the token. The
pairing session is in-memory and lives 10 minutes, so approve promptly; polling
after it lapses returns `{"status":"expired"}` and no token.

Two failure modes are worth knowing, because both once looked like success:

- **`curl` exits 0 on an HTTP error**, and tRPC also reports some failures
  inside a `200` envelope. The hook therefore checks the status code *and* the
  body, and prints the server's own message.
- **`video.detail` is a public procedure** while `history.upsertEvent` is
  protected. A bad token still resolves the `channelId`, so a broken token
  fails only at the write — silently, before this was checked.

A video OwnTube doesn't have (`NOT_FOUND`) is not an error: the hook says so and
exits 0. Anything else exits non-zero, which PCS logs.

### Reaching a LAN-only OwnTube

The VPS can't route to `*.home.example.com` on its own. PCS therefore joins
`seg15-media`, a tier network on the host's permanent site-to-site WireGuard
tunnel to home. The network is created host-side, outside compose — hence
`external: true` — and the home firewall grants each tier its own access.
Three compose settings, already in `deploy/docker-compose.yml`, carry the
whole thing:

- the tier network is the **default route** (`gw_priority: 100`), so all
  outbound traffic carries the tier's source identity; inbound from Caddy
  still works because the caddy subnet is on-link, and on-link beats the
  default route;
- `dns:` points at the segment gateway, where the host resolver serves the
  home zone over the tunnel and everything else publicly;
- `cap_drop: NET_RAW`, so the container can't forge another tier's source.

Nothing is configured per deploy: `make deploy` ships it, and widening access
(another host, another port) is a firewall change at home, not a repo one.
The tunnel carries both address families and the home resolver answers AAAA
first, which is why the hook forces neither.

An earlier variant ran PCS inside a per-stack WireGuard client's network
namespace (`docker-compose.wireguard.yml`, `make deploy WIREGUARD=1`). It is
retired and deleted: its peer no longer exists on the home side, so a stack
resurrected from git history has a tunnel that can never connect — and since
Caddy reached PCS through that container, it takes the server down with it.

`make hooks` installs the hook scripts: `make deploy` only ships the server
and compose file, never the contents of `data/hooks`, so run `make hooks`
again after changing a hook.

## The reverse direction

Hooks carry Pocket Casts playback *out*; `POST /api/v1/playback` carries
external playback back *in*. A service the account also watches through
(OwnTube) reports `{enclosureContains, positionSeconds, completed,
durationSeconds}` with a bearer token; PCS resolves the episode by matching
the fragment against the subscribed podcasts' catalog enclosures (indexed
lazily on first miss) and writes the state to Pocket Casts as a sync record.

Loops terminate by an ahead-only guard: a report that isn't ahead of the
watcher's baseline is dropped (`behind` / `already-completed`), completion is
sticky in both directions, and every accepted write advances the baseline so
the watcher sees Pocket Casts' echo of it as a no-op — hooks don't re-fire.
