import XCTest
@testable import LyricFeverCore

@MainActor
final class PreviewProgressiveSelectionTests: XCTestCase {
    @MainActor private final class Pending {
        let started: XCTestExpectation
        var continuation: CheckedContinuation<[SongResult], Never>?
        init(_ name: String) { started = XCTestExpectation(description: name) }
        func provider() -> FakeProvider {
            let source = FakeProvider("Pending") { _ in .init(lyrics: [], colorData: nil) }
            source.searchAction = { _, _ in
                await withCheckedContinuation { self.continuation = $0; self.started.fulfill() }
            }
            return source
        }
        func finish(_ results: [SongResult] = []) { continuation?.resume(returning: results); continuation = nil }
    }
    private let playback = PlaybackSnapshot(trackID: "spotify:track:Progressive", trackName: "Song", artistName: "Artist",
                                            albumName: "Album", durationMS: 30000, positionMS: 1500, isPlaying: true)
    private func candidate(duration: Int? = 30000, album: String = "Album", artist: String = "Artist", manual: Bool = false) -> SongResult {
        SongResult(lyricType: "Fixture", songName: "Song", albumName: album, artistName: artist,
                   lyrics: [.init(startTime: 1000, words: "Synthetic"), .init(startTime: 2000, words: "Second")],
                   durationMS: duration, sourceIdentity: "fixture", sourceSongID: UUID().uuidString, requiresManualSelection: manual)
    }
    private func immediate(_ results: [SongResult]) -> FakeProvider {
        let source = FakeProvider("Immediate") { _ in .init(lyrics: [], colorData: nil) }
        source.searchAction = { _, _ in results }; return source
    }
    private func session(_ providers: [LyricProvider], preferences: PreviewRecordingPreferences? = nil) -> LyricPreviewSession {
        let model = LyricPreviewSession(providers: providers, preferences: preferences)
        model.updatePlayback(playback, autoSearch: false); return model
    }

    func testPerfectCandidateLoadsBeforeRemainingSearchCompletes() async {
        let perfect = candidate(), later = Pending("remaining source")
        let model = session([immediate([perfect]), later.provider()])
        let task = model.search()
        await fulfillment(of: [later.started], timeout: 2)
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.selectedID, perfect.id)
        XCTAssertEqual(model.activeIndex, 0)
        later.finish(); await task?.value
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.status.contains("人工"))
    }

    func testHTTPResultLoadsBeforeOtherCandidatesFromSameSourceFinish() async throws {
        let blocked = expectation(description: "second candidate requested")
        let release = DispatchSemaphore(value: 0)
        let (http, host) = StubURLProtocol.session { request in
            if request.url!.path.hasSuffix("search") {
                return .init(data: Data(#"{"apiVersion":1,"songs":[{"id":"one","trackName":"Song","artistName":"Artist","albumName":"Album","durationMs":30000,"hasSyncedLyrics":true},{"id":"two","trackName":"Song","artistName":"Artist","albumName":"Album","durationMs":30000,"hasSyncedLyrics":true}]}"#.utf8))
            }
            if request.url!.query!.contains("two") {
                blocked.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return .init(status: 503)
            }
            return .init(data: Data(#"{"apiVersion":1,"id":"one","instrumental":false,"syncedLyrics":"[00:01]Synthetic\n[00:02]Second"}"#.utf8))
        }
        defer { release.signal(); http.invalidateAndCancel() }
        let manifest = LyricSourceManifest(schemaVersion: 1, apiVersion: 1, name: "HTTP", baseURL: "https://\(host)/",
                                          capabilities: ["search", "syncedLyrics"], auth: .init(type: "none"), format: .lyricfeverV1)
        let provider = try CustomHTTPSourceProvider(manifest: manifest, client: .init(session: http), requestDelay: 0)
        let model = session([provider])
        let task = model.search()
        await fulfillment(of: [blocked], timeout: 2)
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.selected?.sourceSongID, "one")
        release.signal(); await task?.value
        XCTAssertEqual(model.results.count, 1, "Streamed results must not be appended again at source completion")
        XCTAssertEqual(model.selected?.sourceSongID, "one")
    }

    func test98LoadsThen100UpgradesAndTieUsesEarlierSource() async {
        let provisional = candidate(duration: 30800), perfect = candidate(), tie = candidate()
        let second = Pending("second"), third = Pending("third")
        let model = session([immediate([provisional]), second.provider(), third.provider()])
        let task = model.search()
        await fulfillment(of: [second.started], timeout: 2)
        XCTAssertEqual(model.matchAssessment(for: provisional).score, 98)
        XCTAssertEqual(model.selectedID, provisional.id)
        second.finish([perfect])
        await fulfillment(of: [third.started], timeout: 2)
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.selectedID, perfect.id)
        third.finish([tie]); await task?.value
        XCTAssertEqual(model.selectedID, perfect.id)
        XCTAssertEqual(model.rankedResults.map(\.id), [perfect.id, tie.id, provisional.id])
    }

    func testValidCandidatesAtOrBelow95AndUncertainRecordingsLoadWhileSearchContinues() async {
        for value in [candidate(duration: 31500), candidate(artist: "Other"), candidate(manual: true),
                      candidate(duration: 35000), candidate(duration: nil)] {
            let later = Pending("blocked source")
            let model = session([immediate([value]), later.provider()])
            let task = model.search()
            await fulfillment(of: [later.started], timeout: 2)
            XCTAssertEqual(model.selectedID, value.id)
            XCTAssertEqual(PreviewLyricPresentation(session: model).currentLine, "Synthetic")
            if !model.matchAssessment(for: value).isReliableMatch { XCTAssertTrue(model.status.contains("临时匹配")) }
            later.finish(); await task?.value
            XCTAssertEqual(model.selectedID, value.id)
        }
    }

    func testLowScoreLoadsThenHigherScoresUpgradeWithoutDowngradingOrBreakingTies() async {
        let low = candidate(artist: "Cover"), middle = candidate(album: "Other"), perfect = candidate(), tie = candidate()
        let second = Pending("middle"), third = Pending("perfect"), fourth = Pending("tie and lower")
        let model = session([immediate([low]), second.provider(), third.provider(), fourth.provider()])
        let task = model.search()
        await fulfillment(of: [second.started], timeout: 2)
        XCTAssertEqual(model.selectedID, low.id)
        XCTAssertEqual(model.matchAssessment(for: low).score, 70)
        second.finish([middle])
        await fulfillment(of: [third.started], timeout: 2)
        XCTAssertEqual(model.selectedID, middle.id)
        third.finish([perfect])
        await fulfillment(of: [fourth.started], timeout: 2)
        XCTAssertEqual(model.selectedID, perfect.id)
        fourth.finish([tie, candidate(artist: "Cover")]); await task?.value
        XCTAssertEqual(model.selectedID, perfect.id)
        XCTAssertEqual(Array(model.rankedResults.prefix(4)).map(\.id), [perfect.id, tie.id, middle.id, low.id])
    }

    func testInvalidHighScoreCannotReplaceValidLowScoreLyrics() async {
        let low = candidate(artist: "Cover"), later = Pending("invalid later")
        let model = session([immediate([low]), later.provider()])
        let task = model.search()
        await fulfillment(of: [later.started], timeout: 2)
        XCTAssertEqual(model.selectedID, low.id)
        let invalid = SongResult(lyricType: "Fixture", songName: "Song", albumName: "Album", artistName: "Artist",
                                 lyrics: [.init(startTime: 0, words: "Untimed")], durationMS: 30000)
        let outsideTrack = SongResult(lyricType: "Fixture", songName: "Song", albumName: "Album", artistName: "Artist",
                                      lyrics: [.init(startTime: 60000, words: "Beyond track")], durationMS: 30000)
        later.finish([invalid, outsideTrack, candidate(duration: Int.max)]); await task?.value
        XCTAssertEqual(model.selectedID, low.id)
        XCTAssertEqual(model.recommendedID, low.id)
        XCTAssertEqual(PreviewLyricPresentation(session: model).currentLine, "Synthetic")
    }

    func testLowScoreHTTPResultLoadsBeforeSameSourceSecondLyricReturns() async throws {
        let blocked = expectation(description: "second low-score candidate requested")
        let release = DispatchSemaphore(value: 0)
        let (http, host) = StubURLProtocol.session { request in
            if request.url!.path.hasSuffix("search") {
                return .init(data: Data(#"{"apiVersion":1,"songs":[{"id":"one","trackName":"Song","artistName":"Cover","albumName":"Album","durationMs":30000,"hasSyncedLyrics":true},{"id":"two","trackName":"Song","artistName":"Artist","albumName":"Album","durationMs":30000,"hasSyncedLyrics":true}]}"#.utf8))
            }
            if request.url!.query!.contains("two") {
                blocked.fulfill(); _ = release.wait(timeout: .now() + 3)
                return .init(data: Data(#"{"apiVersion":1,"id":"two","instrumental":false,"syncedLyrics":"[00:01]Better\n[00:02]Second"}"#.utf8))
            }
            return .init(data: Data(#"{"apiVersion":1,"id":"one","instrumental":false,"syncedLyrics":"[00:01]Synthetic\n[00:02]Second"}"#.utf8))
        }
        defer { release.signal(); http.invalidateAndCancel() }
        let manifest = LyricSourceManifest(schemaVersion: 1, apiVersion: 1, name: "HTTP", baseURL: "https://\(host)/",
                                          capabilities: ["search", "syncedLyrics"], auth: .init(type: "none"), format: .lyricfeverV1)
        let provider = try CustomHTTPSourceProvider(manifest: manifest, client: .init(session: http), requestDelay: 0)
        let model = session([provider])
        let task = model.search()
        await fulfillment(of: [blocked], timeout: 2)
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.selected?.sourceSongID, "one")
        XCTAssertEqual(model.selected.map { model.matchAssessment(for: $0).score }, 70)
        release.signal(); await task?.value
        XCTAssertEqual(model.selected?.sourceSongID, "two")
        XCTAssertEqual(model.results.count, 2)
    }

    func testManualChoiceOrOffsetPinsAgainstLaterPerfectCandidate() async {
        for changeOffset in [false, true] {
            let provisional = candidate(artist: "Cover"), other = candidate(artist: "Another Cover"), perfect = candidate()
            let later = Pending("later perfect")
            let model = session([immediate([provisional, other]), later.provider()])
            let task = model.search()
            await fulfillment(of: [later.started], timeout: 2)
            if changeOffset { model.offsetMS = 250 }
            else { model.select(other.id, remember: false) }
            later.finish([perfect]); await task?.value
            XCTAssertEqual(model.selectedID, changeOffset ? provisional.id : other.id)
            XCTAssertEqual(model.offsetMS, changeOffset ? 250 : 0)
            XCTAssertTrue(model.status.contains("人工"))
        }
    }

    func testLateRememberedChoiceOverridesProvisionalAndKeepsOffset() async {
        let suite = "preview.progressive.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        let remembered = candidate(album: "Other"), perfect = candidate()
        XCTAssertTrue(preferences.remember(remembered, playback: playback, offsetMS: 350))
        let second = Pending("remembered source"), third = Pending("later source")
        let model = session([immediate([perfect]), second.provider(), third.provider()], preferences: preferences)
        let task = model.search()
        await fulfillment(of: [second.started], timeout: 2)
        XCTAssertEqual(model.selectedID, perfect.id)
        second.finish([remembered])
        await fulfillment(of: [third.started], timeout: 2)
        XCTAssertEqual(model.selectedID, remembered.id)
        XCTAssertEqual(model.offsetMS, 350)
        third.finish([candidate()]); await task?.value
        XCTAssertEqual(model.selectedID, remembered.id)
        XCTAssertEqual(model.offsetMS, 350)
    }

    func testTrackChangeDiscardsLateUpgradeAndClearsEarlySelection() async {
        let early = candidate(), later = Pending("late old track")
        let model = session([immediate([early]), later.provider()])
        let task = model.search()
        await fulfillment(of: [later.started], timeout: 2)
        XCTAssertEqual(model.selectedID, early.id)
        model.updatePlayback(.init(trackID: "spotify:track:New", trackName: "New", artistName: "Artist", albumName: "Album",
                                   durationMS: 30000, positionMS: 0, isPlaying: true), autoSearch: false)
        later.finish([candidate()]); await task?.value
        XCTAssertNil(model.selectedID)
        XCTAssertTrue(model.results.isEmpty)
    }

    func testSourceFailureAfterEarlySelectionKeepsLyricsAndDoesNotSaveAutomaticChoice() async {
        let suite = "preview.progressive.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        let provisional = candidate(artist: "Cover")
        let bad = FakeProvider("Failure") { _ in .init(lyrics: [], colorData: nil) }
        bad.searchAction = { _, _ in throw LyricSourceError.httpStatus(503) }
        let model = session([immediate([provisional]), bad], preferences: preferences)
        await model.search()?.value
        XCTAssertEqual(model.selectedID, provisional.id)
        XCTAssertEqual(model.sourceErrors.count, 1)
        XCTAssertTrue(preferences.entries.isEmpty)
    }
}
