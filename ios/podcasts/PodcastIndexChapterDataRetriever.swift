import Foundation
import PocketCastsServer
import PocketCastsUtils

public struct PodcastIndexEvelope: Decodable {
    let chapters: [PodcastIndexChapter]
}

struct PodcastIndexChapter: Decodable {
    let title: String?
    let number: Int?
    let endTime: TimeInterval?
    let startTime: TimeInterval
}

/// Request information about an episode using the show notes endpoint
public actor PodcastIndexChapterDataRetriever {
    private let podcastIndexChaptersCache: URLCache

    private var dataRequestMap: [String: Task<PodcastIndexEvelope, Error>] = [:]

    public init() {
        podcastIndexChaptersCache = URLCache(memoryCapacity: 1.megabytes, diskCapacity: 10.megabytes, diskPath: "podcast_index_chapters")
    }

    public func loadChapters(_ urlString: String) async throws -> PodcastIndexEvelope {
        if let task = dataRequestMap[urlString] {
            return try await task.value
        }

        guard let url = URL(string: urlString) else {
            throw Errors.malformedURL
        }

        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData)

        // Only a success body is worth replaying. Nothing here used to check the status code, so a
        // 401/404/503 body was cached like any other and then decoded on every later attempt —
        // throwing each time. One bad moment (a server hiccup, or a request made before a VPN came
        // up) could therefore poison an episode's chapters for the life of the install.
        if let cachedResponse = podcastIndexChaptersCache.cachedResponse(for: request), Self.isSuccess(cachedResponse.response) {
            return try chapters(from: cachedResponse.data)
        }

        defer {
            dataRequestMap[urlString] = nil
        }

        let task = Task<PodcastIndexEvelope, Error> { [weak self] in
            guard let self else { throw TaskError.nilSelf }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard Self.isSuccess(response) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                FileLog.shared.addMessage("PodcastIndexChapters: \(urlString) returned HTTP \(code)")
                throw Errors.badResponse(code)
            }
            let responseToCache = CachedURLResponse(response: response, data: data)
            podcastIndexChaptersCache.storeCachedResponse(responseToCache, for: request)

            return try await chapters(from: data)
        }

        dataRequestMap[urlString] = task

        return try await task.value
    }

    private func chapters(from data: Data) throws -> PodcastIndexEvelope {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PodcastIndexEvelope.self, from: data)
    }

    /// An HTTP response worth decoding and caching. Non-HTTP responses (file urls) count as success.
    private static func isSuccess(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200 ..< 300).contains(http.statusCode)
    }

    enum Errors: Error {
        case malformedURL
        case badResponse(Int)
    }
}
