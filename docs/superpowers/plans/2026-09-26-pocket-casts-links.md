# Open Pocket Casts Web Links in the Fork App — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `pca.st` and `pocketcasts.com` links open in the self-built Pocket Casts app (bundle root `com.mdbraber.podcasts`), which cannot claim those domains as universal links.

**Architecture:** One in-app entry point handles any Pocket Casts web link (the code that today only runs for universal links). It becomes reachable through the app's own `pktc://` scheme (`pktc://weblink/<full https URL>`, plus `pktc://podcast/<uuid>`). Two ways deliver links to it: the existing Share Extension (now also accepting web URLs), and a new iOS Safari Web Extension that redirects Pocket Casts web pages to `pktc://weblink/…` when they load in Safari.

**Tech Stack:** Swift/UIKit iOS app (`ios/`), JLRoutes, Xcode project `ios/podcasts.xcodeproj` (no project generator — targets live in `project.pbxproj`), Safari Web Extension (manifest v3, JavaScript content script).

**Spec:** Decided in conversation on 2026-09-26: the user wants both the share-sheet route and a Safari extension. Background: universal links for `pca.st`/`pocketcasts.com` are controlled by Pocket Casts' `apple-app-site-association` files, so only the official app can claim them; in-app browsers (e.g. Slack's) don't run Safari extensions, which is why the share route is kept too.

## Design decisions

1. **Single handler.** Extract the `NSUserActivityTypeBrowsingWeb` branch of `AppDelegate.handleContinue(_:)` (`ios/podcasts/AppDelegate+SiriShortcuts.swift`) into `func handleIncomingWebLink(_ url: URL)` on `AppDelegate`, unchanged in behaviour; `handleContinue` calls it. Accept only hosts `pca.st`, `pocketcasts.com`, `www.pocketcasts.com`, `play.pocketcasts.com` (and the staging share host from `ServerConstants.Urls.share()`), over https; ignore anything else.
2. **New routes** (in `ios/podcasts/AppDelegate+UrlHandling.swift`, same JLRoutes style as the others):
   - `pktc://weblink/<url>` — everything after `pktc://weblink/` is the web URL (accept it raw or percent-encoded; decode once if it starts with `https%3A`). Calls `handleIncomingWebLink`.
   - `pktc://podcast/<uuid>` — opens the podcast page via the same path `openSharePath` uses for `/podcast/<uuid>`.
3. **Share Extension** (`ios/Share Extension/`): its activation rule also accepts exactly one `public.url` attachment. For an http(s) URL whose host is one of the Pocket Casts hosts → open `pktc://weblink/<url>`; any other http(s) URL → open `pktc://subscribe/<url>` (existing route: add podcast by feed URL). File attachments keep today's behaviour exactly.
4. **Safari Web Extension**: new app-extension target "Safari Extension", bundle id `$(PRODUCT_BUNDLE_IDENTIFIER_ROOT).SafariExtension`, embedded in the main app like the Share Extension, same deployment target and signing settings as the Share Extension. Manifest v3 with one content script at `document_start` on `https://pca.st/*`, `https://pocketcasts.com/*`, `https://www.pocketcasts.com/*`, `https://play.pocketcasts.com/*` that does `location.replace("pktc://weblink/" + location.href)` — on `pca.st` for every path except `/` and `/get*`; on the other hosts only for paths starting `/podcast/`, `/private/`, `/episode/`, `/social/share/`. A minimal `SafariWebExtensionHandler` (NSExtensionRequestHandling) as principal class. Icons: reuse the app icon at the sizes the manifest needs.
5. **No behaviour change** for universal links, existing routes, or file sharing.

## Global Constraints

- Work only in the worktree `/Users/mdbraber/src/pocket-sessions-pclinks` (branch `pc-links`); `ios/config/Local.xcconfig` is present there (bundle root `com.mdbraber.podcasts`, team `D3S5M885YQ`) and git-ignored — never commit it.
- Localizable strings only via `podcasts/en.lproj/Localizable.strings` + `L10n` if any UI text is added (none expected).
- Swift style per `ios/CLAUDE.md`; run `make lint_changed` from `ios/` if the SwiftLint binary is available.
- Build check: from `ios/`, `make build` (Debug, generic iOS Simulator). The build must include the new extension target (embedded in the app product).

## Review Focus

1. A `pktc://weblink/` URL whose target host is not a Pocket Casts host (e.g. `pktc://weblink/https://evil.example/podcast/x`) must do nothing.
2. Percent-encoded and raw forms of the same link (`pktc://weblink/https%3A%2F%2Fpca.st%2Fpodcast%2F<uuid>` and `pktc://weblink/https://pca.st/podcast/<uuid>`) must behave the same, and query strings like `?t=123` must survive.
3. Sharing an OPML/audio/video file must still import exactly as before.
4. The Safari content script must not redirect `pca.st/` (home) or `/get` pages, nor non-link pages on pocketcasts.com (e.g. `/login`, `/`), or users could never reach them in Safari.
5. The extension target must be embedded in the app and signed with the app's team via automatic signing, or the TestFlight archive (`make testflight`) breaks.

---

### Task 1: One web-link handler, reachable via `pktc://`

**Files:** `ios/podcasts/AppDelegate+SiriShortcuts.swift`, `ios/podcasts/AppDelegate+UrlHandling.swift`; a small pure helper for URL parsing (e.g. `ios/podcasts/PocketCastsWebLink.swift` with `static func webURL(fromPktcWeblink url: URL) -> URL?` and `static func isPocketCastsHost(_ host: String?) -> Bool`) plus tests in `ios/PocketCastsTests/Tests/` covering Review Focus 1 and 2 (raw, percent-encoded, query preserved, foreign host rejected, `pktc://podcast/<uuid>` parsing).

- [ ] Write the helper tests first (XCTest, same style as neighbouring tests), see them fail, implement the helper, extract `handleIncomingWebLink`, add the two routes, see tests pass (`make test_staging ONLY_TESTING=PocketCastsTests/<YourTestClass>` or the Debug `make test` equivalent; if simulator tests can't run in this environment, say so and rely on `make build`).
- [ ] Commit `Open Pocket Casts web links through pktc://weblink and pktc://podcast`.

### Task 2: Share Extension accepts web links

**Files:** `ios/Share Extension/Info.plist` (activation rule), `ios/Share Extension/ShareViewController.swift`.

- [ ] Extend the activation rule with `|| ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.url"` inside the existing single-attachment SUBQUERY (keep the `@count == 1` structure).
- [ ] In the controller, load a `public.url` attachment first when present: Pocket Casts host → `pktc://weblink/<url>`; other http(s) → `pktc://subscribe/<url>`; then complete the request. Keep the file path branch unchanged. Reuse the existing `redirectToHostApp`-style opening (it walks the responder chain to `UIApplication`).
- [ ] `make build`; commit `Share Extension: open shared Pocket Casts links and feed URLs in the app`.

### Task 3: Safari Web Extension

**Files:** new folder `ios/Safari Extension/` (`Info.plist`, `SafariWebExtensionHandler.swift`, `Resources/manifest.json`, `Resources/content.js`, `Resources/images/*.png`, optional `Resources/_locales/en/messages.json`), `ios/podcasts.xcodeproj/project.pbxproj` (new target, build configurations for every configuration the Share Extension has, embed in the main app's "Embed Foundation Extensions" phase, target dependency).

- [ ] Add the target by editing the project with the `xcodeproj` Ruby gem (available through fastlane: `cd ios && bundle exec ruby script.rb`, or install the gem locally) modelled on the Share Extension target's build settings (copy its per-configuration settings, change bundle id suffix, Info.plist path, product name, and set `CODE_SIGN_ENTITLEMENTS` empty/none). Don't hand-edit pbxproj UUIDs unless the gem is unavailable.
- [ ] `make build`; confirm the built app bundle contains `PlugIns/Safari Extension.appex` (or similar) with the manifest inside.
- [ ] Commit `Safari extension: open Pocket Casts web links in the app`.

### Task 4: Ship

- [ ] Merge `pc-links` into `main` of `~/src/pocket-sessions` (only after review). The user builds and installs (TestFlight via `make testflight` from `ios/`, or Xcode). On the phone: Settings → Apps → Safari → Extensions → enable the new extension and allow it on the Pocket Casts sites; in Slack, turn off "Open web pages in app" for automatic redirects.
