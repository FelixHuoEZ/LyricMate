import LyricMateLocalization
import XCTest
@testable import LyricFeverCore

@MainActor
final class PreviewDailyTests: XCTestCase {
    private func playback(id: String = "A", title: String = "Song", artist: String = "Artist", album: String = "Album", duration: Int = 30000) -> PlaybackSnapshot {
        .init(trackID: "spotify:track:" + id, trackName: title, artistName: artist, albumName: album, durationMS: duration,
              positionMS: 1500, isPlaying: false)
    }
    private func candidate(title: String = "Song", artist: String = "Artist", album: String = "Album", duration: Int? = 30000,
                           source: String = "lrclib|https://fixture.invalid/", id: String = "1", text: String = "SyntheticPrivateLine") -> SongResult {
        .init(lyricType: "Fixture", songName: title, albumName: album, artistName: artist,
              lyrics: [.init(startTime: 1000, words: text), .init(startTime: 2500, words: "SyntheticBeta")],
              durationMS: duration, sourceIdentity: source, sourceSongID: id)
    }
    private func isolated() -> (UserDefaults, String) {
        let suite = "local.lyricmate.alpha.tests." + UUID().uuidString
        return (UserDefaults(suiteName: suite)!, suite)
    }
    private func model(_ values: [SongResult], preferences: PreviewRecordingPreferences? = nil) -> LyricPreviewSession {
        let provider = FakeProvider("Fixture") { _ in .init(lyrics: [], colorData: nil) }
        provider.searchAction = { _, _ in values }
        return LyricPreviewSession(providers: [provider], preferences: preferences)
    }
    func testChineseScriptsAndCompleteDuetListNormalizeWithoutVersionStripping() {
        XCTAssertEqual(PreviewRecordingMatcher.normalized("涼涼"), PreviewRecordingMatcher.normalized("凉凉"))
        XCTAssertEqual(PreviewRecordingMatcher.artistRelation("楊宗緯, 張碧晨", "张碧晨、杨宗纬"), .normalized)
        XCTAssertEqual(PreviewRecordingMatcher.artistRelation("A & B", "B / A"), .normalized)
        XCTAssertNil(PreviewRecordingMatcher.artistRelation("A & C", "A & B"))
        XCTAssertNil(PreviewRecordingMatcher.artistRelation("A", "A & B"))
        for title in ["Song Live", "Song Remix", "Song Acoustic", "Song Sped Up", "Song Radio Edit", "Song Taylor's Version"] {
            XCTAssertFalse(PreviewRecordingMatcher.matches(candidate(title: title), track: "Song", artist: "Artist"))
        }
    }
    func testSearchLabelsAreAuditableCandidatesNeverAutomaticSingerProof() {
        XCTAssertEqual(PreviewRecordingMatcher.artistRelation("Stefanie Sun", "孙燕姿"), .searchLabel)
        XCTAssertEqual(PreviewRecordingMatcher.artistRelation("Yanzi Sun", "孫燕姿"), .searchLabel)
        XCTAssertNil(PreviewRecordingMatcher.artistRelation("Unknown Cover", "孙燕姿"))
        let song = candidate(title: "遇见", artist: "Stefanie Sun")
        XCTAssertTrue(PreviewRecordingMatcher.matches(song, track: "遇见", artist: "孙燕姿"))
        let snapshot = playback(title: "遇见", artist: "孙燕姿")
        XCTAssertEqual(PreviewRecordingMatcher.preferred(in: [song], playback: snapshot, track: "遇见", artist: "孙燕姿"), song.id)
        XCTAssertFalse(PreviewRecordingMatcher.assessment(song, track: "遇见", artist: "孙燕姿", playback: snapshot).isReliableMatch)
    }
    func testNormalizationStillRequiresDurationAndStableDuplicateOrder() {
        let snapshot = playback(title: "涼涼", artist: "楊宗緯, 張碧晨")
        let good = candidate(title: "凉凉", artist: "杨宗纬、张碧晨")
        XCTAssertEqual(PreviewRecordingMatcher.preferred(in: [good], playback: snapshot, track: snapshot.trackName, artist: snapshot.artistName), good.id)
        XCTAssertEqual(PreviewRecordingMatcher.preferred(in: [good, candidate(title: "凉凉", artist: "杨宗纬、张碧晨")], playback: snapshot, track: snapshot.trackName, artist: snapshot.artistName), good.id)
        XCTAssertFalse(PreviewRecordingMatcher.eligibleForMemory(candidate(duration: 32001), playback: playback()))
        XCTAssertFalse(PreviewRecordingMatcher.eligibleForMemory(candidate(duration: nil), playback: playback()))
        XCTAssertTrue(PreviewRecordingMatcher.eligibleForMemory(candidate(duration: 32000), playback: playback()))
    }
    func testRecreatedCandidateUUIDDoesNotChangeFingerprintButBodyOrSourceDoes() {
        let a = candidate(), b = candidate()
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(PreviewRecordingPreferences.fingerprint(a), PreviewRecordingPreferences.fingerprint(b))
        for changed in [candidate(id: "2"), candidate(source: "lrclib|https://other.invalid/"), candidate(text: "Changed"), candidate(duration: 30001), candidate(album: "Other")] {
            XCTAssertNotEqual(PreviewRecordingPreferences.fingerprint(a), PreviewRecordingPreferences.fingerprint(changed))
        }
    }
    func testPreferencesRestartRestoresRevalidatedCandidateAndContainsNoLyrics() throws {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        XCTAssertTrue(preferences.remember(candidate(), playback: playback(), offsetMS: 450))
        let stored = try XCTUnwrap(defaults.data(forKey: PreviewRecordingPreferences.storageKey))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("SyntheticPrivateLine"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("https://fixture.invalid"))
        let reloaded = PreviewRecordingPreferences(defaults: defaults)
        let fresh = candidate()
        XCTAssertEqual(reloaded.restoration(in: [fresh], playback: playback())?.id, fresh.id)
        XCTAssertEqual(reloaded.restoration(in: [fresh], playback: playback())?.offsetMS, 450)
    }
    func testMemoryRefusesChangedRecordingSourceBodyDurationAndDuplicateCandidates() {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        XCTAssertTrue(preferences.remember(candidate(), playback: playback(), offsetMS: -500))
        for snapshot in [playback(id: "B"), playback(album: "Other"), playback(duration: 30001), playback(artist: "Cover"), playback(title: "Song Live")] {
            XCTAssertNil(preferences.restoration(in: [candidate()], playback: snapshot))
        }
        for value in [candidate(text: "Changed"), candidate(source: "other|https://fixture.invalid/"), candidate(id: "2"), candidate(duration: 35000)] {
            XCTAssertNil(preferences.restoration(in: [value], playback: playback()))
        }
        XCTAssertNil(preferences.restoration(in: [candidate(), candidate()], playback: playback()))
        XCTAssertNil(preferences.restoration(in: [], playback: playback()))
    }
    func testMemoryBoundsNoAuthenticationAndForeignStorageWrites() {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unrelated-sentinel", forKey: LyricSourceStore.storageKey)
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        for offset in [Double.nan, .infinity, -10001, 10001] {
            XCTAssertFalse(preferences.remember(candidate(), playback: playback(), offsetMS: offset))
        }
        var unknown = candidate(); unknown.sourceIdentity = nil
        XCTAssertFalse(preferences.remember(unknown, playback: playback(), offsetMS: 0))
        XCTAssertTrue(preferences.remember(candidate(), playback: playback(), offsetMS: 10000))
        preferences.forget(playback().trackID)
        XCTAssertEqual(preferences.entries.count, 0)
        XCTAssertEqual(defaults.string(forKey: LyricSourceStore.storageKey), "unrelated-sentinel")
    }
    func testCorruptAndOversizeMemoryIsNotAppliedOrErased() {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        for data in [Data(#"{"schemaVersion":9,"entries":[]}"#.utf8), Data(repeating: 65, count: 256 * 1024 + 1)] {
            defaults.set(data, forKey: PreviewRecordingPreferences.storageKey)
            let preferences = PreviewRecordingPreferences(defaults: defaults)
            XCTAssertNotNil(preferences.loadError)
            XCTAssertTrue(preferences.entries.isEmpty)
            XCTAssertEqual(defaults.data(forKey: PreviewRecordingPreferences.storageKey), data)
        }
    }
    func testMemoryEvictionKeepsAtMostTwoHundredDistinctRecordings() {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        for i in 0...200 { XCTAssertTrue(preferences.remember(candidate(), playback: playback(id: "Track\(i)"), offsetMS: 0)) }
        XCTAssertEqual(preferences.entries.count, 200)
        XCTAssertNil(preferences.restoration(in: [candidate()], playback: playback(id: "Track0")))
        XCTAssertNotNil(preferences.restoration(in: [candidate()], playback: playback(id: "Track200")))
    }
    func testSessionExplicitSelectionOffsetCutAndRestartRestoreWithoutAutomaticWrites() async throws {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        let first = candidate(), alternate = candidate(album: "Manual choice", id: "2")
        let session = model([first, alternate], preferences: preferences)
        session.updatePlayback(playback(), autoSearch: false)
        await session.search()?.value
        XCTAssertTrue(preferences.entries.isEmpty)
        session.select(alternate.id); session.offsetMS = 550
        let data = defaults.data(forKey: PreviewRecordingPreferences.storageKey)
        session.updatePlayback(playback(id: "B"), autoSearch: false)
        XCTAssertEqual(session.offsetMS, 0)
        session.updatePlayback(playback(), autoSearch: false)
        await session.search()?.value
        XCTAssertEqual(session.selectedID, alternate.id); XCTAssertEqual(session.offsetMS, 550)
        let freshAlternate = candidate(album: "Manual choice", id: "2")
        let restarted = model([candidate(), freshAlternate], preferences: PreviewRecordingPreferences(defaults: defaults))
        restarted.updatePlayback(playback(), autoSearch: false); await restarted.search()?.value
        XCTAssertEqual(restarted.selectedID, freshAlternate.id); XCTAssertEqual(restarted.offsetMS, 550)
        XCTAssertEqual(defaults.data(forKey: PreviewRecordingPreferences.storageKey), data)
    }
    func testChangedCandidateDoesNotRestoreOrOverwriteOldOffset() async {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        XCTAssertTrue(preferences.remember(candidate(), playback: playback(), offsetMS: 500))
        let data = defaults.data(forKey: PreviewRecordingPreferences.storageKey)
        let session = model([candidate(text: "Updated lyric")], preferences: preferences)
        session.updatePlayback(playback(), autoSearch: false); await session.search()?.value
        XCTAssertEqual(session.offsetMS, 0)
        XCTAssertTrue(session.memoryMessage.contains(L10n.text("Saved version unavailable or not revalidated. Using automatic selection for now, without the old offset; your binding is preserved.")))
        XCTAssertEqual(defaults.data(forKey: PreviewRecordingPreferences.storageKey), data)
    }
    func testUnavailablePlaybackAndManualOtherQueryCannotWriteMemory() async {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        let value = candidate()
        let session = model([value], preferences: preferences)
        session.updatePlayback(playback(), autoSearch: false); await session.search()?.value
        session.updatePlayback(nil); session.select(value.id); session.offsetMS = 500
        XCTAssertTrue(preferences.entries.isEmpty)
        session.updatePlayback(playback(), autoSearch: false); session.artistQuery = "Other"; session.select(value.id)
        XCTAssertTrue(preferences.entries.isEmpty)
    }
    func testOffsetClampAndForgetAreExplicitAndSourceChangesClearSelection() async {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        let value = candidate(); let session = model([value], preferences: preferences)
        session.updatePlayback(playback(), autoSearch: false); await session.search()?.value; session.select(value.id)
        session.offsetMS = 20000; XCTAssertEqual(session.offsetMS, 10000)
        session.offsetMS = -.infinity; XCTAssertEqual(session.offsetMS, 0)
        session.offsetMS = -300; session.forgetCurrentChoice()
        XCTAssertTrue(preferences.entries.isEmpty); XCTAssertEqual(session.offsetMS, 0)
        session.sourcesChanged(); XCTAssertTrue(session.results.isEmpty); XCTAssertNil(session.activeIndex)
        XCTAssertTrue(session.memoryMessage.isEmpty)
    }
    func testForgetImmediatelyReturnsToHighestScoreInsteadOfKeepingManualChoice() async {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        let best = candidate(), alternate = candidate(album: "Other", id: "2")
        let session = model([best, alternate], preferences: preferences)
        session.updatePlayback(playback(), autoSearch: false)
        await session.search()?.value
        session.select(alternate.id)
        XCTAssertEqual(session.selectedID, alternate.id)
        session.forgetCurrentChoice()
        XCTAssertEqual(session.selectedID, best.id)
        XCTAssertTrue(preferences.entries.isEmpty)
    }
    func testTitleOnlyQueryCanRememberAnOtherwiseVerifiedManualChoice() async {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        let value = candidate()
        let session = model([value], preferences: preferences)
        session.updatePlayback(playback(), autoSearch: false)
        session.artistQuery = ""
        await session.search()?.value
        session.select(value.id)
        XCTAssertEqual(preferences.entries.count, 1)
    }
    func testRepeatedSearchMustRevalidateOldOffsetAndMessage() async throws {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        let original = candidate()
        var available = [original]
        let provider = FakeProvider("Mutable") { _ in .init(lyrics: [], colorData: nil) }
        provider.searchAction = { _, _ in available }
        let session = LyricPreviewSession(providers: [provider], preferences: preferences)
        session.updatePlayback(playback(), autoSearch: false)
        await session.search()?.value
        session.select(original.id); session.offsetMS = 500
        await session.search()?.value
        XCTAssertEqual(session.offsetMS, 500)
        XCTAssertTrue(session.memoryMessage.contains(L10n.text("Revalidated the source, lyric fingerprint and recording; restored the selection and offset.")))
        available = [candidate(text: "Changed body")]
        await session.search()?.value
        XCTAssertEqual(session.offsetMS, 0)
        XCTAssertTrue(session.memoryMessage.contains(L10n.text("Saved version unavailable or not revalidated. Using automatic selection for now, without the old offset; your binding is preserved.")))
        session.sourcesChanged()
        XCTAssertTrue(session.memoryMessage.isEmpty)
    }
    func testImportedDisabledSourceDoesNotEnterProviderSnapshot() throws {
        let (defaults, suite) = isolated(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = LyricSourceStore(defaults: defaults)
        let source = try store.importManifest(JSONEncoder().encode(manifest()), enabled: false)
        let registry = LyricSourceRegistry(store: store)
        XCTAssertTrue(registry.enabledProviders.isEmpty)
        try store.setEnabled(source.id, true); XCTAssertEqual(registry.enabledProviders.count, 1)
        try store.setEnabled(source.id, false); XCTAssertTrue(registry.enabledProviders.isEmpty)
        XCTAssertFalse(LyricSourceStore(defaults: defaults).sources[0].isEnabled)
        try store.remove(source.id); XCTAssertTrue(registry.enabledProviders.isEmpty)
    }
    func testManualOtherRecordingUsesCandidateDurationWithoutChangingPlayback() async {
        let other = candidate(title: "Other Song", duration: 60000)
        let session = model([other])
        let snapshot = playback()
        session.updatePlayback(snapshot, autoSearch: false)
        session.trackQuery = "Other Song"
        await session.search()?.value
        session.select(other.id)
        XCTAssertEqual(session.displayedDurationMS, 30000)
        session.followsPlayback = false
        XCTAssertEqual(session.displayedDurationMS, 60000)
        session.previewPositionMS = 55000
        XCTAssertEqual(session.displayedPositionMS, 55000)
        XCTAssertEqual(session.playback, snapshot)
        session.followsPlayback = true
        XCTAssertEqual(session.displayedDurationMS, 30000)
    }
    func testLRCLIBSupplementFiltersVersionsAndProvisionallySelectsHighestLabelScore() async throws {
        let body = Data(#"[{"id":1,"trackName":"遇见","artistName":"Other","albumName":"Album","duration":30,"instrumental":false,"syncedLyrics":"[00:01]Synthetic"},{"id":2,"trackName":"遇见","artistName":"Stefanie Sun","albumName":"Album","duration":30,"instrumental":false,"syncedLyrics":"[00:01]Synthetic"},{"id":3,"trackName":"遇见 Live","artistName":"孙燕姿","albumName":"Album","duration":30,"instrumental":false,"syncedLyrics":"[00:01]Synthetic"}]"#.utf8)
        let (urlSession, host) = StubURLProtocol.session { req in
            let artist = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "artist_name" })?.value
            return .init(data: (artist ?? "").isEmpty ? body : Data("[]".utf8))
        }
        defer { urlSession.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: urlSession))
        let session = LyricPreviewSession(providers: [provider])
        session.updatePlayback(playback(title: "遇见", artist: "孙燕姿"), autoSearch: false); await session.search()?.value
        XCTAssertEqual(provider.requestCount, 2); XCTAssertEqual(session.results.count, 2)
        XCTAssertTrue(session.results.contains { $0.sourceSongID == "2" })
        XCTAssertEqual(session.selected?.sourceSongID, "2")
        XCTAssertTrue(session.status.contains(L10n.text("Provisional match; the version may differ. Not saved automatically.")))
        XCTAssertTrue(session.matchingMessage.contains(L10n.text("%1$@ made one title-only fallback search. Candidates are previewed by score; other artists or covers may have different timing.", "")))
    }
    func testOnlyOneSupplementPerSourceAnd503IsNotBroadened() async throws {
        let (urlSession, host) = StubURLProtocol.session { _ in .init(data: Data("[]".utf8)) }
        defer { urlSession.invalidateAndCancel() }
        let one = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: urlSession))
        let two = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: urlSession))
        let session = LyricPreviewSession(providers: [one, two]); session.updatePlayback(playback(), autoSearch: false)
        await session.search()?.value; XCTAssertEqual(one.requestCount + two.requestCount, 4)
        let (failing, badHost) = StubURLProtocol.session { _ in .init(status: 503) }
        defer { failing.invalidateAndCancel() }
        let bad = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(badHost)/", format: .lrclib), client: LyricHTTPClient(session: failing))
        let failed = LyricPreviewSession(providers: [bad]); failed.updatePlayback(playback(), autoSearch: false)
        await failed.search()?.value; XCTAssertEqual(bad.requestCount, 1); XCTAssertEqual(failed.sourceErrors.count, 1)
        XCTAssertFalse(failed.status.contains(L10n.text("No timed lyrics found.")))
    }
    func testRateLimitStopsLaterSourcesAndDynamicProviderSnapshotIsFresh() async throws {
        let (urlSession, host) = StubURLProtocol.session { _ in .init(status: 429) }
        defer { urlSession.invalidateAndCancel() }
        let limited = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: urlSession))
        var laterCalls = 0
        let later = FakeProvider("Later") { _ in .init(lyrics: [], colorData: nil) }
        later.searchAction = { [self] _, _ in laterCalls += 1; return [candidate()] }
        var enabled = true
        let session = LyricPreviewSession(providers: [], providerSnapshot: { enabled ? [limited, later] : [later] })
        session.updatePlayback(playback(), autoSearch: false); await session.search()?.value
        XCTAssertEqual(limited.requestCount, 1); XCTAssertEqual(laterCalls, 0)
        enabled = false; session.sourcesChanged(); await session.search()?.value
        XCTAssertEqual(laterCalls, 1); XCTAssertNotNil(session.selected)
    }
}
