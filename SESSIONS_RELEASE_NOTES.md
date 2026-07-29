# Sessions fork — release notes

Marketing version = the sessions version; build number = the stock base it was
cut from (TestFlight shows e.g. "0.6 (8.17.0.2)").

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
