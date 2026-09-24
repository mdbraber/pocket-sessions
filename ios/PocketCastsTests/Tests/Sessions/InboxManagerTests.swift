import PocketCastsDataModel
import XCTest

@testable import podcasts

/// Fork: the Inbox engine.
///
/// The stakes are asymmetric. Failing to offer a new episode costs one missed dot. Offering
/// too eagerly floods the Inbox with a thousand episodes and destroys the one thing the
/// feature promises — that what's in there is what you haven't looked at. Most of these tests
/// are therefore about what must NOT be added.
final class InboxManagerTests: DBTestCase {
    private var store: InboxStore!
    private var storeURL: URL!
    private var inbox: InboxManager!

    override func setUp() async throws {
        try await super.setUp()

        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-manager-tests-\(UUID().uuidString).json")
        store = InboxStore(fileURL: storeURL)
        inbox = InboxManager(store: store)

        // DBTestCase reuses one database across the class, so start from an empty Inbox.
        dataManager.deleteAllEpisodes(in: inbox.inboxPlaylist())
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
        // The manual-unseen exemption set persists in UserDefaults; don't leak it across runs.
        UserDefaults.standard.removeObject(forKey: InboxManager.manualUnseenKey)
        inbox = nil
        store = nil
        storeURL = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func makePodcast(latestEpisodeDate: Date?) -> Podcast {
        let podcast = Podcast()
        podcast.uuid = UUID().uuidString
        podcast.subscribed = 1
        podcast.addedDate = Date()
        podcast.latestEpisodeDate = latestEpisodeDate
        dataManager.save(podcast: podcast)
        return podcast
    }

    @discardableResult
    private func makeEpisode(
        uuid: String = UUID().uuidString,
        podcast: Podcast,
        publishedDate: Date,
        archived: Bool = false,
        playedUpTo: Double = 0,
        playingStatus: PlayingStatus = .notPlayed
    ) -> Episode {
        let episode = Episode()
        episode.uuid = uuid
        episode.podcastUuid = podcast.uuid
        episode.podcast_id = podcast.id
        episode.publishedDate = publishedDate
        episode.addedDate = Date()
        episode.archived = archived
        episode.playedUpTo = playedUpTo
        episode.playingStatus = playingStatus.rawValue
        dataManager.save(episode: episode)
        return episode
    }

    /// Up Next lives in the same table as playlist membership, with a NULL playlist_uuid.
    private func queue(_ episodeUuid: String, podcastUuid: String) {
        let playlistEpisode = PlaylistEpisode()
        playlistEpisode.episodeUuid = episodeUuid
        playlistEpisode.podcastUuid = podcastUuid
        playlistEpisode.episodePosition = dataManager.positionForPlaylistEpisode(bottomOfList: true)
        dataManager.save(playlistEpisode: playlistEpisode)
    }

    private func date(_ daysAgo: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(-daysAgo * 86_400))
    }

    // MARK: - A podcast we have never seen: draw the line, offer NOTHING

    /// This one rule covers a fresh install, a full sync, an OPML import, and a brand-new
    /// subscription — all four are just "no `offeredThrough` entry yet". It is the reason the
    /// entire library cannot flood in, and it is why there is no bootstrap special case.
    func testANewPodcastOffersNothingAndJustDrawsTheLine() {
        let podcast = makePodcast(latestEpisodeDate: date(0))
        for day in 0 ... 5 {
            makeEpisode(uuid: "back-catalogue-\(day)", podcast: podcast, publishedDate: date(day))
        }

        inbox.drain()

        XCTAssertTrue(inbox.unseenUuids().isEmpty, "a back catalogue must NEVER be filled into the Inbox")
        XCTAssertEqual(store.offeredThrough(podcastUuid: podcast.uuid), date(0), "the line is drawn at the newest episode")
    }

    // MARK: - Genuinely new episodes

    func testAnEpisodePublishedAfterTheLineIsOffered() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain() // draws the line at day-5, offers nothing

        let fresh = makeEpisode(uuid: "fresh", podcast: podcast, publishedDate: date(1))
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)

        inbox.drain()

        XCTAssertEqual(inbox.unseenUuids(), ["fresh"])
        XCTAssertEqual(store.offeredThrough(podcastUuid: podcast.uuid), date(1))
        XCTAssertNotNil(fresh)
    }

    /// THE anti-flood test. Once triaged, an episode must never come back — this is what
    /// `offeredThrough` exists for, and the bug it prevents (a second device re-detecting an
    /// episode whose removal it hasn't seen yet) is the whole reason the watermark survived.
    func testATriagedEpisodeIsNeverReOffered() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()

        makeEpisode(uuid: "fresh", podcast: podcast, publishedDate: date(1))
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)
        inbox.drain()
        XCTAssertEqual(inbox.unseenUuids(), ["fresh"])

        inbox.markSeen(episodeUuids: ["fresh"])
        XCTAssertTrue(inbox.unseenUuids().isEmpty)

        inbox.drain()
        inbox.drain()

        XCTAssertTrue(inbox.unseenUuids().isEmpty, "a triaged episode must never be re-offered, no matter how often we drain")
    }

    func testDrainingTwiceDoesNotDuplicateMembership() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()

        makeEpisode(uuid: "fresh", podcast: podcast, publishedDate: date(1))
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)

        inbox.drain()
        inbox.drain()

        XCTAssertEqual(inbox.unseenUuids(), ["fresh"])
    }

    // MARK: - Already-decided episodes are not new

    /// Stock auto-archive runs before us, so a podcast with an episode limit can deliver an
    /// episode that is already archived. It must not appear — but the line must still advance
    /// past it, or every future drain reconsiders it forever.
    func testAnEpisodeArchivedOnArrivalIsNotOfferedButStillAdvancesTheLine() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()

        makeEpisode(uuid: "auto-archived", podcast: podcast, publishedDate: date(1), archived: true)
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)

        inbox.drain()

        XCTAssertTrue(inbox.unseenUuids().isEmpty)
        XCTAssertEqual(store.offeredThrough(podcastUuid: podcast.uuid), date(1), "the line must move past it anyway")
    }

    /// The sync runs before the drain, so an episode already played on another device arrives
    /// with its progress. Any progress at all means it has been decided about.
    func testAnEpisodeWithPlaybackProgressIsNotOffered() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()

        makeEpisode(uuid: "already-started", podcast: podcast, publishedDate: date(1), playedUpTo: 30)
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)

        inbox.drain()

        XCTAssertTrue(inbox.unseenUuids().isEmpty)
    }

    /// Auto-add-to-Up-Next must NOT keep an episode out of the Inbox. Everything that arrives
    /// comes through the Inbox — that is what makes it a complete record of what turned up —
    /// and Mark All as Seen is how you clear it once you have watched it go past. So being
    /// queued is not a disqualifying *state*.
    func testAnEpisodeThatArrivesAlreadyQueuedIsStillOffered() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()

        makeEpisode(uuid: "auto-queued", podcast: podcast, publishedDate: date(1))
        queue("auto-queued", podcastUuid: podcast.uuid)
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)

        inbox.drain()

        XCTAssertEqual(inbox.unseenUuids(), ["auto-queued"], "auto-added episodes must still come through the Inbox")
    }

    /// ...and the sweep must not undo that. This is why "queued" is an EVENT and not a STATE:
    /// a stateless "is it in Up Next" check here would strip the dot off every auto-added
    /// episode the next time anything at all changed.
    func testTheSweepDoesNotRemoveAQueuedEpisode() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()
        makeEpisode(uuid: "auto-queued", podcast: podcast, publishedDate: date(1))
        queue("auto-queued", podcastUuid: podcast.uuid)
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)
        inbox.drain()

        inbox.sweep()

        XCTAssertEqual(inbox.unseenUuids(), ["auto-queued"])
    }

    /// But queuing an episode YOURSELF is deciding to listen to it, so the dot goes.
    func testQueuingAnUnseenEpisodeClearsItsDot() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()
        makeEpisode(uuid: "queue-me", podcast: podcast, publishedDate: date(2))
        makeEpisode(uuid: "leave-me", podcast: podcast, publishedDate: date(1))
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)
        inbox.drain()
        XCTAssertEqual(inbox.unseenUuids(), ["queue-me", "leave-me"])

        inbox.setup()
        queue("queue-me", podcastUuid: podcast.uuid)
        NotificationCenter.default.post(name: Constants.Notifications.upNextEpisodeAdded, object: "queue-me")

        XCTAssertEqual(inbox.unseenUuids(), ["leave-me"], "queuing it yourself is a decision")
    }

    func testAnOptedOutPodcastIsNeverOffered() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()

        SessionFeederEngine.setOptedOut(true, podcastUuid: podcast.uuid)
        defer { SessionFeederEngine.setOptedOut(false, podcastUuid: podcast.uuid) }

        makeEpisode(uuid: "opted-out", podcast: podcast, publishedDate: date(1))
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)

        inbox.drain()

        XCTAssertTrue(inbox.unseenUuids().isEmpty)
    }

    // MARK: - The verbs

    func testMarkSeenRemovesFromTheInbox() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()
        makeEpisode(uuid: "a", podcast: podcast, publishedDate: date(2))
        makeEpisode(uuid: "b", podcast: podcast, publishedDate: date(1))
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)
        inbox.drain()
        XCTAssertEqual(inbox.unseenUuids(), ["a", "b"])

        inbox.markSeen(episodeUuids: ["a"])

        XCTAssertEqual(inbox.unseenUuids(), ["b"])
    }

    /// Mark-unseen is an attention mark, not a rewind: playback state stays untouched. The
    /// episode instead goes into the manual-unseen exemption set, which is what stops the very
    /// next sweep from seeing the progress it still carries and removing it again.
    func testMarkUnseenLeavesPlaybackStateAloneAndTheSweepCannotUndoIt() {
        let podcast = makePodcast(latestEpisodeDate: date(1))
        let episode = makeEpisode(uuid: "decided", podcast: podcast, publishedDate: date(1), playedUpTo: 120, playingStatus: .completed)

        inbox.markUnseen(episodeUuids: [episode.uuid])

        XCTAssertEqual(inbox.unseenUuids(), ["decided"])

        let reloaded = dataManager.findEpisode(uuid: "decided")
        XCTAssertEqual(reloaded?.playedUpTo, 120, "unseen is an attention mark — progress must be left alone")
        XCTAssertEqual(reloaded?.playingStatus, PlayingStatus.completed.rawValue, "…and so must the played status")

        inbox.sweep()
        XCTAssertEqual(inbox.unseenUuids(), ["decided"], "the sweep must not immediately undo mark-unseen")

        // Leaving the Inbox deliberately ends the exemption — otherwise the episode would dodge
        // the sweep's progress rule forever if it ever came back.
        inbox.markSeen(episodeUuids: ["decided"])
        XCTAssertFalse(inbox.manualUnseenUuids().contains("decided"), "mark-seen must clear the manual-unseen exemption")
    }

    // MARK: - The sweep

    func testTheSweepRemovesAnythingSinceDecided() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()
        let played = makeEpisode(uuid: "played", podcast: podcast, publishedDate: date(3))
        let archived = makeEpisode(uuid: "archived", podcast: podcast, publishedDate: date(2))
        makeEpisode(uuid: "untouched", podcast: podcast, publishedDate: date(1))
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)
        inbox.drain()
        XCTAssertEqual(inbox.unseenUuids(), ["played", "archived", "untouched"])

        played.playedUpTo = 5
        dataManager.save(episode: played)
        archived.archived = true
        dataManager.save(episode: archived)

        inbox.sweep()

        XCTAssertEqual(inbox.unseenUuids(), ["untouched"], "any progress, or archiving, means decided")
    }

    // MARK: - The cap

    /// A manual playlist is hard-capped at 1,000 and `add` fails silently when it would
    /// overflow. Stopping short means the failure is ours to see rather than an invisible
    /// "new episodes just stopped appearing".
    func testTheInboxStopsAtItsCapacityRatherThanFailingSilently() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()

        for index in 0 ..< (InboxManager.capacity + 50) {
            makeEpisode(uuid: "e\(index)", podcast: podcast, publishedDate: date(4).addingTimeInterval(TimeInterval(index)))
        }
        podcast.latestEpisodeDate = date(0)
        dataManager.save(podcast: podcast)

        inbox.drain()

        XCTAssertEqual(inbox.unseenUuids().count, InboxManager.capacity, "the Inbox fills to its cap and stops")
    }

    // MARK: - The seen-ledger

    /// `markSeen` is the funnel every deliberate removal goes through, so recording there is
    /// what gives the ledger complete coverage; `markUnseen` must clear the entry (with an
    /// override), or the sync-import filter would fight mark-unseen forever.
    func testMarkSeenRecordsIntoTheLedgerAndMarkUnseenClearsIt() {
        let podcast = makePodcast(latestEpisodeDate: date(1))
        makeEpisode(uuid: "triaged", podcast: podcast, publishedDate: date(1))

        inbox.markSeen(episodeUuids: ["triaged"])
        XCTAssertTrue(store.isSeen("triaged"), "mark-seen must leave a tombstone in the ledger")

        inbox.markUnseen(episodeUuids: ["triaged"])
        XCTAssertFalse(store.isSeen("triaged"), "mark-unseen must take it back out")
        XCTAssertEqual(inbox.unseenUuids(), ["triaged"])

        inbox.markSeen(episodeUuids: ["triaged"])
        XCTAssertTrue(store.isSeen("triaged"), "a later mark-seen must win again — latest decision rules")
    }

    /// This closure is what `ServerConfig.shared.inboxSeenFilter` runs during the playlist
    /// sync import: given the uuids the server would re-add to the Inbox, return the ones the
    /// ledger says were deliberately removed, so the import drops them. The SyncTask path
    /// itself needs a protobuf + network harness, so the filter is tested directly here — the
    /// SyncTask side is a two-line subtract behind a `uuid == inboxPlaylistUuid` guard.
    func testTheImportFilterDropsExactlyTheLedgerSeenUuids() {
        let podcast = makePodcast(latestEpisodeDate: date(1))
        makeEpisode(uuid: "triaged-here", podcast: podcast, publishedDate: date(1))
        inbox.markSeen(episodeUuids: ["triaged-here"])

        XCTAssertEqual(
            inbox.inboxSeenFilter(["triaged-here", "genuinely-new"]), ["triaged-here"],
            "only the triaged episode is filtered; a genuinely new one must still be added"
        )

        inbox.markUnseen(episodeUuids: ["triaged-here"])
        XCTAssertTrue(
            inbox.inboxSeenFilter(["triaged-here"]).isEmpty,
            "after mark-unseen the filter must let the episode through — otherwise sync would fight the user"
        )
    }

    /// The other device triaged an episode away; its ledger arrives over CloudKit before the
    /// playlist sync catches up. The sweep applies the ledger to membership so the dot goes
    /// now, not at some future sync.
    func testTheSweepRemovesMembersTheRemoteLedgerSaysAreSeen() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()
        makeEpisode(uuid: "triaged-elsewhere", podcast: podcast, publishedDate: date(2))
        makeEpisode(uuid: "untouched", podcast: podcast, publishedDate: date(1))
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)
        inbox.drain()
        XCTAssertEqual(inbox.unseenUuids(), ["triaged-elsewhere", "untouched"])

        store.applyRemoteSeenLedger(InboxSeenLedgerPayload(seenAt: ["triaged-elsewhere": Date()], unseenAt: [:]))
        inbox.sweep()

        XCTAssertEqual(inbox.unseenUuids(), ["untouched"])
    }

    /// Incoming server deletes (`rawDeleteEpisodes` in the sync import) bypass `markSeen`, so
    /// a manual-unseen exemption can outlive its episode's membership. The sweep drops those —
    /// otherwise the exemption would silently shield the episode from the progress rule if it
    /// ever came back.
    func testTheSweepDropsExemptionsWhoseEpisodesLeftTheInbox() {
        let podcast = makePodcast(latestEpisodeDate: date(1))
        makeEpisode(uuid: "put-back", podcast: podcast, publishedDate: date(1), playedUpTo: 60)
        inbox.markUnseen(episodeUuids: ["put-back"])
        XCTAssertEqual(inbox.manualUnseenUuids(), ["put-back"])

        // Another device marks it seen; the server-side playlist import removes it with a raw
        // delete, exactly the path that bypasses markSeen.
        dataManager.rawDeleteEpisodes(["put-back"], from: inbox.inboxPlaylist())

        inbox.sweep()

        XCTAssertTrue(inbox.manualUnseenUuids().isEmpty, "an exemption without a member is stale and must go")
        XCTAssertTrue(inbox.unseenUuids().isEmpty, "…and dropping it must not re-add the episode")
    }

    // MARK: - Unsubscribe

    /// Membership would otherwise pin the podcast alive — `deletePodcastIfUnused` bails while
    /// any playlist still contains it.
    func testUnsubscribingClearsThePodcastsEpisodesAndForgetsItsLine() {
        let podcast = makePodcast(latestEpisodeDate: date(5))
        makeEpisode(uuid: "old", podcast: podcast, publishedDate: date(10))
        inbox.drain()
        makeEpisode(uuid: "doomed", podcast: podcast, publishedDate: date(1))
        podcast.latestEpisodeDate = date(1)
        dataManager.save(podcast: podcast)
        inbox.drain()
        XCTAssertEqual(inbox.unseenUuids(), ["doomed"])

        inbox.setup()
        NotificationCenter.default.post(name: Constants.Notifications.podcastDeleted, object: podcast.uuid)

        XCTAssertTrue(inbox.unseenUuids().isEmpty, "an unsubscribed podcast must not keep members in the Inbox")
        XCTAssertNil(store.offeredThrough(podcastUuid: podcast.uuid), "a re-subscribe should draw a fresh line, not replay history")
    }
}
