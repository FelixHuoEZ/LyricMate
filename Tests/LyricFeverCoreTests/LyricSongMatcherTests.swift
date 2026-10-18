import XCTest
@testable import LyricFeverCore

@MainActor
final class LyricSongMatcherTests: XCTestCase {
    private func song(_ title: String = "Song", artist: String = "Artist", album: String? = "Album", duration: Double? = 30000) -> HTTPSourceSong {
        HTTPSourceSong(id: UUID().uuidString, trackName: title, artistName: artist, albumName: album, durationMs: duration, hasSyncedLyrics: true)
    }

    func testWrongArtistAndCoverAreRejected() async {
        XCTAssertTrue(LyricSongMatcher.candidates([song(artist: "Other Artist")], request: request()).isEmpty)
    }

    func testVersionsAreNotStripped() async {
        for title in ["Song Live", "Song (Remix)", "Song (Acoustic)", "Song (Sped Up)", "Song (Radio Edit)", "Song Taylor's Version"] {
            XCTAssertTrue(LyricSongMatcher.candidates([song(title)], request: request()).isEmpty, title)
        }
    }

    func testMissingAlbumDoesNotPreventUnambiguousMatch() async {
        XCTAssertEqual(LyricSongMatcher.candidates([song(album: nil)], request: request()).count, 1)
    }

    func testNormalizationAndUnicode() async {
        XCTAssertEqual(LyricSongMatcher.normalized("  HELLO!  "), "hello")
        XCTAssertEqual(LyricSongMatcher.normalized("e\u{301}"), LyricSongMatcher.normalized("\u{E9}"))
        XCTAssertEqual(LyricSongMatcher.candidates([song(" SONG ")], request: request()).count, 1)
    }

    func testAmbiguousCandidatesAreNotAutomaticallyChosen() async {
        XCTAssertTrue(LyricSongMatcher.candidates([song(), song()], request: request()).isEmpty)
    }

    func testAlbumCanDisambiguate() async {
        let correct = song()
        let result = LyricSongMatcher.candidates([song(album: "Other"), correct], request: request())
        XCTAssertEqual(result.map(\.id), [correct.id])
    }

    func testDurationBoundaryAndMissingDuration() async {
        XCTAssertEqual(LyricSongMatcher.candidates([song(duration: 32000)], request: request()).count, 1)
        XCTAssertTrue(LyricSongMatcher.candidates([song(duration: 32001)], request: request()).isEmpty)
        XCTAssertTrue(LyricSongMatcher.candidates([song(duration: 320000)], request: request()).isEmpty)
        XCTAssertEqual(LyricSongMatcher.candidates([song(duration: nil)], request: request()).count, 1)
    }

    func testMissingArtistAndPartialDuetDoNotMatch() async {
        XCTAssertTrue(LyricSongMatcher.candidates([song()], request: request(artist: nil)).isEmpty)
        XCTAssertTrue(LyricSongMatcher.candidates([song(artist: "A & C")], request: request(artist: "A & B")).isEmpty)
    }
}
