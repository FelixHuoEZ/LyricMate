import LyricMateLocalization
import XCTest
@testable import LyricFeverCore

@MainActor
final class LyricSourceFailureTests: XCTestCase {
    private let candidates = Data(#"{"apiVersion":1,"songs":[{"id":"a","trackName":"Song","artistName":"Artist","albumName":"Album","durationMs":30000,"hasSyncedLyrics":true}]}"#.utf8)

    func testAllCandidateFetchesOfflineRemainAnError() async throws {
        let candidates = self.candidates
        let (session, host) = StubURLProtocol.session { request in
            if request.url!.path.hasSuffix("search") { return .init(data: candidates) }
            throw URLError(.notConnectedToInternet)
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session), requestDelay: 0)
        do {
            _ = try await provider.search(trackName: "Song", artistName: "Artist")
            XCTFail("Offline candidate fetches must not become an empty no-lyrics result")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testAllCandidateFetchesTimedOutRemainAnError() async throws {
        let candidates = self.candidates
        let (session, host) = StubURLProtocol.session { request in
            if request.url!.path.hasSuffix("search") { return .init(data: candidates) }
            throw URLError(.timedOut)
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session), requestDelay: 0)
        do {
            _ = try await provider.search(trackName: "Song", artistName: "Artist")
            XCTFail("Timeout must not become an empty no-lyrics result")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
    }

    func testEarlierCandidateFailureDoesNotDiscardLaterSuccess() async throws {
        let data = Data(#"{"apiVersion":1,"songs":[{"id":"a","trackName":"Song","artistName":"Artist","durationMs":30000,"hasSyncedLyrics":true},{"id":"b","trackName":"Song","artistName":"Artist","durationMs":30000,"hasSyncedLyrics":true}]}"#.utf8)
        let (session, host) = StubURLProtocol.session { request in
            if request.url!.path.hasSuffix("search") { return .init(data: data) }
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            if id == "a" { return .init(status: 503) }
            return .init(data: Data(#"{"apiVersion":1,"id":"b","syncedLyrics":"[00:01]SyntheticAlpha\n[00:02]SyntheticBeta","instrumental":false}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session), requestDelay: 0)
        let results = try await provider.search(trackName: "Song", artistName: "Artist")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.lyrics.count, 2)
    }

    func testPreviewShowsSourceFailureInsteadOfDefiniteNoLyrics() async throws {
        let candidates = self.candidates
        let (session, host) = StubURLProtocol.session { request in
            if request.url!.path.hasSuffix("search") { return .init(data: candidates) }
            throw URLError(.notConnectedToInternet)
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session), requestDelay: 0)
        let model = LyricPreviewSession(providers: [provider])
        model.trackQuery = "Song"
        model.artistQuery = "Artist"
        await model.search()?.value
        XCTAssertFalse(model.isSearching)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.sourceErrors.count, 1)
        XCTAssertTrue(model.status.contains(L10n.text("No usable lyrics retrieved; some source requests failed. Check the errors.")))
    }

    func testExplicitSearchAfterOfflineRecoversAndClearsOldErrors() async {
        var offline = true
        let provider = FakeProvider("Synthetic") { _ in NetworkFetchReturn(lyrics: [], colorData: nil) }
        provider.searchAction = { track, artist in
            if offline { throw URLError(.notConnectedToInternet) }
            return [SongResult(lyricType: "Synthetic", songName: track, albumName: "Album", artistName: artist,
                               lyrics: [LyricLine(startTime: 1000, words: "SyntheticAlpha")], durationMS: 30000)]
        }
        let model = LyricPreviewSession(providers: [provider])
        model.updatePlayback(PlaybackSnapshot(trackID: "A", trackName: "Song", artistName: "Artist", albumName: "Album",
                                              durationMS: 30000, positionMS: 1500, isPlaying: true), autoSearch: false)
        await model.search()?.value
        XCTAssertEqual(model.sourceErrors.count, 1)
        XCTAssertNil(model.activeIndex)
        offline = false
        await model.search()?.value
        XCTAssertTrue(model.sourceErrors.isEmpty)
        XCTAssertEqual(model.results.count, 1)
        XCTAssertEqual(model.activeIndex, 0)
        XCTAssertFalse(model.isSearching)
    }

    func testLateOfflineErrorAfterRapidSwitchCannotOverwriteNewSong() async {
        let started = expectation(description: "Old source request entered")
        var continuation: CheckedContinuation<Void, Never>?
        var call = 0
        let provider = FakeProvider("Synthetic") { _ in NetworkFetchReturn(lyrics: [], colorData: nil) }
        provider.searchAction = { track, artist in
            call += 1
            if call == 1 {
                await withCheckedContinuation { continuation = $0; started.fulfill() }
                throw URLError(.notConnectedToInternet)
            }
            return [SongResult(lyricType: "Synthetic", songName: track, albumName: "Album", artistName: artist,
                               lyrics: [LyricLine(startTime: 1000, words: "SyntheticNew")], durationMS: 30000)]
        }
        let model = LyricPreviewSession(providers: [provider])
        func snapshot(_ id: String) -> PlaybackSnapshot {
            PlaybackSnapshot(trackID: id, trackName: id, artistName: "Artist", albumName: "Album", durationMS: 30000,
                             positionMS: 1500, isPlaying: true)
        }
        model.updatePlayback(snapshot("A"), autoSearch: false)
        let old = model.search()
        await fulfillment(of: [started], timeout: 2)
        model.updatePlayback(snapshot("B"), autoSearch: false)
        model.updatePlayback(snapshot("C"), autoSearch: false)
        await model.search()?.value
        let selected = model.selectedID
        continuation?.resume()
        await old?.value
        XCTAssertEqual(model.playback?.trackID, "C")
        XCTAssertEqual(model.selected?.songName, "C")
        XCTAssertEqual(model.selectedID, selected)
        XCTAssertTrue(model.sourceErrors.isEmpty)
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.activeIndex, 0)
    }

    func testEmptySuccessfulSourceDoesNotInventNetworkFailure() async {
        let provider = FakeProvider("Empty") { _ in NetworkFetchReturn(lyrics: [], colorData: nil) }
        let model = LyricPreviewSession(providers: [provider])
        model.trackQuery = "Song"
        model.artistQuery = "Artist"
        await model.search()?.value
        XCTAssertTrue(model.sourceErrors.isEmpty)
        XCTAssertEqual(model.status, L10n.text("No timed lyrics found."))
    }

    func testAllMalformedCandidateFetchesRemainAResponseError() async throws {
        let candidates = self.candidates
        let (session, host) = StubURLProtocol.session { request in
            .init(data: request.url!.path.hasSuffix("search") ? candidates : Data("{broken".utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session), requestDelay: 0)
        do {
            _ = try await provider.search(trackName: "Song", artistName: "Artist")
            XCTFail("Broken responses must not become definite no-lyrics results")
        } catch { XCTAssertEqual(error as? LyricSourceError, .invalidResponse) }
    }
}
