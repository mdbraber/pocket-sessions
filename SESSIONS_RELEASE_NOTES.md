# Sessions fork — release notes

Marketing version = the sessions version; build number = the stock base it was
cut from (TestFlight shows e.g. "0.7 (8.17.0.2)").

## 0.7 — 2026-07-30 (base 8.17.0.2)

**Lineups are reordered, not sorted.** A session or manual playlist has ONE saved
order. The old sort overlay implied a display preference sitting on top of a
"real" order; there is no such thing. Sorting a lineup now re-arranges that saved
order once, and "Reorder Episodes" gives you drag handles to do it by hand. The
episode lists you merely browse (a podcast's Episodes tab) keep their sticky sort
as before — that genuinely is a display preference.

**A Playlists tab on every podcast page.** Answers "which of my lists is this
podcast in?" from the podcast's side, instead of opening each list to find out.
Rows are grouped by kind (Smart Playlists, Manual Playlists, Smart Playlist
Sessions) with the same collapsible headings as the Episodes tab's Group By, and
counts show how many of THIS podcast's episodes each list holds. Sort by title,
group by type or not at all.

**Queue world.**
- The ⋯ moved to the top right, matching the Playlists world, and gained an
  "Empty Up Next" hide/show toggle.
- "Last Played" now ranks sessions on when the SESSION was last played, not on
  the progress of episodes inside it — one shared episode no longer floats every
  session that contains it to the top.
- Searching within a session matches the podcast as well as the episode title.

**Podcasts world.** "Edit Podcasts" is now "Reorder Podcasts", sits under Sort By,
and appears only when the sort is Drag and Drop — it did nothing under any other
sort.

**New-episode notifications are more reliable.** Pocket Casts' refresh service
keeps a per-device record of what it has already delivered, so an episode handed
over once but not stored could never be fetched again — the app would refresh
forever and be told, correctly, that there was nothing new. When a push names an
episode that isn't there, the app now re-asks for that podcast from an older
anchor, which retrieves it. Works on Pocket Casts' own episode pushes too, with
or without a sessions server.

**Fixes and polish**
- The nav-bar title no longer flies in and the list no longer flickers when you
  press play or pause on the Sessions screen.
- Typing in either Queue search box no longer makes the keyboard drop and return
  on every keystroke.
- The search bar's Cancel button had a 4pt tap target and could not be tapped.
- Folder sessions are gone; a smart playlist scoped to a folder does the same job
  and can be edited.
- "Position in Session" moved from the ⋯ sheet to playlist settings.
- The podcast group sheet uses clearer session verbs and hides session actions
  for podcasts you don't follow.
- "Add to Playlist" suggests a name based on how you got there (e.g. "Serial —
  Season 2").
- Synchronization settings show the linked Pocket Casts account with an Unlink
  action; signing in as a different account now pulls automatically.
- The test suite no longer signs the running app out or writes to its database.

## 0.6 — 2026-07-29 (base 8.17.0.2)

**Your own sync server (Pocket Casts Sessions / PCS).** Sessions data — sessions,
seen episodes, filter presets — can now sync through a small self-hosted server
instead of iCloud, with the Pocket Casts account still handling podcasts,
progress, playlists and Up Next as always. Settings → Synchronization.

- **Setup is one step**: enter the server URL. The device links your Pocket
  Casts account through PC's device-pairing flow (this app approves the code
  itself) and receives its own server token automatically. No password and no
  token ever leaves the device, and nothing has to be typed in.
- **Push-based cross-device sync**: a change on one device wakes the others
  within seconds instead of waiting for the next launch.
- **New-episode notifications** — the server watches your subscriptions and
  sends them, per the per-podcast notification toggles you set in the app.
  (Stock Pocket Casts pushes can't reach a fork build at all, so this is the
  fork's own replacement.)
- **Follow Now Playing** (off by default): idle devices adopt the session
  playing elsewhere and prime its episode, paused at the synced position.

**Podcast settings now sync (speed, playback effects, skip first/last).** These
were silently device-local before — the machinery existed but was never wired
up. They now travel with your account in both directions, per-setting and
last-writer-wins, so a fresh install or a second device gets them back.
Existing installs get a one-time catch-up on the first sync after updating —
no need to sign out and back in.
Note: stock Pocket Casts never uploaded playback speeds, so speeds set only on
a stock install can't be recovered — set them once here and they'll stick.

**Fixes and polish**
- Session and Up Next details drop the blurred artwork backdrop.
- Inbox zero: no search box, and the empty state is vertically centered.
- Merged upstream 8.17.0.2 (306 commits).

## 0.5 and earlier

See git history; the Sessions feature itself (Inbox, sessions, filter presets,
queue screen) landed across 0.1–0.5.
