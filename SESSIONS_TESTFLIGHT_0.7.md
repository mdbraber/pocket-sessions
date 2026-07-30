# 0.7 (8.17.0.2) — what to test

Paste the short version into TestFlight's "What to Test". The rest is the
walkthrough: what changed, where to find it, and what "working" looks like.

---

## Short version (for TestFlight)

Lineups are now reordered rather than sorted — a session or playlist has one
saved order, and sorting rearranges it once. Podcast pages gained a Playlists
tab showing which of your lists that podcast appears in. The Queue world's ⋯
moved to the top right and Last Played now ranks on session history. New-episode
notifications recover episodes Pocket Casts' refresh would otherwise never hand
over. Plus fixes for the flickering nav bar, the disappearing keyboard, and an
untappable Cancel button.

---

## 1. Reordering lineups (the big one)

**Where:** a session's details, or a manual playlist.

Sorting a lineup used to look like a display setting layered over some "real"
order. It wasn't — there is only ever one saved order.

- Open a session → ⋯ → **Sort**. Pick any option. The list rearranges **once**,
  and that becomes the saved order. There is no sticky sort mode to come back to.
- ⋯ → **Reorder Episodes** gives drag handles for doing it by hand.
- The currently playing episode sits at position 0 and stays there.

**Check that:** a podcast's **Episodes** tab still behaves the old way — its sort
IS a display preference and should stick between visits. If browsing a podcast
started rearranging things permanently, that's a bug.

## 2. Playlists tab on a podcast page

**Where:** any podcast → the tab bar under the artwork.

Answers "which of my lists is this podcast in?" without opening each one.

- Grouped by kind: **Smart Playlists**, **Manual Playlists**, **Smart Playlist
  Sessions**. Headings collapse by tapping, like the Episodes tab's Group By, and
  stay collapsed per podcast.
- The number on each row is how many of **this podcast's** episodes that list
  holds — not the list's total.
- ⋯ offers **Sort By** (Title A–Z / Z–A), **Group By** (Type / None) and
  **Show Smart Lists**.
- Tapping a row opens that playlist.
- A podcast in nothing says so, and the wording changes with the Show filter —
  "Not in any playlists" / "…any sessions" / "…any playlists or sessions". A
  search that matches nothing says *that* instead, rather than claiming the
  podcast is in nothing.

**Note:** the podcast's own session is deliberately absent — it already has its
own Session tab.

## 3. Queue world

- The **⋯ moved to the top right**, matching the Playlists world, and includes an
  **Empty Up Next** hide/show toggle.
- **Last Played** now ranks on when the *session* was last played. Previously one
  episode shared by several sessions floated all of them to the top.
- **Searching inside a session** matches the podcast name as well as the episode
  title — useful when a session mixes shows.

## 4. Podcasts world

"Edit Podcasts" is now **Reorder Podcasts**, lives under Sort By, and only
appears when the sort is **Drag and Drop** — under any other sort it did nothing.

## 5. New-episode notifications that actually arrive

Pocket Casts' refresh service keeps a per-device record of what it has already
delivered. If an episode was handed over once and not stored, the app could never
fetch it again: it would refresh forever and be told, correctly, that there was
nothing new.

Now, when a notification names an episode that isn't in the app, it re-asks for
that podcast from an older anchor, which retrieves it.

**Check that:** tapping a new-episode notification opens the episode rather than
the podcast, and Download / Play Now / Add to Up Next from the notification act
on a real episode. This works on Pocket Casts' own episode pushes too, with or
without a sessions server configured.

## 6. Fixes worth confirming

| Fix | How to see it |
|---|---|
| Nav bar no longer flickers | Press play/pause repeatedly on the Sessions screen — the title should stay put |
| Keyboard stays up | Type in either Queue search box; it should not drop and return per keystroke |
| Cancel is tappable | Queue world search → Cancel (its tap target was 4pt tall) |
| Playlist settings | "Position in Session" moved out of the ⋯ sheet into playlist settings |
| Podcast group sheet | Clearer session verbs; session actions hidden for podcasts you don't follow |
| Add to Playlist naming | From a group header, the suggested name follows the route (e.g. "Serial — Season 2") |
| Synchronization settings | Shows the linked Pocket Casts account with **Unlink**; signing in as a different account pulls automatically |

## 7. Removed

**Folder sessions are gone.** A smart playlist scoped to a folder does the same
job and can be edited, so folder feeders were dropped rather than kept as a
second way to say the same thing.

**If you had one**, it will not survive the update — the session disappears
rather than migrating. Nothing else is affected: podcast sessions, smart-playlist
sessions and manual sessions are untouched. Recreate it as a smart playlist
scoped to that folder, then make it a session.

---

## Known limits

- A notification arriving on a **locked phone that you don't tap** recovers a
  little later — on the next foreground push, tap, or launch — rather than
  instantly. iOS doesn't run app code for an untapped banner.
- The Playlists tab has no bulk "add this whole podcast to a playlist" action;
  the ways into a playlist live on the episodes themselves.
