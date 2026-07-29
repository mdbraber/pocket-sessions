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
OWNTUBE_URL=http://owntube.home.example.com
OWNTUBE_TOKEN=<device token — auth.deviceLogin or the device-pairing flow>
```

It resolves the video's `channelId` via `video.detail`, then calls
`history.upsertEvent` with `positionSeconds` = `playedUpTo` and `completed` =
(status is played). OwnTube keeps one history row per video and treats
`completed` as sticky, so repeated events are safe.

### Reaching a LAN-only OwnTube

The VPS can't route to `*.home.example.com` on its own. Add a WireGuard
sidecar and put PCS in its network namespace (the same pattern as the podimo
stack on this host):

```yaml
  wireguard:
    image: lscr.io/linuxserver/wireguard
    cap_add: [NET_ADMIN]
    volumes: [./wireguard-config:/config]
    sysctls: ["net.ipv4.conf.all.src_valid_mark=1"]
    networks: [caddy]
    labels:            # Caddy now reaches PCS through this container
      caddy: ${PCS_DOMAIN}
      caddy.reverse_proxy: "{{upstreams 8080}}"

  pocket-sessions:
    network_mode: service:wireguard   # replaces `networks:` and the labels
```

Keep the tunnel **split**: set `AllowedIPs` to the home subnet only (e.g.
`192.168.1.0/24`), so Pocket Casts and APNs traffic keeps going out directly
and only home-bound requests take the tunnel.
