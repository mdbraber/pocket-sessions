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

The VPS can't route to `*.home.example.com` on its own, so PCS can run inside
a WireGuard client's network namespace (the pattern the podimo stack on this
host already uses). `deploy/docker-compose.wireguard.yml` is that variant,
ready to go — the only thing missing is your tunnel config.

```
make wireguard-scaffold      # creates the config dir, installs owntube.sh
# paste your client config into <deploy-dir>/wireguard-config/wg_confs/wg0.conf
# add OWNTUBE_URL and OWNTUBE_TOKEN to <deploy-dir>/.env
make deploy WIREGUARD=1
```

Three things to get right in that config:

- **Split tunnel.** `AllowedIPs` should list only your home subnet(s) — e.g.
  `192.168.1.0/24` — so Pocket Casts and APNs traffic keeps going out directly.
  `0.0.0.0/0` would route *everything* through home.
- **DNS.** If `owntube.home.example.com` only resolves on a home resolver, set
  `DNS = <home-dns-ip>` in the `[Interface]` section; `wg-quick` applies it.
- **A pass rule per address family.** The hook forces no address family — the
  tunnel carries both, and a home resolver usually answers AAAA first. Note
  that firewall rules are per-family: on OPNsense a v4-only "pass in" rule on
  the VPN interface drops v6 into the default deny, which looks like a routing
  bug rather than a firewall one (client shows the address assigned, the route
  present, `ip -6 route get` correct — and zero replies). Each family needs its
  own rule with the client's tunnel address as source.
- **Keepalive.** `PersistentKeepalive = 25` on the peer, since the VPS sits
  behind the peer's NAT and would otherwise go quiet.

Switching is deliberately opt-in (`WIREGUARD=1`) rather than automatic: while
PCS shares the tunnel's namespace, Caddy reaches PCS *through* that container,
so a tunnel that won't start takes the whole server offline with it. `make
deploy` (without the flag) always puts back the plain, no-VPN stack — that's
the rollback if anything goes wrong.

**Never restart the tunnel container on its own.** Restarting it destroys the
network namespace PCS is sharing, which orphans PCS — it keeps pointing at a
dead namespace and starts answering 502 through Caddy. Restart both together:

```
docker compose up -d --force-recreate
```

`make wireguard-scaffold` is also what re-installs the hook scripts: `make
deploy` only ships the server and compose file, never the contents of
`data/hooks`, so run the scaffold again after changing a hook.
