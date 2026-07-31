# Sync architecture analysis: polling, action mirroring, and the hub question

*2026-07-31. Prompted by the first week of live bidirectional sync between
Pocket Casts and OwnTube. Three questions: (1) can polling become push/pull,
(2) what should the action mirror table be, (3) should PCS hold all state and
proxy everything ("less companion, more proxy").*

## 1. Where polling actually remains, and what push is possible

Today's signal paths:

| Path | Mechanism | Latency |
|---|---|---|
| OwnTube → PCS | webhook on every history write | ~instant |
| PCS → OwnTube | hook scripts on watcher events | ~instant once PCS knows |
| PCS → Pocket Casts | sync-record write-through | ~instant |
| **Pocket Casts → PCS** | **poll** (15m tick) + nudge after the fork's app sync | seconds via nudge, ≤15m otherwise |
| OwnTube feeds → PC catalog | publisher push (30m) + PC's crawler cadence | tens of minutes |

The one real poll is Pocket Casts → PCS, and it is forced: PC's sync API has
no server push, no webhooks, and none are coming. Everything that *can* be
push already is. The honest optimizations, in order of value:

1. **Nudge on action, not just after sync.** The fork already nudges PCS
   after a full sync. Archiving, marking played, and scrubbing should each
   trigger sync-then-nudge immediately. This turns the fork's own actions
   into push with seconds of latency, and tonight's archive test showed the
   gap: the archive sat invisible until a manual nudge because the app hadn't
   synced yet. This is iOS-fork work, small.
2. **Keep the 15m tick as backstop only** — it covers non-fork devices (web
   player, iPad without the fork). Shortening it buys little once (1) exists
   and just multiplies API load.
3. **Publish-on-change for feeds.** The queue feed only changes when the
   publisher pushes (30m loop). OwnTube queue/playlist mutations could
   trigger an immediate one-shot publish (debounced a minute) the same way
   history writes trigger the webhook. PC's crawler cadence for private
   feeds stays outside our control, so this mainly helps other clients and
   the fork's manual refresh.

The "30s debounce" on progress already exists in spirit on both directions:
`PCS_PROGRESS_MIN_DELTA=30` gates PC→OwnTube progress events (a value delta,
not a timer — a 30-second *movement* threshold), and OwnTube's watch tracker
batches its history writes. If a time-based debounce is wanted on the
OwnTube→PCS webhook it belongs in `notifyPcsPlayback` (trailing-edge, per
video), but in practice upsert cadence is already coarse.

## 2. The action mirror table

What exists and what's missing, keyed by *video* (see §3 on why):

| Action | Direction | Today | Gap |
|---|---|---|---|
| progress (≥30s) | PC → OT | position update | — |
| played/completed | PC → OT | watched + dequeue | — |
| **archive** | PC → OT | watched + remove from source collection | — (built tonight) |
| reopened | PC → OT | *nothing* | OwnTube `completed` is sticky by design; would need an explicit un-watch mutation if mirroring is wanted |
| unarchive | PC → OT | nothing (deliberate) | probably correct — re-queueing on unarchive feels surprising |
| progress | OT → PC | position write-through, ahead-only | — |
| watched | OT → PC | completed write-through | — |
| **remove from OwnTube queue/playlist** | OT → PC | *nothing* | queue mutations don't fire the webhook (only history writes do); mirroring "removed in OwnTube → archive in PC" needs a webhook on queue/playlist removal |
| add to queue/playlist | OT → PC | via next publish + PC crawl | publish-on-change shrinks half the delay |

The two real gaps are *reopened* and *OwnTube-side removal*. Both are
mechanical now that the plumbing exists; neither should be built until the
subscription scoping below is in, or they'd fire for content PC never sees.

## 3. Scoping: only for feeds actually subscribed in Pocket Casts

Correct observation, and today's behavior is asymmetric:

- PC → OwnTube is inherently scoped: events only exist for episodes the
  account interacts with, which implies subscription.
- **OwnTube → PCS is unscoped**: every history write for every video fires
  the webhook. For a video in no subscribed feed, PCS does an enclosure
  lookup, misses, **rebuilds the entire enclosure index** (one catalog fetch
  per subscribed podcast), misses again, and returns `unknown-episode`. That
  refresh-on-every-miss is the expensive part — watching random non-feed
  videos in OwnTube causes repeated full catalog sweeps.

Fix (cheap, server-side, no OwnTube knowledge of PC needed): PCS
negative-caches misses (videoId → not-found, TTL ~6h, invalidated when the
index refreshes for another reason), and rate-limits index rebuilds to at
most one per interval. OwnTube stays dumb on purpose — it should not know
what PC subscribes to; the scoping knowledge lives where the subscription
list lives. The same scope gate is where the §2 gap features must sit.

## 4. The hub question: should PCS hold all state and proxy everything?

The variant-duplication found tonight frames it: one video = two PC episodes
(audio and video feed variants, distinct UUIDs). The mapping
`videoId ↔ {episodeUUIDs} ↔ feed ↔ collection` is the heart of every feature
built this week, and pieces of it now live in three places: PCS's enclosure
index, OwnTube's published_feeds ledger, and the companion's feed store.

**Full-hub (PCS owns all state, everything proxies through it): not
recommended.** PCS would duplicate OwnTube's collections and PC's account
state, and duplicated state means reconciliation bugs — the exact class of
problem the ahead-only guard exists to kill. It also inverts PCS's stated
design ("the server stays generic; hooks own the service specifics"), and
both upstreams remain authoritative anyway: PC for podcast state, OwnTube
for library state. A hub that is authoritative for nothing but stores
everything is the worst of both.

**Recommended: PCS as *broker with a mapping ledger*, and absorb the
companion.** Concretely:

1. **Merge the companion into PCS.** This is the true "less companion, more
   proxy" move. PCS is already public (pcs.example.com), already has users,
   tokens, and per-account auth; the companion is a separate service with a
   separate credential system whose only jobs are storing pushed snapshots
   and rendering RSS/chapters/icon. Let OwnTube publish snapshots to PCS and
   let PCS serve `/rss/*`, `/chapters/*`, `/icon.png` (same URLs via a vhost
   or a redirect for migration). One fewer deploy target, one credential
   model, and — decisively — the feed store lands in the same database as
   the enclosure index and progress baseline, which makes the videoId ↔
   episodes ↔ feed mapping *one table instead of three services*.
2. **Key the mirror on videoId, fan out to all episode variants.** Tonight
   the archive of one variant updated the other only by a lucky path
   (mark-watched → webhook → write-through matched the sibling). With the
   ledger in one place, an action applies to every episode UUID of the
   video deliberately, not accidentally.
3. **Keep the actions themselves as the existing narrow interfaces** — hook
   scripts outward, small authenticated mutations inward
   (`remote.archiveFromFeed`, `history.upsertEvent`, `/api/v1/playback`).
   The broker routes and guards; it does not own domain state.

Migration order if adopted: (a) port the companion's store/render into PCS
behind the same URLs, switch the publisher target, retire the container;
(b) build the unified mapping table from the publish payload (it already
carries videoId per item — the enclosure index becomes derived data);
(c) negative-cache scoping (§3); (d) fork nudge-on-action (§1); (e) then the
§2 gap actions on top of the now-scoped, videoId-keyed core.

Each step is independently shippable and none breaks the running system.

## 5. The sharpened hub question: PCS holds the full Pocket Casts DB

The real question (clarified): not "PCS owns both systems' state" but
**"PCS maintains a complete replica of the PC account database"** — every
record the sync protocol carries, not just the episode-progress slice —
and possibly sits in the traffic path ("pass everything through").

Two designs, which compose:

### Design A — full replica via the sync protocol (pull)

A cursor-0 sync already returns the entire account (the watcher's seed
discards most of it today). Persisting *all* record types — episodes with
every field (position, status, archived, starred, deselected chapters),
podcasts, folders, up-next, bookmarks — plus the public-catalog episode
lists PCS already fetches, yields a complete local PC DB kept fresh by the
existing poll/nudge cycle.

- **Feasibility: high.** The protobuf plumbing (parse and write, per-field
  modified stamps) exists and is proven in both directions. Storage is
  trivial (SQLite; thousands of rows). One important hedge: persist the
  **raw record bytes** alongside parsed columns, so unknown/new PC fields
  survive and re-parsing after schema learning is a local replay, not a
  re-sync.
- **What it buys immediately:** the §3 scoping problem evaporates (every
  episode↔enclosure↔feed lookup is local and warm — no catalog sweeps
  ever); the M2 mirror endpoints become complete rather than best-effort;
  the M3 query/automation API gets a real database; the reverse-sync guard
  gets full context (starred, archived, everything) instead of the
  three-field baseline.
- **What it does not buy: freshness.** A replica is only as current as the
  last poll. Design A alone changes none of §1's latency story.

### Design B — sync proxy: the fork routes PC traffic through PCS

The iOS plan explicitly chose "the app never routes PC traffic through this
server." This is the decision to revisit. If the fork points its PC API
base at PCS and PCS relays byte-for-byte to api.pocketcasts.com while
parsing a copy of both directions:

- **Polling disappears for fork-originated activity.** Every archive, played
  mark, scrub, queue edit is *seen by PCS at the moment the app syncs it* —
  the sync request itself is the push. Tonight's archive gap (action
  invisible until a manual nudge) cannot happen: the nudge becomes
  redundant for the fork, and hooks fire off the live traffic. The 15m
  backstop poll remains only for non-fork devices.
- **The replica stays fresh for free** — Design A's DB is written from the
  relayed responses instead of (mostly) from polls.
- **Risks, honestly:** PCS availability becomes part of the app's sync path
  — the fork must fall back to direct PC on PCS failure (a client-side
  timeout + retry-direct, small but essential); token custody is unchanged
  (PCS already holds a device lineage, and the relay uses the app's own
  auth header untouched); fidelity is low-risk because the relay forwards
  opaque bytes and parses a *copy* — a parse failure can never corrupt the
  passthrough.

### Verdict

Design B **with** Design A's store is the architecture that actually
delivers "push, not polling" — not because PC gained push, but because the
fork's own traffic becomes the event stream, with the poll demoted to a
backstop for foreign devices. It also subsumes the §1 nudge-on-action work
(no longer needed for the fork) and the §3 scoping fix (lookups are local).

*Status 2026-07-31: A and B are built — replica seeded (28,956 episodes,
3,107 played, 25,362 archived recovered), relay live at /pcapi with
parse-copy observation, and a relayed sync now triggers a debounced watcher
poll, so hooks are push-driven for relay traffic.*

Order that de-risks it: (1) Design A alone first — replica + raw-bytes
store, fed by today's polls; every consumer (scoping, guard, query API)
starts benefiting with zero new failure modes. (2) Then the relay, behind a
fork setting, with direct-PC fallback; run it read-only (parse the copy,
change nothing about routing decisions) until trusted. (3) Only then let
hooks fire from relay traffic and retire the fork's nudges. The companion
absorption (§4) is orthogonal and can proceed in parallel.
