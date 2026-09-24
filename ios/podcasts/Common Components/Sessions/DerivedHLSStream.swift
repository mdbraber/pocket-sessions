import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// Fork: prefers an HLS ladder over the progressive mp4 for our own video enclosures.
///
/// **Why it is derived rather than advertised.** `Episode.hlsUrl` is only ever populated from
/// Pocket Casts' servers — either the cache-server JSON (`Episode.hlsUrl(fromEpisodeJson:)`) or the
/// protobuf sync path (`Api_AlternateEnclosure.hlsUrl`). Both need PC to have fetched and parsed
/// the feed's `<podcast:alternateEnclosure>`. Our feeds are private (Basic Auth), so PC never reads
/// them and no alternate enclosure ever arrives, however the feed is written.
///
/// The companion server publishes both forms at a fixed relationship, so the ladder can be derived
/// from the enclosure without anyone advertising it:
///
///     https://<media-host>/enclosure/<videoId>.mp4
///     https://<media-host>/hls/<videoId>/master.m3u8
///
/// Same host deliberately — the ladder is served by the media origin that served the enclosure, so
/// nothing about the origin is hardcoded here and a host change carries across for free.
///
/// **Playback only.** Downloads keep using the mp4: `DownloadManager` reads `episode.downloadUrl`
/// directly and never comes through here, which is what we want — a downloaded HLS ladder is not a
/// file you can keep.
enum DerivedHLSStream {
    /// The ladder for a progressive enclosure, or nil if this is not one of ours.
    ///
    /// Restricted to `.mp4`: `.m4a` enclosures are audio-only, where a ladder buys no quality and
    /// would only add a manifest round-trip.
    static func url(forEnclosure urlString: String) -> URL? {
        guard let components = URLComponents(string: urlString),
              let videoId = videoId(fromPath: components.path) else { return nil }
        var ladder = components
        ladder.path = "/hls/\(videoId)/master.m3u8"
        ladder.query = nil
        ladder.fragment = nil
        return ladder.url
    }

    /// Exposed for testing: the 11-character id in `/enclosure/<id>.mp4`, or nil.
    static func videoId(fromPath path: String) -> String? {
        guard let match = try? pattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(withName: "id"), in: path) else { return nil }
        return String(path[range])
    }

    private static let pattern = try! NSRegularExpression(
        pattern: "^/enclosure/(?<id>[A-Za-z0-9_-]{11})\\.mp4$",
        options: [.caseInsensitive]
    )

    /// The ladder to play for this episode, or nil to leave the URL choice alone.
    ///
    /// Returns nil once the ladder has failed for this episode — see `markFailed`. That is the
    /// whole fallback: the next resolve simply doesn't offer HLS and the mp4 is used instead.
    static func playbackUrl(for episode: Episode) -> URL? {
        guard FeatureFlag.hls.enabled,
              let downloadUrl = episode.downloadUrl,
              !hasFailed(episodeUuid: episode.uuid) else { return nil }
        return url(forEnclosure: downloadUrl)
    }

    // MARK: - Remembering failures

    private static let failedKey = "SJDerivedHLSFailed"
    /// Bounded so a run of failures can't grow the defaults without limit. Oldest entries fall off;
    /// an episode that ages out simply gets one more attempt, which is harmless.
    private static let maxRemembered = 100

    static func hasFailed(episodeUuid: String) -> Bool {
        failedUuids().contains(episodeUuid)
    }

    /// Records that the ladder did not play, so this episode falls back to its mp4 from now on.
    static func markFailed(episodeUuid: String) {
        var uuids = failedUuids().filter { $0 != episodeUuid }
        uuids.append(episodeUuid)
        if uuids.count > maxRemembered {
            uuids.removeFirst(uuids.count - maxRemembered)
        }
        UserDefaults.standard.set(uuids, forKey: failedKey)
        FileLog.shared.addMessage("DerivedHLSStream: \(episodeUuid) fell back to its progressive enclosure")
    }

    private static func failedUuids() -> [String] {
        UserDefaults.standard.stringArray(forKey: failedKey) ?? []
    }
}
