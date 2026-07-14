# Sessions rework — research findings & staged plan

Supersedes `NEXT_SESSION_PROMPT.md`.

Module paths in `CLAUDE.md` are **stale** — it says `Modules/DataModel/Sources/…`; reality is
`Modules/Sources/PocketCastsDataModel/…`. Worth fixing.

---

# Status — decisions taken, and what is already fixed

## Decided (2026-07-14)

1. **The 1,000-member cap is accepted.** Consequence, taken as a rule:
   **never fill a backlog into the Inbox.** So §5 collapses: on subscribe, the Inbox gets **nothing**;
   `offeredThrough[p]` is set to the newest episode's `publishedDate` and only genuinely new episodes
   arriving afterwards get a dot. There is no "all" option, no "last N", no "last N days".
   *Consequence to know:* a freshly subscribed podcast shows an empty Inbox until its next release. That
   is the intended behaviour — the Inbox is for what's new, not for what's there.
   The Inbox settings screen (Stage 10) shrinks to the per-podcast opt-out plus the add-to-Session mode.

2. **`showArchivedEpisodes` is superseded — delete the column.** See §2.6 below.

3. **Mark-unseen means unplay + unarchive.** Confirmed. `EpisodeSeenManager.freshenForUnseen`'s behaviour
   survives the rewrite.

## Already fixed (working tree, tests green)

- ✅ **Fix 4 — `add(episodes:to:)` now marks the playlist dirty.** `PlaylistDataManager.add` sets
  `syncStatus = .notSynced` + `playlistUpdateDate` inside its existing write transaction, exactly as
  `deleteEpisodes`/`moveEpisode` already did. The invariant can no longer be forgotten by a caller.
  Required companion fix: `SyncTask+FullSync.swift` set `synced` *before* calling `add()`, which would now
  leave every freshly-imported playlist dirty and re-upload it — the two lines moved to *after* the add,
  matching `SyncTask+ServerChanges`, which already ordered it that way.
- ✅ **Fix 5 — the `Codable` wipe landmine is closed, in two layers.**
  `Session` gets a hand-written `init(from:)` using `decodeIfPresent` (it was using *synthesized*
  `Decodable`, which throws `keyNotFound` rather than falling back to a property's default — the actual
  cause of the wipe). And `Document` now decodes `[LenientlyDecoded<Session>]`, so a single unreadable row
  drops **that row**, never the document. `SessionStore` gained an injectable `init(fileURL:)`.
- ✅ **8 decode-safety tests** in `PocketCastsTests/Tests/Sessions/SessionStoreDecodeTests.swift`.
  Non-vacuous by construction: remove the hand-written init and `testSessionMissingDefaultedKeysDecodesWithDefaults`
  drops to zero sessions; remove `LenientlyDecoded` and `testCorruptSessionDropsOnlyThatSession` takes the
  whole store down. Each layer has a test that fails without it.
- Verified: `PocketCastsDataModelTests` = 461/463, and the 2 failures (`hasGeneratedTranscript` in
  `EpisodeColumnConsistencyTests`) **pre-exist on a clean tree** — confirmed by stashing.

## Still open — `updateEpisodePositionsIfNeeded`

**"Why have it at all?"** Because manual-playlist *order* is real, synced state — and session store lineups
depend on it. `episodeOrder` is what makes a lineup a lineup; drop the import and a session's play order
silently reverts to insertion order on every device but the one that set it.

But it is wrong in two ways and both should be fixed:

- **It is O(n²) for no reason.** It calls `moveEpisode` per episode, and each call reloads the playlist and
  rewrites *every* row's `episodePosition`. Replace the whole loop with a single positional write in the
  shape of `setCustomOrder(episodeUuids:for:)` — one transaction, O(n). This is a straight win for session
  stores too, not just the Inbox.
- **It should not run for the Inbox at all.** The Inbox is a *set*; its stored order is meaningless by
  design (§1). Short-circuit on the reserved uuid and skip both the import and the `episodeOrder` upload.

⇒ Keep it, fix it, and exempt the Inbox. Folded into Stage 2.

---

# Part 1 — The design survives, with seven corrections

The core idea (Inbox-as-manual-playlist, membership = unseen) holds up. The codebase supports it better
than you expected in two places and worse in five.

## ✅ 1.1 `offeredThrough` can replace the refresh hook entirely — no candidates table, no upstream edit

This is the biggest finding, and it makes §1a *smaller*, not bigger.

Stock already has the exact pattern you were reaching for: `AutoAddCandidates`, a durable table written
inside `RefreshOperation.performRefresh()` (`RefreshOperation.swift:143`) and drained **after the sync**
by `processAutoAddUpNextCandidates()` (`:177-220`), which re-checks `!played && !archived` because the
sync may have decided the episode elsewhere. That is §1a(b), already built, already load-bearing.

**But you don't need it.** `offeredThrough` alone is a complete new-episode detector:

```
after sync completes:
    for each subscribed podcast p:
        new = episodes(p) where publishedDate > offeredThrough[p]
                            and not archived and not played
        add new to Inbox
        offeredThrough[p] = max(publishedDate of all episodes of p)
```

This is strictly better than hooking the refresh:

- **No new table, no fork schema addition.** You never touch `applyForkSchemaAdditions`.
- **No edit to `RefreshOperation`** — an upstream file in the Server module. Zero rebase cost.
- **The "never hook episode-inserted generically" rule enforces itself.** A full sync or
  `cache/mobile/podcast/full` dumping the entire back catalogue is *harmless*: every one of those
  episodes has `publishedDate <= offeredThrough[p]`, so none are offered. The rule you were worried
  about violating is structurally impossible to violate.
- **It's idempotent and device-independent**, because `publishedDate` is server-consistent — which was
  the whole argument for `offeredThrough` in the first place.
- It runs **entirely in the app layer**, where `InboxStore` lives. No cross-module problem.

Hook: `ServerSyncManager.performActionsAfterSync()` (`podcasts/ServerSyncManager.swift:77-96`), called as
the *last* step of `RefreshOperation.main()` (`:99`), after refresh, after sync, after stock auto-archive
(`:95`). Stock already hangs `PlaylistManager.checkForAutoDownloads()` there. This is the right seam and
it needs no module change.

**Ordering bonus:** auto-archive runs at `:95`, before our drain at `:99`. So a new episode that stock
auto-archives on arrival never enters the Inbox at all. That is exactly the behaviour you asked for
("archived episodes get swept out") — and you get it for free, before the fact rather than after.

**Cost:** ~60 lines. One query, one loop, one playlist add.

### Residual (accept, don't design around)

- **Background refresh bypasses `main()`.** `BackgroundSyncManager+URLSession.swift:143-157` calls
  `performRefresh()` directly, so `performActionsAfterSync()` never runs there. New episodes get their dot
  on the next foreground launch. Stock's auto-add-to-Up-Next behaves identically. If you want background
  coverage, observe `ServerNotifications.syncCompleted` instead — it fires on both paths
  (`BackgroundSyncManager+URLSession.swift:79`). Recommendation: start with `performActionsAfterSync()`;
  it's simpler and matches stock.
- **CloudKit lag is a real, bounded re-offer window.** `offeredThrough` rides CloudKit; the Inbox playlist
  rides Pocket Casts sync. Two channels, different latencies. If device B drains before A's watermark
  advance arrives via CloudKit, B re-offers an episode A already triaged. It is **self-healing** (once
  CloudKit converges it stops) and it is the same class of risk as the last-writer-wins merge you already
  accepted. Worth knowing; not worth engineering around.

## 🔴 1.2 Manual playlists have a **1,000-member hard cap**, and overflow fails **silently**

`PlaylistDataManager.add(episodes:to:)` (`:450-466`):

```swift
if episodes.isEmpty || episodes.count > maxPlaylistItems { return false }   // maxPlaylistItems = 1000
let isFull = playlistCount + episodes.count > maxPlaylistItems
if isFull { return false }
```

It is **all-or-nothing** — it does not partially add — and it returns `false`, which most callers ignore.

Consequences the design does not account for:

1. **An Inbox at 1,000 members stops accepting new episodes.** No error, no dot, no clue. New episodes
   silently vanish from triage. This is the single worst failure mode in the whole design, because it is
   invisible and it degrades the one guarantee the feature makes.
2. **§5's "all back catalogue" option is unimplementable as written.** Subscribe to a podcast with 1,200
   episodes and pick "all" → `episodes.count > 1000` → **nothing is added at all.**

**Recommendation:**
- Cap the Inbox explicitly in fork code, *above* the DataModel: refuse to exceed ~900 and surface it
  ("Inbox is full — mark some as seen"). Never let the silent `false` be the thing that stops you.
- Drop "all" from the Inbox settings, or clamp it to "last N" with N ≤ 500. "All" on a large back
  catalogue is a bad idea independent of the cap.
- Add the count to the Inbox tab's counts line so approaching the ceiling is visible.

## 🔴 1.3 The Inbox playlist leaks into **~20** list surfaces — not the "already handled" case you assumed

The design says: *"The fork hides it from playlist lists (it already hides `" — feed"` playlists this way)."*
That mechanism does not apply. There are two existing hiding paths and the Inbox matches neither:

- `SessionStore.feederPlaylistUuids` (`SessionStore.swift:168-178`) hides only **smart** playlists whose
  **name ends in `" — feed"`**.
- `SJPlaylistsHideSessions` hides only playlists that are a **session store**, and it's a user preference
  (default off).

A reserved **manual** Inbox playlist is neither, so it appears in every surface that enumerates playlists:
`PlaylistsViewController:319,416` · `WidgetHelper:112` (takes `allPlaylists(...).first` — **the Inbox could
become the widget's filter**) · `UpNextViewController:1200` and `ManualPlaylistsChooserViewController:142`
(the "add to playlist" chooser) · `DownloadSettingsViewController:181-182` (auto-download) ·
`SiriSettingsViewController:160` · `CarPlaySceneDelegate+Tabs:57` · `WatchManager:700` ·
`ShareProfileViewModel:55` · `ChoosePlaylistFolderView:90` · `PlaylistFolderCreateFlow:77,101` ·
`PlaylistFolderEditView:122` · `PlaylistFolderManager:100` · `PlaylistCacheInvalidationCoordinator:155` ·
`PlaylistManager:91,116,133`.

**Fix — one chokepoint, and it is safe:** exclude the reserved uuid inside `PlaylistDataManager`, in
`allPlaylists` / `allManualPlaylists` / `allSmartPlaylists` / `count`.

✅ **Sync is unaffected**, because sync enumerates through a *different* API:
`SyncTask+LocalChanges.swift:109` → `allUnsyncedPlaylists()` (`WHERE syncStatus = notSynced`). The Inbox
still uploads and downloads normally while being invisible to every UI surface — including surfaces
upstream adds in future. That rebase-safety is the real argument for doing it here rather than at 20 call
sites.

## 🔴 1.4 The Inbox uuid should be a **compile-time constant**, not a value stored in `InboxStore`

Three reasons, and they compound:

1. §1.3 requires `PlaylistDataManager` (in DataModel) to know the uuid. A value living in an app-layer JSON
   store cannot be reached from there.
2. **It makes creation idempotent.** With a constant, two devices that both find-or-create the Inbox
   produce the *same* uuid and sync converges. With a random uuid persisted in `InboxStore`, two devices
   can create **two different Inbox playlists** and race through CloudKit — a genuine split-brain that the
   design would otherwise have to heal.
3. "Recognisable on a fresh install" becomes free.

Use a fixed UUID literal (a real UUID string, so server-side validation is never a question).
**`InboxStore` then collapses to `{ offeredThrough }`** — one less field and one less decode surface.

## 🔴 1.5 Sync import reorders manual playlists in **O(n²)**

`SyncTask+ServerChanges.updateEpisodePositionsIfNeeded` (`:393-407`) loops the server's `episodeOrder` and
calls `DataManager.moveEpisode(...)` **once per episode**. Each `moveEpisode`
(`PlaylistDataManager.swift:202-234`) reloads the whole playlist and rewrites **every** row's
`episodePosition`.

For a 200-member Inbox that is ~40,000 UPDATEs on any sync where the order differs. At 500 members it's
250,000. Your byte-level measurement of manual-playlist sync was right, but it measured *upload*; this is
the *import* cost, and it is the one that will actually hurt.

It bites the Inbox specifically because the Inbox goes dirty on nearly every refresh, so its order churns
constantly — **and its order is meaningless by design** (§1: "the Inbox is conceptually a set"). So the
work is not just expensive, it is entirely wasted.

**Fix (small, and it helps stock too):** replace the loop with one batch write in the shape of the existing
`setCustomOrder(episodeUuids:for:)` (`PlaylistDataManager.swift:539`) — one DELETE + n INSERTs in a single
transaction, or one pass of positional UPDATEs. `moveEpisode` already early-returns when the index is
unchanged, so a no-op sync is cheap; it's the *changed* case that explodes.

## 🔴 1.6 `add(episodes:to:)` does **not** mark the playlist dirty

`PlaylistDataManager.add` never touches `syncStatus` or `playlistUpdateDate`. Only `moveEpisode`,
`deleteEpisodes`, `deleteAllEpisodes` and `bumpSortPositionForAllPlaylists` do.

So **every Inbox add must explicitly mark the playlist unsynced or it never reaches the server.** The
fork's existing convention is right there — `SessionManager.markStoreChanged(_:)` (`SessionManager.swift:541-545`):

```swift
store.syncStatus = SyncStatus.notSynced.rawValue
DataManager.sharedManager.save(playlist: store)
NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: store)
```

Reuse it. (Conversely: sync-originated adds deliberately *skip* it — `SyncTask+ServerChanges.swift:377-386`.)

## 🔴 1.7 The `Codable` wipe landmine is **still half-open today**

You mitigated it at the wrong level. `SessionStore.Document.init(from:)` (`SessionStore.swift:104-111`) is
hand-written with `decodeIfPresent` — good. But it decodes `[Session].self`, and **`Session`
(`SessionStore.swift:18-35`) uses synthesized `Decodable`** with seven defaulted non-optional properties.

Swift's synthesized decoder does **not** fall back to default values; it throws `keyNotFound`. And
`decodeIfPresent` only returns `nil` for an *absent* key — if the key is present but an element fails to
decode, it **rethrows**. So:

```
Session gains a field → older document lacks it → [Session] decode throws
  → decodeIfPresent rethrows → Document.init throws
  → load()'s `try?` (:439) swallows → document stays empty
  → first mutation overwrites the file → EVERYTHING GONE
```

That is precisely the wipe you already suffered, and the mitigation stopped one level short of it.

**Therefore the decoder tests must cover the *element* types (`Session`, `FilterPreset`), not just the
document.** And every element type needs a hand-written `init(from:)`. Also: `SessionStore` has no
injectable `init(fileURL:)` today — the `archive/session-grdb-spike` tag added one, and the tests need it.

---

# Part 2 — Corrections to the smaller claims

## 2.1 The "inert `EpisodeFilter` columns" are mostly **not inert**

You listed four for excision. Only one is actually dead:

| Column | Reality |
|---|---|
| `newEpisodesAutoAdd` | ✅ **Genuinely inert.** Only the model decl, `copyForkOnlyFields`, and the DB round-trip. (`PlaylistDetailViewModel.updatePlaylist(newEpisodesAutoAdd:)` is a false positive — that's a *parameter label*; the body writes `Session.autoAdd`.) Safe to drop. |
| `folderUuids` | 🔴 **LIVE.** Written by `PodcastFilterOverlayController:206/213/217`; read by `PlaylistPreviewViewModel:80` and by `SessionManager.refreshFolderRules()` (`:494,:499`), which materialises folder members into `podcastUuids` on `folderChanged`/`syncCompleted`. This is the `smartPlaylistFolderRules` feature. |
| `customOrderLastInsertedUuid` | 🔴 **LIVE.** Written at `PlaylistDataManager:591-595`, `PlaylistDetailViewModel:475`, `UpNextViewController:951/961/991`; read by `EpisodeFilter.insertMarkerIndex`. |
| `customOrderInsertMode` | 🟡 **One live writer** (`PlaylistDetailViewModel:537-539`, the no-session/no-lens fallback). Everything else uses `Session.insertMode`. Nearly orphaned, not orphaned. |
| `showArchivedEpisodes` | 🔴 **VERY LIVE** — 7 readers. Becomes redundant only once the preset's `includeArchived` rule replaces it. |

So "excise the inert columns for diff hygiene" is a **one-column job** (`newEpisodesAutoAdd`), not four. The
rest are entangled with folder rules and custom-order insert, which are out of scope for this rework.

## 2.2 The preset query builder needs **no** DataModel change; the smart-playlist page needs **one**

Good news: `DataManager.findEpisodesWhere(customWhere: String, arguments: [Any]?)` is **public**
(`DataManager.swift:518`), and the app **already** builds raw SQL — `EpisodesDataManager.createEpisodesQuery()`
(`:194`) returns a WHERE+ORDER string that `EpisodeTableHelper.loadEpisodes(query:arguments:)` executes.

⇒ **`FilterPreset -> (whereFragment, args)` is a pure Swift function in the app target.** The
"app doesn't link GRDB" landmine does not bind the query builder at all. It binds only
`playlistEpisodeUuids(for:)`.

Bad news: `PlaylistQueryBuilder.query(...)` returns a **full SELECT with CTEs**, not a fragment — so the
smart-playlist page cannot AND a preset onto it from outside. You need an `extraWhere:` parameter.
That's ~6 lines, following the identical pattern the existing `searchTerm` uses at `:274`
(`let searchClause = mainQueryHasWhere ? "AND" : "WHERE"` — the builder already tracks `mainQueryHasWhere`
precisely for this).

**Two DataModel changes, not one.** Both tiny.

## 2.3 There is **no cascade** — you have to write it

- Episode deleted → `EpisodeDataManager.delete` (`:884-892`) only touches `SJEpisode`. `SJPlaylistEpisode`
  rows are **orphaned**, forever, and still count toward `MAX(episodePosition)` and toward the 1,000 cap.
- Podcast unsubscribed → `PlaylistManager.handlePodcastUnsubscribed` (`:115-130`) only strips uuids from
  *smart* playlists' `podcastUuids`. It never touches membership rows.
- **And membership actively blocks cleanup**: `PodcastManager.deletePodcastIfUnused` bails if
  `playlistContainsPodcast(podcastUuid:)` (`PodcastManager+Cleanup.swift:15`). So an unsubscribed podcast
  with Inbox members is **never** cleaned up. The Inbox would pin dead podcasts in the database indefinitely.

⇒ Cascade-on-unsubscribe is **mandatory**, not a nicety.

## 2.4 There is **no unseen dot** today — nothing to reuse, but a clean template exists

`EpisodeCell` (745 LOC) has **no dot of any kind**. Played/archived state is expressed only by alpha
dimming (`playedAlpha = 0.5`, `:306-312`).

The template is the fork's own `setSessionIndicator` (`EpisodeCell.swift:613-637`): a lazy `UIImageView`
inserted into the existing "Info Stack View" next to `upNextIndicator`, with a `prepareForReuse` reset.
A **trailing** unseen dot is ~25 LOC on the same pattern. A **leading**, Mail-style dot needs a XIB change
(new leading imageView + width constraint) — more expensive, and worth deciding deliberately.

Both `cellForRowAt` sites already compute per-row context (`PodcastViewController+TableData.swift:164`,
`PlaylistDetailViewController+TableView.swift:161-162`), so the "fetch the member `Set` once per list load"
rule has an obvious home.

## 2.5 Two consumers the design never mentions

- **The Up Next filter has a "hide seen" mode**: `UpNextViewController.swift:472` — `.filter { !$0.isSeen }`.
  It remaps to `.filter { inboxMembers.contains($0.uuid) }`. Small, but it's a live dependency.
- **A per-podcast global-Inbox opt-out already exists**: `SessionFeederEngine.optOutPodcastUuids()` /
  `SJGlobalInboxOptOutPodcasts`, toggled from `PodcastSettingsViewController+Table.swift:455`. The new design
  has no home for it. Natural fit: keep it, and implement it as "never advance `offeredThrough` for this
  podcast, never offer" — one `if` in the drain.

`isSeen` has only **9 call sites** total, so the remap itself is cheap.

## 2.6 `showArchivedEpisodes` — yes, superseded, but check *why* before deleting it

It has 7 readers, and the important question is whether any of them is **behavioural** rather than
display — because the preset is a *global, sticky, transient lens*, and a lens must never change what the
app does in the background. If a preset could change what auto-downloads, that would be a bad bug.

Checked all seven:

- **Display:** `EpisodesDataManager:255`, `PlaylistDetailViewModel:422`, `PlaylistDetailViewModel+Archive:5/27`
  (the Show Archived toggle itself), `PlaylistCellViewModel:168`, `PlaylistMetadataLoader:368` (cell artwork).
- **Behavioural:** `PlaybackManager:952` — but this is `play(playlist:)`, i.e. **Play All**, not
  auto-download. And `Settings:1842` — the fork's own feeder-domain query for `.smartPlaylist` sessions.

**Nothing reads it for auto-download.** So there is no lens-changes-background-behaviour hazard.

And the column becomes *constant-false* the moment the funnel dies: the only writer is the Show Archived
toggle (`PlaylistDetailViewModel+Archive:27`), which the preset picker replaces. A column nothing writes is
dead weight.

⇒ **Delete `showArchivedEpisodes`** and revert its six readers to stock (`shouldShowArchived: false`).
Archived visibility on the Episodes tab becomes the preset's `includeArchived` rule; Play All and the
feeder domain go back to stock semantics (archived excluded), which is what they should have been.

That makes the column excision **two** columns (`newEpisodesAutoAdd` + `showArchivedEpisodes`), not one and
not the four you listed. `folderUuids`, `customOrderInsertMode` and `customOrderLastInsertedUuid` stay —
they are live (§2.1).

## 2.7 Deleting `FeatureFlag.sessions` is 30 sites, not a rewrite

30 call sites across 16 files, all mechanical (delete the gate, keep the ON path). The OFF path does not
delete anything — the 2,517-line Sessions module still compiles and is referenced from 43 files either way.
So "delete the flag" (make the fork unconditional) is cheap and shrinks the surface every later stage has
to reason about. Do it early.

Note the coupling: `playbackSessions` (43 sites) and `globalInboxTab` (2 sites) both **default to**
`FeatureFlag.sessions.enabled` (`FeatureFlag.swift:424,:428`), so deleting `sessions` forces a decision on
both. `episodesFunnel` (6 sites) should die **with** the preset picker, not before it — otherwise the
Episodes tab has no filter at all for several stages.

`customTabBar` is 1 site (`MainTabBarController.swift:108`) — keep if it's a real preference.

Badge types are safe: `Settings.podcastBadgeType()` reads **UserDefaults only** (`Settings.swift:69-82`).
The fork's raw values 3/4/5 do **not** ride the server-synced `AppSettings.badges`.

---

# Part 3 — Answers to the open questions

## Q1. The counts line

Today it's a 3-way switch (`triageCountsText()`, `PlaylistDetailViewController+TableView.swift:452-474`;
`EpisodeListSearchController.updateInfoView`, `:114-179`). With two tabs:

- **Episodes tab** → `"N episodes"` where **N is the count *after* the preset and search** — i.e. it
  describes what is actually on screen. Append `" • M unseen"` when M > 0.
  **Drop `" • M archived"`.** Archived is a preset rule now, and the preset control is labelled, so the
  "silently withholding things" anti-pattern is already closed by the label. Keeping a separate archived
  counter would be a second, drifting encoding of the same fact — exactly Castro's warning.
- **Session tab** → `"N episodes • Xh Ym"`. Playtime is the meaningful number for a lineup; keep it.
- **Global Inbox tab** → `"N unseen • Xh Ym"`, plus a warning when N approaches the 1,000 cap (§1.2).
- **Hide at 0** everywhere (both surfaces already do this).

## Q2. Multi-select actions

All four remap cleanly. Every one is a **bulk verb**: one DB call, one `playlistChanged`.

| Action | New implementation |
|---|---|
| `markAsSeen` (20) | `DataManager.deleteEpisodes(uuids, from: inbox)` — **already** one `DELETE ... IN (...)` + one reindex pass (`PlaylistDataManager:249-260`), and it already marks the playlist dirty. Then one `playlistChanged`. ✅ |
| `markAsUnseen` (21) | `DataManager.add(episodes:to: inbox)` + `markStoreChanged`. ⚠️ Watch the 1,000 cap — and see the conflict below. |
| `addToSession` (18) | Unchanged (`SessionManager.addToSessions`), plus a **leaf** Inbox removal, batched. |
| `removeFromSession` (19) | Unchanged. Does **not** re-add to the Inbox (your decision). Dismissal recording dies with dismissals. |

### ⚠️ A conflict the design has not noticed: mark-unseen vs. "any playback progress removes"

You decided *"any playback progress (`playedUpTo > 0`) removes from the Inbox"* **and** *"recovery = mark it
unseen, which re-adds it"*. Those two rules fight: mark-unseen re-adds an episode with `playedUpTo > 0`, and
the very next sweep on `episodePlayStatusChanged` removes it again. The dot would flicker and vanish.

The current code already solves this and **the behaviour is load-bearing** —
`EpisodeSeenManager.freshenForUnseen` (`EpisodeSeen.swift:53-69`) *unplays and unarchives* on mark-unseen,
because "unseen" means "fresh again". **Keep that.** Mark-unseen must clear progress and unarchive, or the
only recovery path in the entire design is broken. (Clearing dismissals goes away with dismissals.)

## Q3. What breaks — the things not already covered above

1. **The 1,000-member cap** (§1.2). The most serious. Silent, invisible, and it breaks the feature's one
   promise.
2. **The O(n²) sync import** (§1.5). Will make syncing feel broken once the Inbox has a few hundred members.
3. **The ~20 leak surfaces** (§1.3), including the widget picking the Inbox as its filter.
4. **No cascade** (§2.3) — and Inbox membership *pinning unsubscribed podcasts alive* in the DB.
5. **The `Session` decode landmine** (§1.7) — already armed, today.
6. **`add()` not marking dirty** (§1.6) — silent non-sync.
7. **Mark-unseen vs. progress-removes** (Q2) — the recovery path.
8. **`PodcastViewController.subscribe()` fires no `podcastAdded`** (`:1040-1062`) — the most common subscribe
   gesture in the app posts *no notification at all*, while `podcastAdded` *does* fire N times during a
   full sync (where it must not feed the Inbox). ⇒ **Do not hook subscribe.** Use the lazy rule instead:
   *"a subscribed podcast with no `offeredThrough` entry is a new subscription"* → apply the Inbox setting,
   set the watermark. It is idempotent, it covers every subscribe path including the silent one, and it
   needs a one-time `bootstrapped` flag to distinguish first-run (watermark everything, add nothing) from a
   genuinely new subscription.
9. **`inSession` going global changes `unseen ∧ inSession` to always-empty** — you flagged this as
   consistent, and it is. But note the *other* half: an episode in **any** session no longer shows a dot
   anywhere, including on an unrelated smart-playlist page. That's the intent; just be sure it's the intent.

---

# Part 4 — Staged plan

Each stage builds and is verifiable on its own. Costs are honest and include the deletions.

### Stage 0 — Decoder tests + testability ✅ **DONE**
Hand-written `Session.init(from:)`, `LenientlyDecoded` element wrapper, `SessionStore.init(fileURL:)`,
8 tests in `PocketCastsTests/Tests/Sessions/SessionStoreDecodeTests.swift`. All green.
⚠️ The Makefile passes `-only-testing:` once — a comma-separated list matches zero tests **and still reports
`** TEST SUCCEEDED **`**. Run each suite separately.
*(When `InboxStore` and `FilterPresetStore` land, each gets the same 8-test treatment. The pattern is now
established; copy the file.)*

### Stage 1 — Feature-flag cleanup ✅ **DONE**
Deleted `FeatureFlag.sessions`, `playbackSessions`, `globalInboxTab` — **77 call sites across 24 files**
(more than the 30 first counted; `playbackSessions` alone was 43). `episodesFunnel` deliberately kept until
Stage 8, so the Episodes tab keeps a filter until the preset picker replaces it. `customTabBar` kept (1
site — a genuine layout preference).
Build green, `PocketCastsTests` 370/370, `PocketCastsDataModelTests` unchanged at 461/463.
Net −36 lines. `make format` run.

Notable collapses (the OFF paths were resurrecting stock code, exactly as predicted):
- `Settings.strippingSessionActions` was the identity function → deleted, 8 call sites unwrapped.
- `UpNextViewController+Table`: `viewForHeaderInSection` → always `nil`; `heightForHeaderInSection` → one
  line; `refreshSections` lost its stock branch. The queue header is a scrolling *row* now, not a pinned
  header.
- `PlaylistDetailViewController+PlayAll`: Play All **is** Play as Session; the stock replace-the-queue flow
  is gone.

**Orphaned by the removal, deliberately left in place:** `PlaybackManager.playIfSafe`, the
`PlaylistPlayAllSheet`/`Host` trio, `L10n.playlistsPlayAll`. These are *stock* code — leaving them dormant
keeps the upstream diff smaller than deleting them would. `UpNextViewController+Table.queueHeaderHeight` is
fork code and now dead; sweep it in Stage 11.

### Stage 2 — DataModel foundations ✅ **DONE**
1. ✅ `DataManager.playlistEpisodeUuids(for:) -> Set<String>` — membership without hydrating Episodes.
2. ✅ `PlaylistQueryBuilder.query(extraWhere:)` + a **separate** `playlistEpisodes(for:matching:arguments:)`
   overload. The stock 3-arg signature is left untouched on purpose: `SyncTaskPlaylistOrderingTests`
   subclasses `DataManager` and overrides it, and every added parameter widens the upstream diff.
3. ✅ `DataManager.inboxPlaylistUuid` (a fixed UUID constant) + the chokepoint in `PlaylistDataManager`:
   `allPlaylists` / `allManualPlaylists` / `allSmartPlaylists` / `count` all exclude it. `allUnsyncedPlaylists`
   and `findBy(uuid:)` deliberately do **not** — so the Inbox syncs and the fork can still fetch it.
4. ✅ `applyEpisodeOrder(_:for:)` — one pass, writes nothing when the order already matches. Sync import now
   calls it instead of `moveEpisode` per episode (O(n²) → O(n)), and **skips the Inbox entirely**.
5. ✅ Cascade on episode delete + delete-all-in-podcast, scoped to `playlist_uuid IS NOT NULL` so the Up Next
   queue (which shares the table and has its own sync) is untouched.
6. ⏭️ **`showArchivedEpisodes` moved to Stage 8.** Deleting it now would leave manual playlists unable to
   show archived episodes until the preset picker exists — the same regression window that made me defer
   `episodesFunnel`. It is a display column; it should die *with* the funnel, not before it.

12 new tests in `Modules/Tests/PocketCastsDataModelTests/InboxPlaylistFoundationsTests.swift`, each run
against both the SQL and GRDB backends. DataModel 473/475 (the 2 pre-existing transcript failures),
Server 94/94, app 370/370, build green.

⚠️ **Gotcha found while testing:** a bare `EpisodeFilter()` is **not** a match-everything smart playlist.
`filterDownloading` is `@GRDBIgnore`-hardcoded `true` while `filterDownloaded`/`filterNotDownloaded` default
to `false`, so the builder emits a download-status clause that matches almost nothing. All three on (or all
three off) is what leaves the block unconstrained. This will bite the preset query builder in Stage 7.

**Still owed from this stage:** the *unsubscribe* half of the cascade. Removing a podcast's episodes from
the Inbox needs the Inbox playlist to exist, so it lands with `InboxManager` in Stage 3. Until then, an
unsubscribed podcast with Inbox members would keep itself alive (`deletePodcastIfUnused` bails on
`playlistContainsPodcast`).

### Stage 3 — `InboxStore` + the Inbox playlist + `offeredThrough` ✅ **DONE**
`InboxStore { offeredThrough }` (own file, own decode discipline) and `InboxManager` (the engine),
`InboxManager.drain()` hooked into `ServerSyncManager.performActionsAfterSync()`, and `SessionCloudSync`
extended with a `ForkOfferedThrough` record type — without which §1a is inert.
20 new tests (8 decode, 12 engine). Build green; app 390/390, DataModel 473/475, Server 94/94.

🟢 **The first-run bootstrap turned out to be unnecessary — the rule collapsed.** The plan had a special
case for first launch (watermark every podcast, seed nothing). But once "never fill a backlog into the
Inbox" was decided, *first run*, *full sync*, *OPML import* and *a brand-new subscription* are all the same
situation: **a subscribed podcast with no `offeredThrough` entry**. One rule covers all four — draw the line
at its newest episode, offer nothing. So there is no bootstrap flag, no first-run branch, and the
"never hook episode-inserted" hazard is now structurally impossible rather than carefully avoided.

Two things worth remembering:
- **The watermark is monotonic.** It never retreats, including for values arriving from CloudKit. A lower
  value can only mean a stale device or a stale record, and honouring it would re-offer episodes already
  triaged away — the exact flood the whole mechanism exists to prevent. Two tests pin this.
- **Mark-unseen unplays and unarchives**, and that is load-bearing, not a nicety: any playback progress
  removes an episode from the Inbox, so re-adding one that still carries progress would be swept straight
  back out. It is the only recovery path in the model. A test asserts the sweep cannot undo it.

The **unsubscribe cascade** owed from Stage 2 landed here too: `podcastDeleted` clears the podcast's Inbox
members (membership would otherwise pin it alive — `deletePodcastIfUnused` bails while any playlist contains
it) and forgets its line, so a re-subscribe draws a fresh one rather than replaying history.

⚠️ **Nothing renders it yet.** The Inbox playlist fills and empties correctly but is invisible: the old
`EpisodeSeen`/`SessionFeederEngine` model still drives every surface. Both models run in parallel until
Stage 4 switches the UI over and deletes the old one.

### Stage 4 — Seen becomes membership ✅ **DONE**
**−415 lines net** (21 files: +193 / −608). Build green; app 390/390, DataModel 473/475, Server 94/94.

- ✅ `EpisodeCell.setUnseenIndicator` — an accent dot in the existing info stack, mirroring
  `setSessionIndicator`. Both list surfaces fetch the member `Set` **once per load**
  (`cachedUnseenUuids` / `unseenUuidsForDisplay`); no cell ever queries membership.
- ✅ `SessionFeederEngine` re-pointed at Inbox membership. **This deletes the fork's worst hot path**:
  `inboxEpisodes` was a full playlist query *per session* plus a Swift filter over every unarchived episode;
  `allStoreMemberUuids` ran a query *per session* and the playlists list re-ran it *per row*. Both are now
  single indexed queries (`playlistEpisodeUuids(forPlaylistUuids:)`, `playlistEpisodeCountsByPodcast`).
- ✅ Add-to-Session clears the dot — as a **primitive** call (`InboxManager.markSeen`), not a verb, so the
  Up Next ⇄ Session mirroring stays two-party with the Inbox as a leaf and recursion stays impossible.
- ✅ **Deleted:** `EpisodeSeen.swift`, `DismissedEpisodesView.swift`, `SessionStore`'s `seenMarks` /
  `unseenMarks` / `clearedThrough` / `dismissals` (the Document is now just `{ sessions }`), `prune()`,
  `SessionFeeder.inboxKey`, and the `ForkSeenMark` / `ForkUnseenMark` / `ForkWatermark` / `ForkDismissal`
  CloudKit record types. Removing an episode from a Session no longer makes it unseen.

⚠️ **Also removed the Episodes-tab partition** (`EpisodesDataManager.applyDisplayFilters` no longer hides
Inbox members). This was scheduled for Stage 6, but it had to move: the partition hid exactly the episodes
the new dot marks, so the dot would have been invisible. Running a partition *and* a dot over the same bit
is precisely the drift hazard in the UI research — the dot is the one that survives. The per-page Inbox tabs
still exist until Stage 6 and now show the same (dotted) episodes; redundant for one stage, but not drifting,
since both read the same membership set.

🔶 **Behaviour change to confirm: queuing an episode no longer clears its dot.** The old model treated
"in Up Next" as decided and hid it from every inbox. The new spec's removal list (progress / archived /
added-to-Session / triage / deleted) does not include queuing. So an episode queued *without* Up Next ⇄
Session mirroring keeps its dot until you play it. Coherent — the Inbox is about attention, Up Next is a
lineup — and with mirroring on the chain still clears it. But it *is* a change, and it was not stated.

### Stage 5 — Global Inbox tab re-points at the playlist ✅ **DONE**
`InboxViewController.allEpisodes` is now `InboxManager.unseenEpisodes()` — one indexed read of the Inbox
playlist, newest first, instead of a domain sweep over every unarchived episode of every subscribed podcast.
The tab badge and app badge are `unseenCount()`, a **count query** that never materialises the episodes.
Both surfaces now observe `playlistChanged` (membership *is* the list). Bulk verbs were already batched
(`markSeen` = one DELETE + one notification; `bulkArchive` + the sweep). Group-by-Podcast already existed
on this tab, so §1's grouping requirement was already met. Opting a podcast out now also **clears what it
already put there** — otherwise the switch reads as "stop offering" but leaves a pile nothing will refill.
App 393/393, DataModel 473/475, Server 94/94, build green.

### 🔶 Queuing: DECIDED, and subtler than it looked
**Queuing an episode clears its dot — but as an EVENT, not a STATE.** The distinction is load-bearing.

The obvious implementation (the sweep treats "is in Up Next" as decided) is **wrong**, and it breaks the
thing you actually want: a podcast set to **auto-add-to-Up-Next** delivers episodes that are *already queued*
when they arrive. You want those to still come through the Inbox — it is the complete record of what turned
up, and Mark All as Seen is how you clear it once you've watched it go past. A stateless "is it queued" check
in the sweep would strip their dots the next time anything at all changed.

So: the drain does **not** exclude queued episodes, the sweep does **not** look at the queue, and a
`upNextEpisodeAdded` observer clears the dot for the episode you just queued. The ordering makes it work by
construction — auto-add runs at `RefreshOperation:97`, *before* the drain at `:99`, so an auto-added episode
isn't in the Inbox yet when its notification fires (no-op), and the drain offers it moments later.
One-directional, like every other decision: taking an episode back out of Up Next does not make it unseen.
Three tests pin all three cases.

### Stage 6 — Two tabs  · ~250 LOC deleted · blast radius: 5 files
Drop the Inbox tab from `PodcastDetailsTabView:113-122` and `PlaylistHeaderView:134-143`; remove
`EpisodesListMode.inbox`, `loadInboxEpisodes`, the inbox footer, `TriageTab.new`. New counts line (Q1).

### Stage 7 — `FilterPreset` model + query builder  · ~350 LOC + ~200 test LOC · blast radius: new files only
Pure function `(FilterPreset) -> (String, [Any])` in the **app target** (§2.2 — no module change).
Correlated `EXISTS`/`NOT EXISTS`, never `NOT IN`. Genuinely unit-testable with zero UI.

### Stage 8 — Preset picker + delete the funnel  · ~250 LOC added, ~200 deleted · blast radius: 6 files
The single labelled control. Delete `EpisodeStateFilter.swift` (155 LOC), its 8 call sites, the
`episodesFunnel` flag, the `SJEpisodesFilterOn` key from `ForkSettingsSync`, and 8 L10n keys.

### Stage 9 — Preset editor  · **~1,200–1,500 LOC** · blast radius: new files only · **the main expense**
Copy the SwiftUI rules layer (~719 LOC: `SmartPlaylistRulesView` 221, `SmartPlaylistRulesSectionView` 242,
`PlaylistPreviewViewModel` 186, `SmartPlaylistRule` 58, `SmartPlaylistRuleInfo` 12) + the reachable pushed
editors (`FilterDurationViewController` 242 + XIB, `EpisodeFilterOverlayController` 147,
`FilterSettingsOverlayController` 71 + XIB).
**Drop `PodcastFilterOverlayController` (532) and `PodcastChooserViewController` (166) + XIBs** — the podcast
picker is exactly the row you're removing, and it's the single biggest file. That's why this lands nearer
1,200 than 2,000.
Add the seen and session rows as inline pickers (the cheap kind — `SmartPlaylistRulesSectionView` already
hosts four of them).

### Stage 10 — Inbox settings  · ~80 LOC · blast radius: 2 files
Now much smaller: **no back-catalogue options at all** (decided — never fill a backlog into an Inbox).
Just the per-podcast opt-out (§2.5) and the existing add-to-Session mode.

### Stage 11 — Hygiene  · ~100 LOC deleted
Drop `newEpisodesAutoAdd` (§2.1). Dead strings. `Session.groupBy`/`groupLimit`. Update `CLAUDE.md`'s stale
module paths. (`showArchivedEpisodes` already went in Stage 2.)

---

**Total: roughly 11–13 focused days.** Stage 9 is a third of it, as you predicted. Stages 2–3 are the ones
that determine whether the whole thing is sound; stages 5–6 are where it starts to feel like the design.
