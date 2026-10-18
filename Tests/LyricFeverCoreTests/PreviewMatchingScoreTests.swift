import XCTest
@testable import LyricFeverCore

@MainActor
final class PreviewMatchingScoreTests: XCTestCase {
    private let playback = PlaybackSnapshot(trackID: "A", trackName: "Song", artistName: "Artist", albumName: "Album",
                                            durationMS: 30000, positionMS: 0, isPlaying: true)
    private func candidate(title: String = "Song", artist: String = "Artist", album: String = "Album", duration: Int? = 30000,
                           manual: Bool = false) -> SongResult {
        .init(lyricType: "Fixture", songName: title, albumName: album, artistName: artist,
              lyrics: [.init(startTime: 5000, words: "Synthetic first"), .init(startTime: 7000, words: "Synthetic next")],
              durationMS: duration, requiresManualSelection: manual)
    }
    private func score(_ value: SongResult) -> PreviewRecordingMatcher.Assessment {
        PreviewRecordingMatcher.assessment(value, track: "Song", artist: "Artist", playback: playback)
    }
    func testScoringSeparatesProvisionalDisplayFromReliableRecordingEvidence() {
        XCTAssertEqual(score(candidate()).score, 100)
        XCTAssertEqual(score(candidate(album: "Other")).score, 90)
        XCTAssertEqual(score(candidate(duration: 31000)).score, 98)
        XCTAssertEqual(score(candidate(duration: 32000)).score, 95)
        for value in [candidate(title: "Song Live"), candidate(artist: "Cover"), candidate(duration: 32001),
                      candidate(duration: nil), candidate(manual: true)] {
            XCTAssertFalse(score(value).isReliableMatch)
            XCTAssertTrue(score(value).canPreview)
            XCTAssertEqual(PreviewRecordingMatcher.preferred(in: [value], playback: playback, track: "Song", artist: "Artist"), value.id)
        }
        for value in [candidate(duration: Int.max), candidate(duration: Int.min)] {
            XCTAssertFalse(score(value).canPreview)
            XCTAssertNil(PreviewRecordingMatcher.preferred(in: [value], playback: playback, track: "Song", artist: "Artist"))
        }
        XCTAssertTrue(score(candidate(album: "Other", duration: 32000)).isReliableMatch)
        XCTAssertEqual(score(candidate(duration: nil)).score, 80)
    }
    func testHighestScoreLoadsAndResultsRankStably() async {
        let low = candidate(album: "Other"), high = candidate(), tied = candidate()
        let provider = FakeProvider("Fixture") { _ in .init(lyrics: [], colorData: nil) }
        provider.searchAction = { _, _ in [low, high, tied] }
        let session = LyricPreviewSession(providers: [provider])
        session.updatePlayback(playback, autoSearch: false)
        await session.search()?.value
        XCTAssertEqual(session.selectedID, high.id)
        XCTAssertEqual(session.rankedResults.map(\.id), [high.id, tied.id, low.id])
        XCTAssertEqual(session.recommendedID, high.id)
    }
    func testLateBetterCandidateNeverOverridesManualChoice() async {
        let low = candidate(album: "Other"), high = candidate()
        let first = FakeProvider("First") { _ in .init(lyrics: [], colorData: nil) }
        first.searchAction = { _, _ in [low] }
        let started = expectation(description: "Second source")
        var continuation: CheckedContinuation<[SongResult], Never>?
        let slow = FakeProvider("Slow") { _ in .init(lyrics: [], colorData: nil) }
        slow.searchAction = { _, _ in await withCheckedContinuation { continuation = $0; started.fulfill() } }
        let session = LyricPreviewSession(providers: [first, slow])
        session.updatePlayback(playback, autoSearch: false)
        let search = session.search()
        await fulfillment(of: [started], timeout: 2)
        session.select(low.id)
        session.offsetMS = 250
        continuation?.resume(returning: [high])
        await search?.value
        XCTAssertEqual(session.selectedID, low.id)
        XCTAssertEqual(session.offsetMS, 250)
    }
    func testTitleOnlyQueryIsAllowedAndNeverInventsSingerEvidence() async throws {
        var calls = 0
        let body = Data(#"[{"id":1,"trackName":"Song","artistName":"Cover","albumName":"Album","duration":30,"instrumental":false,"syncedLyrics":"[00:05]Synthetic first\n[00:07]Synthetic next"}]"#.utf8)
        let (http, host) = StubURLProtocol.session { request in
            calls += 1
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertFalse(query.contains { $0.name == "artist_name" })
            return .init(data: body)
        }
        defer { http.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: http))
        let session = LyricPreviewSession(providers: [provider])
        session.updatePlayback(playback, autoSearch: false)
        session.artistQuery = ""
        await session.search()?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(session.results.count, 1)
        XCTAssertEqual(session.selectedID, session.results[0].id)
        XCTAssertEqual(session.matchAssessment(for: session.results[0]).score, 70)
        XCTAssertFalse(session.matchAssessment(for: session.results[0]).isReliableMatch)
        XCTAssertTrue(session.status.contains("临时匹配"))
    }
    func testFallbackDisplaysCoverProvisionallyWithoutInventingRecordingEvidence() async throws {
        let body = Data(#"[{"id":1,"trackName":"Song","artistName":"Cover","albumName":"Album","duration":30,"instrumental":false,"syncedLyrics":"[00:05]Synthetic first\n[00:07]Synthetic next"}]"#.utf8)
        let (http, host) = StubURLProtocol.session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            return .init(data: query.contains { $0.name == "artist_name" } ? Data("[]".utf8) : body)
        }
        defer { http.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: http))
        let session = LyricPreviewSession(providers: [provider])
        session.updatePlayback(playback, autoSearch: false)
        await session.search()?.value
        XCTAssertEqual(provider.requestCount, 2)
        XCTAssertEqual(session.results.first?.artistName, "Cover")
        XCTAssertEqual(session.selectedID, session.results[0].id)
        XCTAssertTrue(session.matchingMessage.contains("仅歌名"))
        XCTAssertFalse(session.matchAssessment(for: session.results[0]).isReliableMatch)
        XCTAssertTrue(session.status.contains("临时匹配"))
        let presentation = PreviewLyricPresentation(session: session)
        XCTAssertEqual(presentation.currentLine, "Synthetic first")
        XCTAssertEqual(presentation.nextLine, "Synthetic next")
        XCTAssertTrue(presentation.hasVisibleLyrics)
        XCTAssertNotNil(session.selectedID)
    }

    func testSupplementFailureKeepsAlreadyFetchedPrimaryCandidatesAndReportsError() async throws {
        let body = Data(#"[{"id":1,"trackName":"Song","artistName":"Cover","albumName":"Album","duration":30,"instrumental":false,"syncedLyrics":"[00:05]Synthetic first\n[00:07]Synthetic next"}]"#.utf8)
        let (http, host) = StubURLProtocol.session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            return query.contains { $0.name == "artist_name" } ? .init(data: body) : .init(status: 503)
        }
        defer { http.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: http))
        let session = LyricPreviewSession(providers: [provider])
        session.updatePlayback(playback, autoSearch: false)
        await session.search()?.value
        XCTAssertEqual(provider.requestCount, 2)
        XCTAssertEqual(session.results.count, 1)
        XCTAssertEqual(session.sourceErrors.count, 1)
        XCTAssertEqual(session.selectedID, session.results[0].id)
        XCTAssertTrue(session.status.contains("临时匹配"))
    }

    func testPrimaryCandidateIsVisibleDuringTitleOnlyFallbackAndDuplicateIsNotAddedTwice() async throws {
        let blocked = expectation(description: "title-only fallback pending")
        let release = DispatchSemaphore(value: 0)
        let body = Data(#"[{"id":1,"trackName":"Song","artistName":"Cover","albumName":"Album","duration":30,"instrumental":false,"syncedLyrics":"[00:05]Synthetic first\n[00:07]Synthetic next"}]"#.utf8)
        let (http, host) = StubURLProtocol.session { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if !items.contains(where: { $0.name == "artist_name" }) {
                blocked.fulfill(); _ = release.wait(timeout: .now() + 3)
            }
            return .init(data: body)
        }
        defer { release.signal(); http.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib),
                                                    client: .init(session: http), requestDelay: 0)
        let model = LyricPreviewSession(providers: [provider])
        model.updatePlayback(playback, autoSearch: false)
        let task = model.search()
        await fulfillment(of: [blocked], timeout: 2)
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.selected?.artistName, "Cover")
        let firstID = model.selectedID
        release.signal(); await task?.value
        XCTAssertEqual(model.results.count, 1)
        XCTAssertEqual(model.selectedID, firstID)
    }

    func testTitleOnlySupplementStillFiltersUnrelatedTitlesBeforeEarlyDelivery() async throws {
        let body = Data(#"[{"id":1,"trackName":"Unrelated","artistName":"Artist","albumName":"Album","duration":30,"instrumental":false,"syncedLyrics":"[00:05]Synthetic first\n[00:07]Synthetic next"}]"#.utf8)
        let (http, host) = StubURLProtocol.session { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            return .init(data: items.contains { $0.name == "artist_name" } ? Data("[]".utf8) : body)
        }
        defer { http.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib),
                                                    client: .init(session: http), requestDelay: 0)
        let model = LyricPreviewSession(providers: [provider])
        model.updatePlayback(playback, autoSearch: false)
        await model.search()?.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedID)
    }
}
