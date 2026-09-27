import Foundation
import NaturalLanguage
import PocketCastsDataModel
import PocketCastsUtils
#if os(iOS) && canImport(Translation)
import Translation
#endif

/// Fork: translates Pocket Casts' generated chapter titles into the podcast's own language.
///
/// The generated chapters come as a ready-made file from Pocket Casts' servers and their titles are
/// always English, whatever language the episode is in — a Dutch podcast gets English chapters.
/// The request has no language parameter, so the fix has to happen here: detect the podcast's
/// language and, when it differs from the titles', translate them on-device.
///
/// Uses Apple's Translation framework without any UI, which needs iOS 26 and both languages already
/// downloaded on the device (Settings › Apps › Translate › Downloaded Languages). When either is
/// missing the titles are left as they are — never worse than before.
actor GeneratedChapterTranslator {
    static let shared = GeneratedChapterTranslator()

    /// Keyed by episode uuid; holds the titles already translated for that episode.
    private var cache: [String: [GeneratedChapter]] = [:]

    /// - Parameters:
    ///   - transcriptLanguage: language code of the episode's generated transcript, when known. That
    ///     is the language actually spoken, so it wins over guessing from the podcast's text.
    ///   - languageHints: podcast and episode titles and descriptions, used to detect the language
    ///     when no transcript language is known.
    func translated(
        _ chapters: [GeneratedChapter],
        episodeUuid: String,
        transcriptLanguage: String?,
        languageHints: [String?]
    ) async -> [GeneratedChapter] {
        #if os(iOS) && canImport(Translation)
        guard #available(iOS 26.0, *) else { return chapters }

        if let cached = cache[episodeUuid] { return cached }

        guard let target = Self.language(code: transcriptLanguage) ?? Self.detectLanguage(in: languageHints),
              let source = Self.detectLanguage(in: chapters.map(\.title)),
              source.languageCode != target.languageCode
        else { return chapters }

        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else {
            FileLog.shared.addMessage("GeneratedChapterTranslator: \(source.minimalIdentifier) → \(target.minimalIdentifier) not installed (\(status)), keeping original titles")
            return chapters
        }

        do {
            let session = TranslationSession(installedSource: source, target: target)
            let requests = chapters.enumerated().map { index, chapter in
                TranslationSession.Request(sourceText: chapter.title, clientIdentifier: String(index))
            }
            let titles = try await session.translations(from: requests).reduce(into: [Int: String]()) { titles, response in
                if let index = response.clientIdentifier.flatMap(Int.init) {
                    titles[index] = response.targetText
                }
            }
            let result = chapters.enumerated().map { index, chapter in
                GeneratedChapter(title: titles[index] ?? chapter.title, timestamp: chapter.timestamp, startTime: chapter.startTime)
            }
            cache[episodeUuid] = result
            return result
        } catch {
            FileLog.shared.addMessage("GeneratedChapterTranslator: translating to \(target.minimalIdentifier) failed: \(error)")
            return chapters
        }
        #else
        return chapters
        #endif
    }

    private static func language(code: String?) -> Locale.Language? {
        guard let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty else { return nil }
        return Locale.Language(identifier: code)
    }

    /// The dominant language of the given text, or nil when the recognizer isn't reasonably sure.
    private static func detectLanguage(in texts: [String?]) -> Locale.Language? {
        let text = texts.compactMap { $0 }.joined(separator: "\n").strippingHTML
        guard !text.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.5
        else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }
}

private extension String {
    /// Podcast descriptions are often HTML; tags and entities would skew language detection.
    var strippingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&[a-zA-Z#0-9]+;", with: " ", options: .regularExpression)
    }
}
