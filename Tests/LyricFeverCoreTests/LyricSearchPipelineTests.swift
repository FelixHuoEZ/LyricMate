import XCTest
@testable import LyricFeverCore

@MainActor
final class LyricSearchPipelineTests: XCTestCase {
    private func provider(_ name: String, search: @escaping (String, String) async throws -> [SongResult]) -> FakeProvider {
        let provider = FakeProvider(name) { _ in NetworkFetchReturn(lyrics: [], colorData: nil) }
        provider.searchAction = search
        return provider
    }

    private var result: SongResult {
        SongResult(lyricType: "Test", songName: "Song", albumName: "", artistName: "Artist",
                   lyrics: [LyricLine(startTime: 1000, words: "Alpha")])
    }

    func testSourceFailureDoesNotPreventLaterSearchResults() async throws {
        let result = self.result
        let bad = provider("Bad") { _, _ in throw LyricSourceError.httpStatus(503) }
        let good = provider("Good") { track, artist in
            XCTAssertEqual(track, "Song"); XCTAssertEqual(artist, "Artist")
            return [result]
        }
        var errors: [String] = []
        var results: [SongResult] = []
        try await LyricSearchPipeline.search(trackName: "Song", artistName: "Artist", providers: [bad, good],
                                             validate: { try Task.checkCancellation() },
                                             failure: { errors.append($0.providerName); _ = $1 }, append: { results += $0 })
        XCTAssertEqual(errors, ["Bad"])
        XCTAssertEqual(results.count, 1)
    }

    func testCancellationDoesNotStartNextProvider() async throws {
        for error in [CancellationError(), URLError(.cancelled)] as [Error] {
            let cancelled = provider("Cancelled") { _, _ in throw error }
            let next = provider("Next") { _, _ in XCTFail("Cancellation must stop fallback"); return [] }
            do {
                try await LyricSearchPipeline.search(trackName: "Song", artistName: "Artist", providers: [cancelled, next],
                                                     validate: {}, failure: { _, _ in XCTFail("Cancellation is not a provider failure") },
                                                     append: { _ in XCTFail("No results expected") })
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testPlaybackChangeRejectsReturnedResults() async throws {
        var current = true
        let result = self.result
        let old = provider("Old") { _, _ in current = false; return [result] }
        do {
            try await LyricSearchPipeline.search(trackName: "Song", artistName: "Artist", providers: [old],
                                                 validate: { if !current { throw FetchError.staleTrack } },
                                                 failure: { _, _ in XCTFail("Stale search must not update errors") },
                                                 append: { _ in XCTFail("Stale search must not update results") })
            XCTFail("Expected stale search")
        } catch { XCTAssertTrue(error is FetchError) }
    }

    func testEmptyAndUnsynchronizedResultsAreNotDisplayedAsSuccess() async throws {
        let empty = provider("Empty") { _, _ in [] }
        let invalid = provider("Invalid") { _, _ in
            [SongResult(lyricType: "Test", songName: "Song", albumName: "", artistName: "Artist",
                        lyrics: [LyricLine(startTime: 0, words: "Untimed")])]
        }
        var count = 0
        try await LyricSearchPipeline.search(trackName: "Song", artistName: "Artist", providers: [empty, invalid],
                                             validate: {}, failure: { _, _ in XCTFail("Empty is not an error") }, append: { count += $0.count })
        XCTAssertEqual(count, 0)
    }
}
