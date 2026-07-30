import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

actor ShowInfoCoordinator: ShowInfoCoordinating {
    static let shared = ShowInfoCoordinator()

    private let dataRetriever: ShowInfoDataRetriever
    private let podcastIndexChapterRetriever: PodcastIndexChapterDataRetriever
    private let generatedEpisodeMetadataRetriever: GeneratedEpisodeMetadataRetriever
    private let dataManager: DataManager
    private let transcriptDataRetriever: TranscriptsDataRetriever

    private var requestingShowInfo: [String: Task<Episode.Metadata?, Error>] = [:]
    private var requestingRawMetadata: [String: Task<String?, Error>] = [:]

    init(
        dataRetriever: ShowInfoDataRetriever = ShowInfoDataRetriever(),
        podcastIndexChapterRetriever: PodcastIndexChapterDataRetriever = PodcastIndexChapterDataRetriever(),
        generatedEpisodeMetadataRetriever: GeneratedEpisodeMetadataRetriever = GeneratedEpisodeMetadataRetriever(),
        dataManager: DataManager = .sharedManager,
        transcriptDataRetriever: TranscriptsDataRetriever = TranscriptsDataRetriever()
    ) {
        self.dataRetriever = dataRetriever
        self.podcastIndexChapterRetriever = podcastIndexChapterRetriever
        self.generatedEpisodeMetadataRetriever = generatedEpisodeMetadataRetriever
        self.dataManager = dataManager
        self.transcriptDataRetriever = transcriptDataRetriever
    }

    func loadShowNotes(
        podcastUuid: String,
        episodeUuid: String
    ) async throws -> String {
        let metadata = try await loadShowInfo(podcastUuid: podcastUuid, episodeUuid: episodeUuid)
        return metadata?.showNotes ?? CacheServerHandler.noShowNotesMessage
    }

    func loadEpisodeArtworkUrl(
        podcastUuid: String,
        episodeUuid: String
    ) async throws -> URL? {
        let metadata = try await loadShowInfo(podcastUuid: podcastUuid, episodeUuid: episodeUuid)
        return metadata?.image.flatMap(URL.init(string:))
    }

    public func loadChapters(
        podcastUuid: String,
        episodeUuid: String
    ) async throws -> ([Episode.Metadata.EpisodeChapter]?, [PodcastIndexChapter]?, [GeneratedChapter]?) {
        // Fork: our own feeds are private (Basic Auth), so Pocket Casts' servers never fetch them
        // and never index their <podcast:chapters> into show notes — `metadata?.chaptersUrl` below
        // is always nil for them. The companion publishes the same Podcast Index JSON at a PUBLIC
        // url derived from the enclosure, so ask for it directly.
        //
        // Deliberately BEFORE loadShowInfo: for these episodes PC has nothing to offer, and a
        // failure fetching show info would otherwise throw past our own perfectly good source.
        // For every other episode `videoChaptersUrl` fails its pattern match immediately, so
        // this costs one database lookup and nothing else.
        if let url = videoChaptersUrl(episodeUuid: episodeUuid),
           let chapters = try? await podcastIndexChapterRetriever.loadChapters(url), !chapters.chapters.isEmpty {
            return (nil, chapters.chapters, nil)
        }

        let metadata = try await loadShowInfo(podcastUuid: podcastUuid, episodeUuid: episodeUuid)

        if let podcastIndexChapterUrl = metadata?.chaptersUrl,
           let chapters = try? await podcastIndexChapterRetriever.loadChapters(podcastIndexChapterUrl) {
            return (nil, chapters.chapters, nil)
        }

        if let chapters = metadata?.chapters, !chapters.isEmpty {
            return (chapters, nil, nil)
        }

        if FeatureFlag.generatedChapters.enabled,
           !Settings.disableAiChapters,
           let chapters = try? await generatedEpisodeMetadataRetriever.loadMetadata(podcastUuid: podcastUuid, episodeUuid: episodeUuid).chapters,
           !chapters.isEmpty {
            return (nil, nil, chapters)
        }

        return (nil, nil, nil)
    }

    /// The video-chapters url for one of our own enclosures, or nil for anything else.
    ///
    /// Enclosures look like `…/enclosure/<videoId>.m4a|.mp4` where `<videoId>` is an 11-character
    /// YouTube id, and chapters for that id live at `<base>/chapters/<videoId>.json`. The host is
    /// matched loosely (any host) because the media origin and the feed origin differ — enclosures
    /// stream from a LAN host while chapters are served publicly — so the enclosure's own host
    /// cannot be reused. Override the base with the `SJVideoChaptersBase` default if it moves.
    private func videoChaptersUrl(episodeUuid: String) -> String? {
        guard let episode = dataManager.findEpisode(uuid: episodeUuid),
              let downloadUrl = episode.downloadUrl,
              let videoId = Self.videoChaptersVideoId(fromEnclosure: downloadUrl) else { return nil }
        let base = UserDefaults.standard.string(forKey: "SJVideoChaptersBase") ?? "https://owntube.example.com"
        return "\(base)/chapters/\(videoId).json"
    }

    /// Exposed for testing: the 11-character id in `…/enclosure/<id>.m4a|.mp4`, or nil.
    static func videoChaptersVideoId(fromEnclosure urlString: String) -> String? {
        // Strip any query/fragment before matching so `?token=…` can't defeat the extension anchor.
        let path = urlString.split(separator: "?").first.map(String.init)?.split(separator: "#").first.map(String.init) ?? urlString
        guard let match = try? Self.enclosurePattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(withName: "id"), in: path) else { return nil }
        return String(path[range])
    }

    private static let enclosurePattern = try! NSRegularExpression(
        pattern: "/enclosure/(?<id>[A-Za-z0-9_-]{11})\\.(m4a|mp4)$",
        options: [.caseInsensitive]
    )

    private func buildGeneratedTranscript(podcastUuid: String, episodeUuid: String) -> Episode.Metadata.Transcript {
        let format = TranscriptFormat.vtt
        let urlString = "\(ServerConstants.Urls.generatedTranscripts)\(podcastUuid)/\(episodeUuid).\(format.fileExtension)"
        return Episode.Metadata.Transcript(url: urlString, type: format.rawValue, language: nil)
    }

    public func loadTranscriptsMetadata(podcastUuid: String, episodeUuid: String) async throws -> EpisodeTranscriptData {
#if os(watchOS)
        return (transcripts: [], hasGeneratedTranscripts: false, isDisplayingGeneratedTranscript: false)
#else
        let metadata = try await loadShowInfo(podcastUuid: podcastUuid, episodeUuid: episodeUuid)

        if FeatureFlag.generatedTranscripts.enabled {
            let externalTranscripts = metadata?.transcripts ?? []
            var pocketCastsTranscripts: [Episode.Metadata.Transcript] = []
            if let episode = dataManager.findEpisode(uuid: episodeUuid),
               let hasTranscript = episode.hasGeneratedTranscript {
                if hasTranscript {
                    let transcript = buildGeneratedTranscript(podcastUuid: podcastUuid, episodeUuid: episodeUuid)
                    pocketCastsTranscripts = [transcript]
                }
            } else {
                pocketCastsTranscripts = metadata?.pocketCastsTranscripts ?? []
            }

            let isDisplayingGenerated = externalTranscripts.isEmpty && !pocketCastsTranscripts.isEmpty
            let transcripts = externalTranscripts.isEmpty ? pocketCastsTranscripts : externalTranscripts
            return (transcripts: transcripts, hasGeneratedTranscripts: !pocketCastsTranscripts.isEmpty, isDisplayingGeneratedTranscript: isDisplayingGenerated)
        }

        guard let transcripts = metadata?.transcripts else {
            return (transcripts: [], hasGeneratedTranscripts: false, isDisplayingGeneratedTranscript: false)
        }
        return (transcripts: transcripts, hasGeneratedTranscripts: false, isDisplayingGeneratedTranscript: false)
#endif
    }

    @discardableResult
    func loadShowInfo(
        podcastUuid: String,
        episodeUuid: String
    ) async throws -> Episode.Metadata? {
        try await requestShowInfo(podcastUuid: podcastUuid, episodeUuid: episodeUuid)
    }

    @discardableResult
    func requestShowInfo(
        podcastUuid: String,
        episodeUuid: String
    ) async throws -> Episode.Metadata? {
        if let task = requestingShowInfo[episodeUuid] {
            return try await task.value
        }

        let task = Task<Episode.Metadata?, Error> { [weak self] in
            guard let self else { throw TaskError.nilSelf }

            do {
                let data = try await dataRetriever.loadEpisodeDataFromCache(for: podcastUuid, episodeUuid: episodeUuid)
                await setRequestingShowInfoToNil(for: episodeUuid)
                return await getShowInfo(for: data?.data(using: .utf8))
            } catch {
                await setRequestingShowInfoToNil(for: episodeUuid)
                throw error
            }
        }

        requestingShowInfo[episodeUuid] = task

        return try await task.value
    }

    private func setRequestingShowInfoToNil(for episodeUuid: String) {
        requestingShowInfo[episodeUuid] = nil
    }

    private func getShowInfo(for data: Data?) async -> Episode.Metadata? {
        guard let data else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Episode.Metadata.self, from: data)
        } catch {
            return nil
        }
    }
}
