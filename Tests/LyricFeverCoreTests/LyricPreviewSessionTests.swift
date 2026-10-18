import XCTest
@testable import LyricFeverCore

@MainActor
final class LyricPreviewSessionTests: XCTestCase {
    private let lines = [LyricLine(startTime: 1000, words: "Alpha"), LyricLine(startTime: 2500, words: "Beta")]
    private func playback(_ id: String = "A", position: Double = 1500, playing: Bool = true) -> PlaybackSnapshot {
        PlaybackSnapshot(trackID: id, trackName: "Song", artistName: "Artist", albumName: "Album", durationMS: 30000,
                         positionMS: position, isPlaying: playing)
    }
    private func result(name: String = "Song", artist: String = "Artist", album: String = "Album", duration: Int? = 30000) -> SongResult {
        SongResult(lyricType: "Fixture", songName: name, albumName: album, artistName: artist, lyrics: lines, durationMS: duration)
    }
    private func session(with result: SongResult) -> LyricPreviewSession {
        let source = FakeProvider("Fixture") { _ in NetworkFetchReturn(lyrics: [], colorData: nil) }
        source.searchAction = { _, _ in [result] }
        return LyricPreviewSession(providers: [source])
    }

    func testMetadataMatchAutoSelectsAndPauseDoesNotAdvanceHighlight() async {
        let candidate = result()
        let model = session(with: candidate)
        model.updatePlayback(playback(), autoSearch: false)
        await model.search()?.value
        XCTAssertEqual(model.selectedID, candidate.id)
        XCTAssertEqual(model.activeIndex, 0)
        model.updatePlayback(playback(position: 2600, playing: false), autoSearch: false)
        XCTAssertEqual(model.activeIndex, 1)
        model.updatePlayback(playback(position: 2600, playing: false), autoSearch: false)
        XCTAssertEqual(model.activeIndex, 1)
        XCTAssertEqual(model.displayedPositionMS, 2600)
    }

    func testManualCursorAndOffsetNeverChangePlaybackSnapshot() async {
        let model = session(with: result())
        let snapshot = playback()
        model.updatePlayback(snapshot, autoSearch: false)
        await model.search()?.value
        model.followsPlayback = false
        model.previewPositionMS = 2600
        XCTAssertEqual(model.activeIndex, 1)
        model.offsetMS = 300
        XCTAssertEqual(model.activeIndex, 0)
        model.previewPositionMS = 0
        XCTAssertNil(model.activeIndex)
        XCTAssertEqual(model.playback, snapshot)
        model.followsPlayback = true
        XCTAssertEqual(model.displayedPositionMS, 1500)
    }

    func testPauseResumeAndForwardBackwardSeekFollowOnlyReportedPosition() async {
        let candidate = result()
        let model = session(with: candidate)
        model.updatePlayback(playback(), autoSearch: false)
        await model.search()?.value
        model.updatePlayback(playback(position: 1500, playing: false), autoSearch: false)
        XCTAssertEqual(model.activeIndex, 0)
        XCTAssertEqual(model.displayedPositionMS, 1500)
        model.updatePlayback(playback(position: 2700), autoSearch: false)
        XCTAssertEqual(model.activeIndex, 1)
        model.updatePlayback(playback(position: 500), autoSearch: false)
        XCTAssertNil(model.activeIndex)
        model.updatePlayback(playback(position: 2600), autoSearch: false)
        XCTAssertEqual(model.activeIndex, 1)
        XCTAssertEqual(model.selectedID, candidate.id)
        XCTAssertEqual(model.offsetMS, 0)
    }

    func testTimeoutRecoveryKeepsSelectionButNeverKeepsOldProgress() async {
        let candidate = result()
        let model = session(with: candidate)
        model.updatePlayback(playback(position: 2600), autoSearch: false)
        await model.search()?.value
        model.updatePlayback(nil)
        XCTAssertNil(model.activeIndex)
        XCTAssertEqual(model.displayedPositionMS, 0)
        XCTAssertEqual(model.selectedID, candidate.id)
        model.updatePlayback(playback(position: 1500), autoSearch: false)
        XCTAssertEqual(model.activeIndex, 0)
        XCTAssertEqual(model.displayedPositionMS, 1500)
    }

    func testUnavailablePlaybackStopsLiveHighlightAndCancelsSearch() async {
        let model = session(with: result())
        model.updatePlayback(playback(), autoSearch: false)
        await model.search()?.value
        XCTAssertNotNil(model.activeIndex)
        model.updatePlayback(nil)
        XCTAssertFalse(model.playbackAvailable)
        XCTAssertNil(model.activeIndex)
        XCTAssertFalse(model.isSearching)
    }

    func testTrackChangeClearsOldLyricsAndOffsetBeforeNewSearch() async {
        let model = session(with: result())
        model.updatePlayback(playback(), autoSearch: false)
        await model.search()?.value
        model.offsetMS = 250
        model.updatePlayback(playback("B"), autoSearch: false)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.offsetMS, 0)
    }

    func testUncertainRecordingCanDisplayProvisionallyButUnrelatedQueryCannotAutoApply() {
        for candidate in [result(artist: "Other"), result(name: "Song Live"), result(duration: 35000)] {
            XCTAssertEqual(LyricPreviewSession.preferredCandidate(in: [candidate], playback: playback(), track: "Song", artist: "Artist"), candidate.id)
            XCTAssertFalse(PreviewRecordingMatcher.assessment(candidate, track: "Song", artist: "Artist", playback: playback()).isReliableMatch)
        }
        XCTAssertNil(LyricPreviewSession.preferredCandidate(in: [result()], playback: playback(), track: "Other", artist: "Artist"))
    }

    func testAlbumRanksFirstAndDuplicateExactAlbumsUseStableSourceOrder() {
        let exact = result()
        XCTAssertEqual(LyricPreviewSession.preferredCandidate(in: [result(album: "Other"), exact], playback: playback(), track: "Song", artist: "Artist"), exact.id)
        XCTAssertEqual(LyricPreviewSession.preferredCandidate(in: [exact, result()], playback: playback(), track: "Song", artist: "Artist"), exact.id)
    }

    func testSourceFailureDoesNotHideLaterResults() async {
        let bad = FakeProvider("Bad") { _ in NetworkFetchReturn(lyrics: [], colorData: nil) }
        bad.searchAction = { _, _ in throw LyricSourceError.httpStatus(503) }
        let good = FakeProvider("Good") { _ in NetworkFetchReturn(lyrics: [], colorData: nil) }
        good.searchAction = { [self] _, _ in [result()] }
        let model = LyricPreviewSession(providers: [bad, good])
        model.updatePlayback(playback(), autoSearch: false)
        await model.search()?.value
        XCTAssertEqual(model.sourceErrors.count, 1)
        XCTAssertEqual(model.results.count, 1)
        XCTAssertNotNil(model.selectedID)
        XCTAssertFalse(model.isSearching)
    }

    func testLateAResponseCannotRestoreLyricsAfterAtoBtoA() async {
        let started = expectation(description: "Old search started")
        var continuation: CheckedContinuation<[SongResult], Never>?
        let source = FakeProvider("Slow") { _ in NetworkFetchReturn(lyrics: [], colorData: nil) }
        source.searchAction = { _, _ in await withCheckedContinuation { continuation = $0; started.fulfill() } }
        let model = LyricPreviewSession(providers: [source])
        model.updatePlayback(playback(), autoSearch: false)
        let old = model.search()
        await fulfillment(of: [started], timeout: 2)
        model.updatePlayback(playback("B"), autoSearch: false)
        model.updatePlayback(playback("A"), autoSearch: false)
        continuation?.resume(returning: [result()])
        await old?.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertFalse(model.isSearching)
    }

    func testInvalidSnapshotAndBlankQueriesDoNotStartNetworkWork() async {
        let source = FakeProvider("Fixture") { _ in NetworkFetchReturn(lyrics: [], colorData: nil) }
        var searches = 0
        source.searchAction = { _, _ in searches += 1; return [] }
        let model = LyricPreviewSession(providers: [source])
        model.updatePlayback(playback(position: .nan))
        XCTAssertFalse(model.playbackAvailable)
        XCTAssertNil(model.search())
        model.trackQuery = "Song"
        model.artistQuery = "   "
        await model.search()?.value
        XCTAssertEqual(searches, 1)
    }
}
