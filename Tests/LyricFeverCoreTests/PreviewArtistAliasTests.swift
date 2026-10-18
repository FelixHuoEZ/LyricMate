import LyricMateLocalization
import XCTest
@testable import LyricFeverCore

@MainActor
final class PreviewArtistAliasTests: XCTestCase {
    private func playback() -> PlaybackSnapshot {
        .init(trackID: "spotify:track:AliasFixture", trackName: "Alias Test Song", artistName: "Joker Xue",
              albumName: "Alias Test Album", durationMS: 30758, positionMS: 7000, isPlaying: true)
    }

    private func candidate(artist: String = "\u{859B}\u{4E4B}\u{8C26}", title: String = "Alias Test Song",
                           album: String = "Alias Test Album", duration: Int? = 30000, manual: Bool = false) -> SongResult {
        .init(lyricType: "Fixture", songName: title, albumName: album, artistName: artist,
              lyrics: [.init(startTime: 5000, words: "Synthetic first"), .init(startTime: 9000, words: "Synthetic next")],
              durationMS: duration, sourceIdentity: "fixture|https://fixture.invalid/", sourceSongID: "1", requiresManualSelection: manual)
    }

    private func assessment(_ value: SongResult) -> PreviewRecordingMatcher.Assessment {
        let snapshot = playback()
        return PreviewRecordingMatcher.assessment(value, track: snapshot.trackName, artist: snapshot.artistName, playback: snapshot)
    }

    func testVerifiedSingerAliasCanMatchWithAlbumAndTightDurationEvidence() {
        let value = candidate()
        XCTAssertNotNil(PreviewRecordingMatcher.artistRelation(value.artistName, "Joker Xue"))
        XCTAssertEqual(assessment(value).score, 98)
        XCTAssertTrue(assessment(value).isReliableMatch)
        XCTAssertEqual(PreviewRecordingMatcher.preferred(in: [value], playback: playback(), track: playback().trackName, artist: "Joker Xue"), value.id)
    }

    func testAliasIsAnExactSingleSingerAllowlistNotFuzzyTransliteration() {
        XCTAssertNotNil(PreviewRecordingMatcher.artistRelation("JOKER XUE", "\u{859B}\u{4E4B}\u{8B19}"))
        for artist in ["Joker", "Xue", "Joker Xue Cover", "Joker Xue & Other", "\u{859B}\u{4E4B}\u{8C26}\u{3001}Other"] {
            XCTAssertNil(PreviewRecordingMatcher.artistRelation(artist, "Joker Xue"))
        }
        XCTAssertEqual(PreviewRecordingMatcher.artistRelation("Stefanie Sun", "\u{5B59}\u{71D5}\u{59FF}"), .searchLabel)
    }

    func testAliasReliabilityStillRequiresRecordingEvidence() {
        for value in [candidate(album: "Other"), candidate(album: ""), candidate(duration: nil), candidate(duration: 29757),
                      candidate(title: "Alias Test Song - Live"), candidate(artist: "Cover"), candidate(manual: true)] {
            XCTAssertFalse(assessment(value).isReliableMatch)
            XCTAssertTrue(assessment(value).canPreview)
        }
        XCTAssertTrue(assessment(candidate(duration: 29758)).isReliableMatch)
        let snapshot = playback()
        XCTAssertTrue(PreviewRecordingMatcher.assessment(candidate(), track: snapshot.trackName, artist: "", playback: snapshot).isReliableMatch)
        XCTAssertFalse(PreviewRecordingMatcher.assessment(candidate(), track: snapshot.trackName, artist: "Cover", playback: snapshot).isReliableMatch)
    }

    func testTitleOnlyFallbackLoadsVerifiedAliasDespiteAnotherSourceFailure() async throws {
        let fields: [String: Any] = ["id": 1, "trackName": playback().trackName, "artistName": candidate().artistName,
                                     "albumName": playback().albumName, "duration": 30, "instrumental": false,
                                     "syncedLyrics": "[00:05]Synthetic first\n[00:09]Synthetic next"]
        let body = try JSONSerialization.data(withJSONObject: [fields])
        let (http, host) = StubURLProtocol.session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            return .init(data: query.contains { $0.name == "artist_name" } ? Data("[]".utf8) : body)
        }
        defer { http.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: http), requestDelay: 0)
        let failed = FakeProvider("Unavailable") { _ in .init(lyrics: [], colorData: nil) }
        failed.searchAction = { _, _ in throw URLError(.badServerResponse) }
        let session = LyricPreviewSession(providers: [failed, provider])
        session.updatePlayback(playback(), autoSearch: false)
        await session.search()?.value
        XCTAssertEqual(provider.requestCount, 2)
        XCTAssertEqual(session.sourceErrors.count, 1)
        XCTAssertEqual(session.selected?.artistName, candidate().artistName)
        XCTAssertEqual(session.activeIndex, 0)
        let presentation = PreviewLyricPresentation(session: session)
        XCTAssertEqual(presentation.currentLine, "Synthetic first")
        XCTAssertEqual(presentation.nextLine, "Synthetic next")
    }

    func testAliasSelectionAndOffsetCanBeRevalidatedWithoutChangingSourceSettings() async throws {
        let suite = "local.lyricmate.alpha.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("source-sentinel", forKey: LyricSourceStore.storageKey)
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        let value = candidate()
        XCTAssertTrue(preferences.remember(value, playback: playback(), offsetMS: 250))
        let fresh = candidate()
        let restored = PreviewRecordingPreferences(defaults: defaults).restoration(in: [fresh], playback: playback())
        XCTAssertEqual(restored?.id, fresh.id)
        XCTAssertEqual(restored?.offsetMS, 250)
        XCTAssertEqual(defaults.string(forKey: LyricSourceStore.storageKey), "source-sentinel")
    }

    func testUnverifiedSingerDisplaysLyricsWithProvisionalWarning() async {
        let value = candidate(artist: "Cover")
        let provider = FakeProvider("Fixture") { _ in .init(lyrics: [], colorData: nil) }
        provider.searchAction = { _, _ in [value] }
        let session = LyricPreviewSession(providers: [provider])
        session.updatePlayback(playback(), autoSearch: false)
        await session.search()?.value
        XCTAssertEqual(session.selectedID, value.id)
        XCTAssertEqual(PreviewLyricPresentation(session: session).currentLine, "Synthetic first")
        XCTAssertTrue(session.status.contains(L10n.text("Provisional match; the version may differ. Not saved automatically.")))
    }

}
