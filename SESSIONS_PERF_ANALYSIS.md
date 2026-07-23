# Sessions — Performance & Robustness Analysis

_Static audit of the fork's Sessions feature (data model, list builder, add/remove/reconcile,
and the Queue-tab UI). Findings are from code reading and should be confirmed with Instruments
before/after each change. Line numbers are against the working tree at time of writing._

## Verdict

The feature is **functionally solid and defensively written** (good `[safe:]` usage, guarded optionals,
sensible decode fallbacks, played/archived invariants enforced on both read and write). The problems are
**not correctness-of-logic** — they're **cost and concurrency**: single-item changes trigger whole-collection
rewrites and whole-list rebuilds, most of it synchronous DB work on the main thread, fanned out across
uncoalesced notifications. At today's scale (a handful of sessions) it's fine; it degrades linearly — and in
two places quadratically — with the number of sessions and total episodes.

One real correctness bug and two latent ones were found (see Bugs).

---

## Implementation status (updated)

**Done** (shipped to device; compiles clean):
- **B1** untappable last pool row — `willSelectRowAt` now maps through `sessionListIndex`.
- **B2** applyingRemote race — replaced the off-queue bool with atomic `applyRemoteUpsert`/`applyRemoteDelete`
  (single queue-confined transaction, no cloud echo, no shared flag). `SessionCloudSync` updated.
- **B4** corrupt-store quarantine — `load()` moves an undecodable file to `sessions.corrupt.json` before
  any write can overwrite it with an empty doc.
- **B5** dup-uuid trap — cloud diffs use `Dictionary(_, uniquingKeysWith:)`.
- **RC2** `reorderSessions` O(n²) → O(n) via a uuid→offset map.
- **RC4 / 1.5** per-session membership query → the existing bulk `allStoreMemberUuids()`.
- **F3** `mutate` skips the file write, cloud diff, and change notification when the document is unchanged.
- **F6** cloud `record(for:)` O(n²) → sessions snapshot indexed once per batch.
- **Phase 2** builder: **F5** O(sessions²) smart-playlist coverage → precomputed `Set` once; **F7** hoisted
  the per-session Settings read; **F4** deduped the double `findPlaylist` (reuses the fetched store filter).
- **Phase 1**: reload **coalescing** (`setNeedsReload` collapses the `upNextChanged`/foreground storm into one
  reload per runloop) and **search-in-place** (`deriveSessionListRows` re-filters the cached source — no
  per-keystroke DB rebuild).
- **Phase 3 (safe part) / C2**: `mutateSession` batches the compound store writes (lastInserted + pins/unpins)
  into one transaction that re-reads the live row — one save + one cloud diff, and no stale-snapshot clobber.
  `addToLineup`/`replaceLineup` routed through it.
- **E1 / C1** atomic lineup add: new `DataManager.insertSessionMembers` does read → insert-at-the-session-marker →
  rewrite → denormalize title/podcast → mark-for-sync in ONE transaction, replacing `addToLineup`'s racy
  read + `add()` + `setCustomOrder` trio. It uses the SESSION's own marker (not the playlist's) and preserves
  the `notSynced` marking. **Validated**: `SessionAutoAddIngestTests`, `SessionDirectAddPinTests`,
  `SessionTrueTopOrderTests` all green; the swap also orphaned `SessionManager.insertMarkerIndex` (removed).
- **Phase 5 (partial)**: removed dead `insertMarkerIndex` + `sessionListControlsThreshold`; fixed the misleading
  "search row hidden in reorder" comment.

**Resolved: active-first rule removed (option C).**
- The comparator's active-first rule (`isActive && !sessionPaused` → active session hoisted to the top of
  `SessionListRows.current`) is **removed** — `current()` is now a pure sorted builder. Rationale: the Queue
  surfaces the current session via its own row-1 extraction (so hoisting here double-handled it and reshuffled
  the pool on activation), and the two direct `.recentlyPlayed` consumers (Switch Session sheet, CarPlay)
  already float the playing session up via `lastUsed` (bumped to now on `playbackStarted`) — so no per-consumer
  hoist was needed. This also fixes the sort-baking call, which previously baked the active session to the top
  of the saved manual order. The test suite was internally inconsistent (`testOpeningASessionDoesNotReorderTheList`
  said "no hoist", `testPlayingSessionSurvivesAFilterThatWouldExcludeIt` said "still leads"); resolved in favour
  of no-hoist. **All 25 `SessionListRowTests` green.**

**Deferred (with reason — need runtime validation or are high-risk-blind):**
- **F3-builder-off-main** (move the per-session DB reads off the main thread): the single biggest remaining
  item and the riskiest (async hand-off, stale-UI/race potential). Do it AFTER an Instruments trace confirms
  it's still the bottleneck once coalescing + de-quadratic + caching have landed.
- **Phase 4 deep** (funnel ALL store-order mutations through one queue/actor): architectural; the add path is now
  atomic (E1), so the remaining exposure is the reconcile/remove interleave — sequence this next if a trace shows it.
- **Phase 5 remainder** — the index-math centralization (one `table-row ↔ list-index ↔ placement` type) and the
  rest of the dead code (unreachable chooser empty cell, `upNextShowsSessionHeadRow=false` branches): B1 removed the
  live bug; the centralization is a maintainability refactor to schedule on its own.
- **F8** (byName fold key), **F11** (single CloudKit order record), schema `version` field: low value / bigger
  change — skipped for now.

---

## Root-Cause Analysis

Four root causes explain ~90% of the findings.

### RC1 — No line between "data changed" and "redraw"; every notification does a full rebuild
`reloadTable()` unconditionally runs `refreshSessionMembership()` **and** `refreshSessionState()`
(→ `SessionListRows.current`, which does O(sessions) DB work) **and** `reloadData()`. About a dozen
observers funnel into it, **uncoalesced** — and `upNextChanged` re-dispatches async so the passes don't
even collapse. A single user action (play a session episode) fires `playbackTrackChanged` +
`playbackStarted` + `playbackSessionChanged` → **up to 3 full rebuilds**, each O(sessions × episodes) DB on
the main thread. Presentation-only reloads (theme change, `didBecomeActive`, an archive swipe) rebuild the
entire model too, even though the session set can't have changed.

### RC2 — Single-item changes rewrite whole collections
- **Store:** every mutation re-encodes the *entire* JSON document + atomic file write + a CloudKit diff
  (`save()` on every `mutate`). A single `lastUsed` stamp rewrites all sessions.
- **Lineup:** adding/removing one episode does `add()` (per-episode DELETE+INSERT) **then** `setCustomOrder()`,
  which is `DELETE FROM playlistEpisode WHERE playlist=?` + re-INSERT of **every** position row — despite an
  existing incremental primitive (`insertIntoCustomOrder`).
- **Reorder:** `reorderSessions` is O(n²) (`firstIndex` in a loop); the CloudKit `record(for:)` snapshots the
  whole store *per record* → O(n²) again; and because reorder rewrites `sortIndex` on every shifted row, one
  drag enqueues O(n) CloudKit saves.

### RC3 — Concurrency is ad hoc: cross-thread read-modify-write guarded by non-atomic bools
`addToLineup`/`removeFromLineup` read the full order, compute, and write it back — from **both** background
queues (auto-add, `addToSessions`) and the main thread (reconcile, sweep, swipes) — with no serialization of
the read→write pair. A reconcile landing mid-sequence produces a lost update. Stale `Session` snapshots
passed to `upsert` clobber concurrently-changed fields. The `applyingRemote` and `isReconcilingFeeder` flags
are plain `Bool`s written off the store queue → a genuine local change can **silently skip its cloud diff**,
and re-entrancy is avoided only by an incidental uuid distinction.

### RC4 — The same derivations are computed several different (redundant) ways
Two separate caches of "episodes in any session" (a per-session loop in `+Table` vs the single grouped query
in `SessionMembership`); `findPlaylist(uuid:)` fetched twice per session per rebuild; podcast names via a
per-row `findPodcast`; smart-playlist coverage recomputed O(S²); and an **ambiguous ownership of lineup
order** between the store and the feeder (a guard comment claims the reconciler is order-authoritative; the
code makes it membership-only).

---

## Bugs

| # | Severity | What | Where |
|---|----------|------|-------|
| B1 | **High (correctness)** | Last pool session is **untappable** when the search bar is visible: `willSelectRowAt` uses the raw `indexPath.row` instead of `sessionListIndex(forTableRow:)`, so the last row's index overflows `sessionListRows` and returns `nil`. | `UpNextViewController+Table.swift:360` |
| B2 | **Med (sync)** | Lost cloud diff: `applyingRemote` is written off the store queue; a local mutation in the reset window observes `true` and never syncs. Also a TSan data race. | `SessionStore.swift:308,323-327` |
| B3 | **Med (latent)** | Store-vs-feeder **order desync**: `mirrorOrderIntoSmartFeeder` no-ops unless the feeder is drag-sorted, and the reconciler comment disagrees with what it actually does. Prerequisite risk for the deferred "top = current" feature. | `UpNextViewController.swift:1540-1551` |
| B4 | Low (robustness) | Corrupt store file → `try?` swallows the decode error, store stays empty, and the **next mutation overwrites the file with the empty document** (no backup/quarantine). | `SessionStore.swift:329-335` |
| B5 | Low (robustness) | `Dictionary(uniqueKeysWithValues:)` in the cloud diff **traps** on a duplicate-uuid document. | `SessionCloudSync.swift:170-171` |

---

## Phased Plan

Ordered by value-to-risk. Each phase is independently shippable; validate with Instruments (Time Profiler +
a reorder/scroll trace) before/after.

### Phase 0 — Correctness + one-line wins _(low risk, do first)_
- **B1**: map `willSelectRowAt` through `sessionListIndex(forTableRow:)` like every sibling method.
- **RC4**: replace `refreshSessionMembership`'s per-session loop with the existing bulk
  `SessionFeederEngine.allStoreMemberUuids()` (or read `SessionMembership.shared.inAnySession`) — deletes an
  O(sessions) DB pass from every reload.
- **RC2**: rewrite `reorderSessions` as one `[uuid: offset]` map + a single O(n) pass.
- **B5**: `Dictionary(_, uniquingKeysWith:)`. **B4**: quarantine a bad store file before the empty doc
  overwrites it.
- **Dead code**: `sessionListControlsThreshold` (unused), the unreachable chooser empty-state cell +
  `max(count,1)`, the `upNextShowsSessionHeadRow = false` branches, vestigial whitespace in `SessionCloudSync`.

### Phase 1 — Coalesce reloads & split "changed" from "redraw" _(biggest steady-state win)_
- One coalescing reload entry point: set a `needsReload` flag, do a single `reloadTable()` per runloop.
- Rebuild `sessionListRows` **only when the underlying data changed** (a generation counter bumped by
  `SessionStore` mutations + relevant playlist writes); presentation-only reloads reuse the cached rows.
- **Search filters the cached rows in place** — never re-enter `SessionListRows.current` per keystroke.

### Phase 2 — De-quadratic the builder & get its DB work off the main thread
- Precompute the smart-playlist-covered podcast set **once** before the per-session loop (kills the O(S²)).
- Dedupe the double `findPlaylist(uuid:)`; resolve podcast names from an in-memory map instead of per-row
  `findPodcast`; precompute a folded `byName` sort key on `Entry`.
- Move the per-session `orderedEpisodes` work to a background queue; hand the finished value-type
  `[SessionListRow]` back to the main thread. (Consider one bulk lineup fetch instead of N.)

### Phase 3 — Persistence & lineup write efficiency
- Route `addToLineup`/`removeFromLineup` through `insertIntoCustomOrder` (single transaction, O(shifted rows))
  — this also **closes the RC3 read-modify-write window**.
- Batch compound mutations (`upsert` + `pin` + `unpin`) into one `mutate` → one save + one diff.
- Debounce/coalesce `SessionStore.save()`; skip the write + diff when the document is unchanged.
- _(Optional, bigger)_ store session order as a single CloudKit "order" record so a reorder is one op, not O(n).

### Phase 4 — Concurrency hardening
- Funnel **all** store-order mutations through one serial queue/actor.
- Make `upsert` take a mutation closure that re-reads inside the store queue (kill the stale-snapshot clobber).
- Queue-confine `applyingRemote`; tag reconcile-originated `playlistChanged` posts instead of relying on the
  attached object; collapse the four copies of the reconcile skeleton into one `withFeederReconcile(_:)`.

### Phase 5 — Clean code & the deferred feature
- Centralize **table-row ↔ list-index ↔ placement** into one small tested type — removes the entire
  off-by-one class that B1 is an instance of. Collapse the two membership caches into one.
- Settle **store-vs-feeder order authority** (B3) — a prerequisite for reliability.
- Then build the deferred **"reorder-to-top makes the new top the current/playing episode"**: the active-session
  path is already ~built (`moveSessionEpisodeToTrueTop` primes the player before writing); the browsed-session
  case is a product decision (it would hijack playback) plus the RC3 fix.
- Add a guard test for the row/index mapping and a `version` field to the store `Document`.

---

## Notes / caveats

- These are **static** findings. The per-rebuild main-thread stall (est. tens–hundreds of ms at 30 sessions ×
  50 episodes) should be **measured on-device with Instruments** to prioritize Phase 1/2 vs Phase 3.
- Things that are **already correct** and shouldn't be "optimized" away: the per-second playback tick does
  **not** rebuild the list; `cellForRow` reads the cached array (no per-cell DB); the Set-based in-place update
  in `sessionPlayStateChanged` is sound; the persistent search-cell focus trick is safe; played/archived
  exclusion is consistently enforced.

_Detailed per-finding notes (with all file:line references) available on request — this is the synthesized plan._
