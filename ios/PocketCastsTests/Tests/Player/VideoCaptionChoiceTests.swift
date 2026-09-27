import XCTest
@testable import podcasts

final class VideoCaptionChoiceTests: XCTestCase {
    func testRawValueRoundTrips() {
        let choices: [VideoCaptionChoice] = [.off, .transcript, .embedded(languageTag: nil), .embedded(languageTag: "nl-NL")]
        for choice in choices {
            XCTAssertEqual(VideoCaptionChoice(rawValue: choice.rawValue), choice)
        }
    }

    func testEmbeddedKeepsLanguageTag() {
        XCTAssertEqual(VideoCaptionChoice(rawValue: "embedded:en"), .embedded(languageTag: "en"))
    }

    func testUnknownRawValueIsRejected() {
        XCTAssertNil(VideoCaptionChoice(rawValue: "subtitles"))
    }
}
