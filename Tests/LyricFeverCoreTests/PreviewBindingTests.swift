import XCTest
@testable import LyricFeverCore

@MainActor
private final class VersionFixtureProvider: LyricVersionProvider {
    let providerName = "Version fixture"
    let versionSourceIdentity: String
    var retrieveCalls = 0
    var searchCalls = 0
    var retrieve: (PreviewRecordingPreferences.VersionReference) async throws -> SongResult? = { _ in nil }
    var searchResults: [SongResult] = []
    var onSearch: (() -> Void)?
    init(source: String) { versionSourceIdentity = source }
    func retrieveVersion(_ version: PreviewRecordingPreferences.VersionReference) async throws -> SongResult? {
        retrieveCalls += 1
        return try await retrieve(version)
    }
    func search(trackName: String, artistName: String) async throws -> [SongResult] {
        searchCalls += 1; onSearch?()
        return searchResults
    }
    func fetchNetworkLyrics(trackName: String, trackID: String, currentlyPlayingArtist: String?, currentAlbumName: String?) async throws -> NetworkFetchReturn {
        .init(lyrics: [], colorData: nil)
    }
}

@MainActor
final class PreviewBindingTests: XCTestCase {
    private let source = "lrclib|https://fixture.invalid/"
    private func playback(id: String = "spotify:track:A", title: String = "Song", artist: String = "Artist") -> PlaybackSnapshot {
        .init(trackID: id, trackName: title, artistName: artist, albumName: "Album", durationMS: 30000, positionMS: 1500, isPlaying: false)
    }
    private func candidate(source: String? = nil, id: String = "42", album: String = "Album", text: String = "SyntheticAlpha") -> SongResult {
        .init(lyricType: "Fixture", songName: "Song", albumName: album, artistName: "Artist",
              lyrics: [.init(startTime: 1000, words: text), .init(startTime: 2500, words: "SyntheticBeta")],
              durationMS: 30000, sourceIdentity: source ?? self.source, sourceSongID: id)
    }
    private func defaults() -> UserDefaults {
        let suite = "dev.lyricmate.binding.tests." + UUID().uuidString
        let value = UserDefaults(suiteName: suite)!
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }
    private func start(_ session: LyricPreviewSession, playback snapshot: PlaybackSnapshot? = nil) async {
        session.updatePlayback(snapshot ?? playback(), autoSearch: false)
        await session.search()?.value
    }

    func testRestartRetrievesBoundNonHighestVersionEvenWhenAbsentFromSearch() async throws {
        let d = defaults(), prefs = PreviewRecordingPreferences(defaults: d)
        let chosen = candidate(id: "7", album: "Other"), highest = candidate()
        XCTAssertTrue(prefs.remember(chosen, playback: playback(), offsetMS: 450))
        let bytes = d.data(forKey: PreviewRecordingPreferences.storageKey)
        let provider = VersionFixtureProvider(source: source)
        provider.retrieve = { version in XCTAssertEqual(version.songID, "7"); return chosen }
        provider.searchResults = [highest]
        let session = LyricPreviewSession(providers: [provider], preferences: PreviewRecordingPreferences(defaults: d))
        provider.onSearch = {
            XCTAssertEqual(session.selectedID, chosen.id, "The binding must load before ordinary search")
            XCTAssertEqual(session.offsetMS, 450)
        }
        await start(session)
        XCTAssertEqual(provider.retrieveCalls, 1)
        XCTAssertEqual(session.selectedID, chosen.id)
        XCTAssertEqual(session.rankedResults.first?.id, highest.id, "Ranking stays independent of the saved selection")
        XCTAssertTrue(session.isSavedChoice(chosen))
        XCTAssertEqual(d.data(forKey: PreviewRecordingPreferences.storageKey), bytes)
    }

    func testSearchDuplicateOfRetrievedVersionDoesNotInvalidateBinding() async {
        let prefs = PreviewRecordingPreferences(defaults: defaults()), chosen = candidate()
        XCTAssertTrue(prefs.remember(chosen, playback: playback(), offsetMS: 500))
        let provider = VersionFixtureProvider(source: source)
        provider.retrieve = { _ in chosen }; provider.searchResults = [candidate()]
        let session = LyricPreviewSession(providers: [provider], preferences: prefs)
        await start(session)
        XCTAssertEqual(session.results.count, 1)
        XCTAssertEqual(session.selectedID, chosen.id); XCTAssertEqual(session.offsetMS, 500)
    }

    func testChangedVersionFallsBackWithoutOverwritingBindingOrOffset() async {
        let d = defaults(), prefs = PreviewRecordingPreferences(defaults: d)
        XCTAssertTrue(prefs.remember(candidate(id: "7"), playback: playback(), offsetMS: 700))
        let bytes = d.data(forKey: PreviewRecordingPreferences.storageKey)
        let provider = VersionFixtureProvider(source: source), highest = candidate()
        provider.retrieve = { [self] _ in candidate(id: "7", text: "Changed") }
        provider.searchResults = [highest]
        let session = LyricPreviewSession(providers: [provider], preferences: prefs)
        provider.onSearch = { XCTAssertFalse(session.memoryMessage.isEmpty) }
        await start(session)
        XCTAssertEqual(session.selectedID, highest.id); XCTAssertEqual(session.offsetMS, 0)
        XCTAssertFalse(session.memoryMessage.isEmpty); XCTAssertFalse(session.isSavedChoice(highest))
        XCTAssertEqual(d.data(forKey: PreviewRecordingPreferences.storageKey), bytes)
    }

    func testDisabledOrDifferentSourceIsNeverUsedToRetrieveBinding() async {
        let d = defaults(), prefs = PreviewRecordingPreferences(defaults: d)
        XCTAssertTrue(prefs.remember(candidate(), playback: playback(), offsetMS: 700))
        let bytes = d.data(forKey: PreviewRecordingPreferences.storageKey)
        let other = VersionFixtureProvider(source: "lrclib|https://other.invalid/")
        other.searchResults = [candidate(source: other.versionSourceIdentity)]
        let session = LyricPreviewSession(providers: [other], preferences: prefs)
        await start(session)
        XCTAssertEqual(other.retrieveCalls, 0); XCTAssertEqual(session.offsetMS, 0)
        XCTAssertFalse(session.memoryMessage.isEmpty)
        XCTAssertEqual(d.data(forKey: PreviewRecordingPreferences.storageKey), bytes)
    }

    func testSavedPlatformBindingsCannotBypassSourceAlphaRegistryPolicy() async throws {
        for platform in PlatformLyricSource.allCases {
            let d = defaults(), store = LyricSourceStore(defaults: d)
            _ = try store.importManifest(JSONEncoder().encode(platform.manifest))
            let sourceID = platform.manifest.apiFormat.rawValue + "|" + (try platform.manifest.validatedURL()).absoluteString
            let prefs = PreviewRecordingPreferences(defaults: d)
            XCTAssertTrue(prefs.remember(candidate(source: sourceID), playback: playback(), offsetMS: 500))
            let sourceBytes = d.data(forKey: LyricSourceStore.storageKey)
            let bindingBytes = d.data(forKey: PreviewRecordingPreferences.storageKey)
            var constructions = 0
            let registry = LyricSourceRegistry(store: store) {
                constructions += 1
                return try CustomHTTPSourceProvider(manifest: $0)
            }
            let session = LyricPreviewSession(providers: [], providerSnapshot: { registry.enabledProviders }, preferences: prefs)
            await start(session)
            XCTAssertEqual(constructions, 0)
            XCTAssertTrue(session.results.isEmpty); XCTAssertEqual(session.offsetMS, 0)
            XCTAssertEqual(d.data(forKey: LyricSourceStore.storageKey), sourceBytes)
            XCTAssertEqual(d.data(forKey: PreviewRecordingPreferences.storageKey), bindingBytes)
        }
    }

    func testDisabledCustomSourceBindingCannotReenableItsProvider() async throws {
        let d = defaults(), store = LyricSourceStore(defaults: d)
        let saved = try store.importManifest(JSONEncoder().encode(manifest(baseURL: "https://fixture.invalid/", format: .lrclib)))
        try store.setEnabled(saved.id, false)
        let prefs = PreviewRecordingPreferences(defaults: d)
        XCTAssertTrue(prefs.remember(candidate(), playback: playback(), offsetMS: 500))
        var constructions = 0
        let registry = LyricSourceRegistry(store: store) {
            constructions += 1
            return try CustomHTTPSourceProvider(manifest: $0)
        }
        let session = LyricPreviewSession(providers: [], providerSnapshot: { registry.enabledProviders }, preferences: prefs)
        await start(session)
        XCTAssertEqual(constructions, 0); XCTAssertTrue(session.results.isEmpty)
        XCTAssertEqual(session.offsetMS, 0); XCTAssertEqual(prefs.entries.count, 1)
        XCTAssertEqual(store.sources.first?.isEnabled, false)
    }

    func testSameTitleDifferentTrackCoverLiveAndForeignNamespaceCannotRestore() async {
        let prefs = PreviewRecordingPreferences(defaults: defaults())
        XCTAssertTrue(prefs.remember(candidate(), playback: playback(), offsetMS: 400))
        let provider = VersionFixtureProvider(source: source)
        provider.searchResults = [candidate()]
        for snapshot in [playback(id: "spotify:track:B"), playback(artist: "Cover"), playback(title: "Song Live"), playback(id: "other:track:A")] {
            let session = LyricPreviewSession(providers: [provider], preferences: prefs)
            await start(session, playback: snapshot)
            XCTAssertEqual(provider.retrieveCalls, 0)
            XCTAssertEqual(session.offsetMS, 0)
            XCTAssertFalse(session.isSavedChoice(provider.searchResults[0]))
        }
        XCTAssertFalse(prefs.remember(candidate(), playback: playback(id: "other:track:A"), offsetMS: 0))
    }

    func testChangingBindingAndUnbindingImmediatelyAffectsRestart() async {
        let d = defaults(), prefs = PreviewRecordingPreferences(defaults: d)
        let provider = VersionFixtureProvider(source: source)
        let best = candidate(), alternate = candidate(id: "7", album: "Other")
        provider.searchResults = [best, alternate]
        let session = LyricPreviewSession(providers: [provider], preferences: prefs)
        await start(session)
        session.select(alternate.id); session.offsetMS = 300
        XCTAssertTrue(session.canUseAutomaticSelection)
        XCTAssertTrue(session.isSavedChoice(alternate))
        session.select(best.id)
        XCTAssertEqual(prefs.entry(for: playback())?.version?.songID, "42")
        XCTAssertFalse(session.isSavedChoice(alternate)); XCTAssertEqual(session.offsetMS, 0)
        session.select(alternate.id)
        session.forgetCurrentChoice()
        XCTAssertEqual(session.selectedID, best.id); XCTAssertFalse(session.canUseAutomaticSelection)
        let restarted = LyricPreviewSession(providers: [provider], preferences: PreviewRecordingPreferences(defaults: d))
        await start(restarted)
        XCTAssertEqual(restarted.selectedID, best.id); XCTAssertEqual(provider.retrieveCalls, 0)
    }

    func testUnbindDuringRetrievalDoesNotResurrectSavedChoice() async {
        let prefs = PreviewRecordingPreferences(defaults: defaults())
        let chosen = candidate(id: "7", album: "Other"), best = candidate()
        XCTAssertTrue(prefs.remember(chosen, playback: playback(), offsetMS: 700))
        let provider = VersionFixtureProvider(source: source)
        let session = LyricPreviewSession(providers: [provider], preferences: prefs)
        provider.retrieve = { _ in session.forgetCurrentChoice(); return chosen }
        provider.searchResults = [best]
        await start(session)
        XCTAssertTrue(prefs.entries.isEmpty); XCTAssertEqual(session.selectedID, best.id)
        XCTAssertEqual(session.offsetMS, 0)
    }

    func testTrackChangeWhileRetrievingRejectsStaleResult() async {
        let prefs = PreviewRecordingPreferences(defaults: defaults())
        let chosen = candidate()
        XCTAssertTrue(prefs.remember(chosen, playback: playback(), offsetMS: 500))
        let provider = VersionFixtureProvider(source: source)
        let session = LyricPreviewSession(providers: [provider], preferences: prefs)
        provider.retrieve = { [self] _ in
            session.updatePlayback(playback(id: "spotify:track:B"), autoSearch: false)
            return chosen
        }
        await start(session)
        XCTAssertTrue(session.results.isEmpty); XCTAssertNil(session.selectedID)
        XCTAssertEqual(session.playback?.trackID, "spotify:track:B"); XCTAssertFalse(session.isSearching)
        XCTAssertEqual(provider.searchCalls, 0); XCTAssertEqual(prefs.entries.count, 1)
    }

    func testRateLimitAndAuthenticationFailureDoNotRetryBoundProvider() async {
        for error in [LyricSourceError.rateLimited, .httpStatus(401), .httpStatus(403)] {
            let prefs = PreviewRecordingPreferences(defaults: defaults())
            XCTAssertTrue(prefs.remember(candidate(), playback: playback(), offsetMS: 500))
            let provider = VersionFixtureProvider(source: source)
            provider.retrieve = { _ in throw error }
            let other = VersionFixtureProvider(source: "customHTTPV1|https://other.invalid/")
            other.searchResults = [candidate(source: other.versionSourceIdentity)]
            let session = LyricPreviewSession(providers: [provider, other], preferences: prefs)
            await start(session)
            XCTAssertEqual(provider.retrieveCalls, 1); XCTAssertEqual(provider.searchCalls, 0)
            XCTAssertEqual(other.searchCalls, 1); XCTAssertNotNil(session.selectedID)
            XCTAssertFalse(session.sourceErrors.isEmpty); XCTAssertEqual(prefs.entries.count, 1)
        }
    }

    func testLegacyHashOnlyChoiceAndBackupRemainCompatible() async throws {
        let d = defaults(), prefs = PreviewRecordingPreferences(defaults: d), chosen = candidate()
        let legacy = PreviewRecordingPreferences.Entry(recording: .init(playback()),
            candidateSHA256: try XCTUnwrap(PreviewRecordingPreferences.fingerprint(chosen)), offsetMS: 350)
        try prefs.replaceValidated([legacy])
        let bytes = try XCTUnwrap(d.data(forKey: PreviewRecordingPreferences.storageKey))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("version"))
        let reloaded = PreviewRecordingPreferences(defaults: d)
        let provider = VersionFixtureProvider(source: source); provider.searchResults = [chosen]
        let session = LyricPreviewSession(providers: [provider], preferences: reloaded)
        await start(session)
        XCTAssertEqual(session.selectedID, chosen.id); XCTAssertEqual(session.offsetMS, 350)
        XCTAssertEqual(provider.retrieveCalls, 0)
        let backup = try PreviewBackup.export(sources: LyricSourceStore(defaults: d), preferences: prefs)
        XCTAssertNil(try PreviewBackup.decode(backup).preferences.first?.version)
        XCTAssertEqual(d.data(forKey: PreviewRecordingPreferences.storageKey), bytes)
    }

    func testVersionReferenceAndBackupHaveNoBodyURLOrArbitraryFields() throws {
        let d = defaults(), prefs = PreviewRecordingPreferences(defaults: d)
        XCTAssertTrue(prefs.remember(candidate(), playback: playback(), offsetMS: 0))
        let backup = try PreviewBackup.export(sources: LyricSourceStore(defaults: d), preferences: prefs)
        let string = String(decoding: backup, as: UTF8.self)
        XCTAssertFalse(string.contains("SyntheticAlpha")); XCTAssertFalse(string.contains("fixture.invalid"))
        XCTAssertEqual(try PreviewBackup.decode(backup).preferences.first?.version?.songID, "42")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
        var payload = try XCTUnwrap(root["payload"] as? [String: Any])
        var entries = try XCTUnwrap(payload["preferences"] as? [[String: Any]])
        var version = try XCTUnwrap(entries[0]["version"] as? [String: Any])
        version["token"] = "must-not-import"; entries[0]["version"] = version
        payload["preferences"] = entries; root["payload"] = payload
        XCTAssertThrowsError(try PreviewBackup.decode(JSONSerialization.data(withJSONObject: root)))
    }

    func testLRCLIBRetrievesExactIDWithFreshMetadataAndOneRequest() async throws {
        let body = Data(#"{"id":42,"trackName":"Song","artistName":"Artist","albumName":"Album","duration":30,"instrumental":false,"syncedLyrics":"[00:01]SyntheticAlpha\n[00:02.50]SyntheticBeta"}"#.utf8)
        let (http, host) = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/get/42")
            return .init(data: body)
        }
        defer { http.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib),
                                                   client: LyricHTTPClient(session: http), requestDelay: 0)
        let original = candidate(source: provider.versionSourceIdentity)
        let restored = try await provider.retrieveVersion(XCTUnwrap(.init(original)))
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(restored.flatMap(PreviewRecordingPreferences.fingerprint), PreviewRecordingPreferences.fingerprint(original))
    }

    func testLRCLIBRejectsWrongIDAndChangedMetadata() async throws {
        for fields in [(43, "Song"), (42, "Song Live")] {
            let body = try JSONSerialization.data(withJSONObject: ["id": fields.0, "trackName": fields.1, "artistName": "Artist",
                "albumName": "Album", "duration": 30, "instrumental": false, "syncedLyrics": "[00:01]SyntheticAlpha"])
            let (http, host) = StubURLProtocol.session { _ in .init(data: body) }
            defer { http.invalidateAndCancel() }
            let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib),
                                                       client: LyricHTTPClient(session: http), requestDelay: 0)
            do {
                let restored = try await provider.retrieveVersion(XCTUnwrap(.init(candidate(source: provider.versionSourceIdentity))))
                XCTAssertNil(restored)
            } catch { XCTAssertEqual(error as? LyricSourceError, .invalidResponse) }
        }
    }

    func testCustomHTTPRetrievesVersionByIDWithoutSearchingOrPersistingText() async throws {
        let body = Data(#"{"apiVersion":1,"id":"42","instrumental":false,"syncedLyrics":"[00:01]SyntheticAlpha\n[00:02.50]SyntheticBeta"}"#.utf8)
        let (http, host) = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/v1/lyrics")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "id", value: "42")])
            return .init(data: body)
        }
        defer { http.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"),
                                                   client: LyricHTTPClient(session: http), requestDelay: 0)
        let original = candidate(source: provider.versionSourceIdentity)
        let restored = try await provider.retrieveVersion(XCTUnwrap(.init(original)))
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(restored.flatMap(PreviewRecordingPreferences.fingerprint), PreviewRecordingPreferences.fingerprint(original))
    }

    func testPlatformRestorationRediscoversMetadataBeforeRequestingLyrics() async throws {
        let http = StubURLProtocol.session(hosts: ["music.163.com"]) { request in
            if request.url?.path == "/api/search/get" {
                return .init(data: Data(#"{"code":200,"result":{"songs":[{"id":42,"name":"Song","artists":[{"name":"Artist"}],"album":{"name":"Album"},"duration":30000}]}}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/api/song/lyric")
            return .init(data: Data(#"{"code":200,"lrc":{"lyric":"[00:01]SyntheticAlpha\n[00:02.50]SyntheticBeta"}}"#.utf8))
        }
        defer { http.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: PlatformLyricSource.netease.manifest,
                                                   client: LyricHTTPClient(session: http), requestDelay: 0)
        let original = candidate(source: provider.versionSourceIdentity)
        let restored = try await provider.retrieveVersion(XCTUnwrap(.init(original)))
        XCTAssertEqual(provider.requestCount, 2)
        XCTAssertEqual(restored.flatMap(PreviewRecordingPreferences.fingerprint), PreviewRecordingPreferences.fingerprint(original))
    }

    func testRecoveredBindingStillFollowsPlaybackTimelineWithSavedOffset() async {
        let prefs = PreviewRecordingPreferences(defaults: defaults()), chosen = candidate()
        XCTAssertTrue(prefs.remember(chosen, playback: playback(), offsetMS: 700))
        let provider = VersionFixtureProvider(source: source)
        provider.retrieve = { _ in chosen }
        let session = LyricPreviewSession(providers: [provider], preferences: prefs)
        await start(session)
        XCTAssertNil(session.activeIndex, "At 1500 minus 700 ms, the first line has not started")
        let advanced = PlaybackSnapshot(trackID: playback().trackID, trackName: "Song", artistName: "Artist", albumName: "Album",
                                        durationMS: 30000, positionMS: 3500, isPlaying: true)
        session.updatePlayback(advanced, autoSearch: false)
        XCTAssertEqual(session.selectedID, chosen.id); XCTAssertEqual(session.activeIndex, 1)
        XCTAssertEqual(session.offsetMS, 700)
    }

    func testMalformedVersionReferenceIsNotLoadedOrRewritten() throws {
        let d = defaults(), prefs = PreviewRecordingPreferences(defaults: d)
        XCTAssertTrue(prefs.remember(candidate(), playback: playback(), offsetMS: 0))
        let original = try XCTUnwrap(d.data(forKey: PreviewRecordingPreferences.storageKey))
        for invalid in [String(repeating: "z", count: 64), "", String(repeating: "0", count: 65)] {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
            var version = try XCTUnwrap(entries[0]["version"] as? [String: Any])
            version["sourceSHA256"] = invalid; entries[0]["version"] = version; root["entries"] = entries
            let data = try JSONSerialization.data(withJSONObject: root)
            d.set(data, forKey: PreviewRecordingPreferences.storageKey)
            let reloaded = PreviewRecordingPreferences(defaults: d)
            XCTAssertNotNil(reloaded.loadError); XCTAssertTrue(reloaded.entries.isEmpty)
            XCTAssertEqual(d.data(forKey: PreviewRecordingPreferences.storageKey), data)
        }
    }

    func testCanceledRetrievalDoesNotRestartSearchOrEraseBinding() async {
        let prefs = PreviewRecordingPreferences(defaults: defaults())
        XCTAssertTrue(prefs.remember(candidate(), playback: playback(), offsetMS: 500))
        let provider = VersionFixtureProvider(source: source)
        provider.retrieve = { _ in throw CancellationError() }
        let session = LyricPreviewSession(providers: [provider], preferences: prefs)
        await start(session)
        XCTAssertEqual(provider.searchCalls, 0); XCTAssertTrue(session.results.isEmpty)
        XCTAssertTrue(session.sourceErrors.isEmpty); XCTAssertEqual(prefs.entries.count, 1)
        XCTAssertFalse(session.isSearching)
    }

    func testAmbiguousProviderSnapshotNeverRetrievesBindingByGuessing() async {
        let prefs = PreviewRecordingPreferences(defaults: defaults())
        XCTAssertTrue(prefs.remember(candidate(), playback: playback(), offsetMS: 500))
        let one = VersionFixtureProvider(source: source), two = VersionFixtureProvider(source: source)
        one.searchResults = [candidate()]; two.searchResults = [candidate()]
        let session = LyricPreviewSession(providers: [one, two], preferences: prefs)
        await start(session)
        XCTAssertEqual(one.retrieveCalls, 0); XCTAssertEqual(two.retrieveCalls, 0)
        XCTAssertEqual(session.results.count, 1)
        XCTAssertEqual(session.offsetMS, 500, "A search candidate can still be independently revalidated")
    }

    func testEachTrackAndLyricPairRetainsItsOffsetAcrossSwitchesAndRestart() async {
        let d = defaults(), prefs = PreviewRecordingPreferences(defaults: d)
        let first = candidate(), second = candidate(id: "7", album: "Other")
        let provider = VersionFixtureProvider(source: source)
        provider.searchResults = [first, second]
        let session = LyricPreviewSession(providers: [provider], preferences: prefs)
        await start(session)
        session.select(first.id); session.offsetMS = 450
        session.select(second.id)
        XCTAssertEqual(session.offsetMS, 0)
        session.offsetMS = -300
        session.select(first.id)
        XCTAssertEqual(session.offsetMS, 450)
        session.select(second.id)
        XCTAssertEqual(session.offsetMS, -300)
        let restarted = LyricPreviewSession(providers: [provider], preferences: PreviewRecordingPreferences(defaults: d))
        await start(restarted)
        XCTAssertEqual(restarted.selectedID, second.id); XCTAssertEqual(restarted.offsetMS, -300)
        restarted.select(first.id)
        XCTAssertEqual(restarted.offsetMS, 450)
    }

    func testPairOffsetRequiresExactTrackSourceBodyAndTimeline() {
        let prefs = PreviewRecordingPreferences(defaults: defaults())
        let original = candidate(), otherSource = candidate(source: "lrclib|https://other.invalid/")
        let otherTrack = playback(id: "spotify:track:B")
        XCTAssertTrue(prefs.remember(original, playback: playback(), offsetMS: 450))
        XCTAssertTrue(prefs.remember(original, playback: otherTrack, offsetMS: -300))
        XCTAssertTrue(prefs.remember(otherSource, playback: playback(), offsetMS: 700))
        XCTAssertEqual(prefs.offset(for: candidate(), playback: playback()), 450, "A fresh runtime UUID must not change the pair")
        XCTAssertEqual(prefs.offset(for: original, playback: otherTrack), -300)
        XCTAssertEqual(prefs.offset(for: otherSource, playback: playback()), 700)
        XCTAssertNil(prefs.offset(for: otherSource, playback: otherTrack))
        XCTAssertNil(prefs.offset(for: original, playback: playback(id: "spotify:track:C")))
        XCTAssertNil(prefs.offset(for: candidate(text: "Changed"), playback: playback()))
        let retimed = SongResult(lyricType: original.lyricType, songName: original.songName, albumName: original.albumName,
            artistName: original.artistName, lyrics: [.init(startTime: 1100, words: "SyntheticAlpha"), .init(startTime: 2500, words: "SyntheticBeta")],
            durationMS: original.durationMS, sourceIdentity: original.sourceIdentity, sourceSongID: original.sourceSongID)
        XCTAssertNil(prefs.offset(for: retimed, playback: playback()))
        XCTAssertNil(prefs.offset(for: original, playback: playback(artist: "Cover")))
    }

    func testForgetClearsAllVersionOffsetsForOnlyTheCurrentTrack() {
        let prefs = PreviewRecordingPreferences(defaults: defaults())
        let first = candidate(), second = candidate(id: "7", album: "Other"), other = playback(id: "spotify:track:B")
        XCTAssertTrue(prefs.remember(first, playback: playback(), offsetMS: 450))
        XCTAssertTrue(prefs.remember(second, playback: playback(), offsetMS: -300))
        XCTAssertTrue(prefs.remember(first, playback: other, offsetMS: 700))
        XCTAssertTrue(prefs.forget(playback().trackID))
        XCTAssertNil(prefs.offset(for: first, playback: playback()))
        XCTAssertNil(prefs.offset(for: second, playback: playback()))
        XCTAssertFalse(prefs.offsets.contains { $0.recording.id == playback().trackID })
        XCTAssertEqual(prefs.offset(for: first, playback: other), 700)
    }

    func testInactiveVersionOffsetsSurviveBackupRestoreAndUndo() throws {
        let from = defaults(), fromPrefs = PreviewRecordingPreferences(defaults: from)
        let first = candidate(), second = candidate(id: "7", album: "Other")
        XCTAssertTrue(fromPrefs.remember(first, playback: playback(), offsetMS: 450))
        XCTAssertTrue(fromPrefs.remember(second, playback: playback(), offsetMS: -300))
        let backup = try PreviewBackup.export(sources: LyricSourceStore(defaults: from), preferences: fromPrefs)
        XCTAssertEqual(try PreviewBackup.decode(backup).offsets?.count, 2)
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("SyntheticAlpha"))
        let d = defaults(), prefs = PreviewRecordingPreferences(defaults: d), sources = LyricSourceStore(defaults: d)
        let other = playback(id: "spotify:track:B")
        XCTAssertTrue(prefs.remember(first, playback: other, offsetMS: 700))
        let previous = try PreviewBackup.export(sources: sources, preferences: prefs)
        try PreviewBackup.restore(PreviewBackup.prepare(backup, sources: sources, preferences: prefs), sources: sources, preferences: prefs, defaults: d)
        XCTAssertEqual(prefs.offset(for: first, playback: playback()), 450)
        XCTAssertEqual(prefs.offset(for: second, playback: playback()), -300)
        XCTAssertNil(prefs.offset(for: first, playback: other))
        let restarted = PreviewRecordingPreferences(defaults: d)
        XCTAssertEqual(restarted.offset(for: first, playback: playback()), 450)
        try PreviewBackup.restore(PreviewBackup.prepare(previous, sources: sources, preferences: prefs), sources: sources, preferences: prefs, defaults: d)
        XCTAssertNil(prefs.offset(for: first, playback: playback()))
        XCTAssertEqual(prefs.offset(for: first, playback: other), 700)
    }

    func testInactiveOffsetChangeInvalidatesBackupRestorePlan() throws {
        let d = defaults(), prefs = PreviewRecordingPreferences(defaults: d), sources = LyricSourceStore(defaults: d)
        let first = candidate(), second = candidate(id: "7", album: "Other")
        XCTAssertTrue(prefs.remember(first, playback: playback(), offsetMS: 450))
        XCTAssertTrue(prefs.remember(second, playback: playback(), offsetMS: -300))
        let backup = try PreviewBackup.export(sources: sources, preferences: prefs)
        let plan = try PreviewBackup.prepare(backup, sources: sources, preferences: prefs)
        let active = prefs.entries
        XCTAssertTrue(prefs.remember(first, playback: playback(), offsetMS: 600))
        XCTAssertTrue(prefs.remember(second, playback: playback(), offsetMS: -300))
        XCTAssertEqual(prefs.entries, active)
        XCTAssertThrowsError(try PreviewBackup.restore(plan, sources: sources, preferences: prefs, defaults: d))
        XCTAssertNil(d.data(forKey: PreviewBackup.undoKey))
        XCTAssertEqual(prefs.offset(for: first, playback: playback()), 600)
    }

    func testOldBackupWithoutOffsetHistoryStillPreservesItsPairAfterSwitching() throws {
        let first = candidate(), second = candidate(id: "7", album: "Other")
        let entry = PreviewRecordingPreferences.Entry(recording: .init(playback()),
            candidateSHA256: try XCTUnwrap(PreviewRecordingPreferences.fingerprint(first)), offsetMS: 450)
        let payload = PreviewBackup.Payload(application: "local.lyricmate.alpha", sources: [], preferences: [entry])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let oldBackup = try encoder.encode(PreviewBackup.Document(schemaVersion: 1, payload: payload,
            sha256: PreviewLocalLyrics.digest(encoder.encode(payload))))
        XCTAssertNil(try PreviewBackup.decode(oldBackup).offsets)
        let d = defaults(), prefs = PreviewRecordingPreferences(defaults: d), sources = LyricSourceStore(defaults: d)
        try PreviewBackup.restore(PreviewBackup.prepare(oldBackup, sources: sources, preferences: prefs), sources: sources, preferences: prefs, defaults: d)
        XCTAssertEqual(prefs.offset(for: first, playback: playback()), 450)
        XCTAssertTrue(prefs.remember(second, playback: playback(), offsetMS: -300))
        let restarted = PreviewRecordingPreferences(defaults: d)
        XCTAssertEqual(restarted.offset(for: first, playback: playback()), 450)
        XCTAssertEqual(restarted.offset(for: second, playback: playback()), -300)
    }

    func testInvalidDuplicateOversizeOrInconsistentPairOffsetsDoNotWrite() throws {
        let d = defaults(), prefs = PreviewRecordingPreferences(defaults: d)
        XCTAssertTrue(prefs.remember(candidate(), playback: playback(), offsetMS: 450))
        let entry = try XCTUnwrap(prefs.entries.first), valid = PreviewRecordingPreferences.PairOffset(entry)
        let conflicting = PreviewRecordingPreferences.PairOffset(.init(recording: entry.recording, candidateSHA256: entry.candidateSHA256, offsetMS: 600))
        let invalid = PreviewRecordingPreferences.PairOffset(.init(recording: entry.recording, candidateSHA256: entry.candidateSHA256, offsetMS: 10001))
        let bytes = d.data(forKey: PreviewRecordingPreferences.storageKey)
        for offsets in [[valid, valid], [invalid], [conflicting], Array(repeating: valid, count: 201)] {
            XCTAssertThrowsError(try prefs.replaceValidated(prefs.entries, offsets: offsets))
            XCTAssertEqual(d.data(forKey: PreviewRecordingPreferences.storageKey), bytes)
        }
    }

    func testPairOffsetHistoryIsBoundedWithoutCrossPairFallback() {
        let prefs = PreviewRecordingPreferences(defaults: defaults())
        for index in 0...200 {
            XCTAssertTrue(prefs.remember(candidate(id: String(index)), playback: playback(), offsetMS: Double(index)))
        }
        XCTAssertEqual(prefs.entries.count, 1)
        XCTAssertEqual(prefs.offsets.count, PreviewRecordingPreferences.maximumOffsets)
        XCTAssertNil(prefs.offset(for: candidate(id: "0"), playback: playback()))
        XCTAssertEqual(prefs.offset(for: candidate(id: "1"), playback: playback()), 1)
        XCTAssertEqual(prefs.offset(for: candidate(id: "200"), playback: playback()), 200)
    }

    func testAutomaticFallbackUsesOnlyItsOwnKnownPairOffset() async {
        let prefs = PreviewRecordingPreferences(defaults: defaults())
        let first = candidate(), missing = candidate(id: "7", album: "Other")
        XCTAssertTrue(prefs.remember(first, playback: playback(), offsetMS: 450))
        XCTAssertTrue(prefs.remember(missing, playback: playback(), offsetMS: -300))
        let provider = VersionFixtureProvider(source: source); provider.searchResults = [first]
        let session = LyricPreviewSession(providers: [provider], preferences: prefs)
        await start(session)
        XCTAssertEqual(session.selectedID, first.id); XCTAssertEqual(session.offsetMS, 450)
        XCTAssertEqual(prefs.entry(for: playback())?.offsetMS, -300)
        XCTAssertFalse(session.isSavedChoice(first))
        session.forgetCurrentChoice()
        XCTAssertEqual(session.selectedID, first.id); XCTAssertEqual(session.offsetMS, 0)
    }

    func testOffsetHistoryWithoutPreferredBindingCanStillBeClearedInTheSession() async throws {
        let prefs = PreviewRecordingPreferences(defaults: defaults()), value = candidate()
        let remembered = PreviewRecordingPreferences.PairOffset(.init(recording: .init(playback()),
            candidateSHA256: try XCTUnwrap(PreviewRecordingPreferences.fingerprint(value)), offsetMS: 450))
        try prefs.replaceValidated([], offsets: [remembered])
        let provider = VersionFixtureProvider(source: source); provider.searchResults = [value]
        let session = LyricPreviewSession(providers: [provider], preferences: prefs)
        await start(session)
        XCTAssertEqual(session.offsetMS, 450); XCTAssertTrue(session.canUseAutomaticSelection)
        XCTAssertTrue(prefs.entries.isEmpty)
        session.forgetCurrentChoice()
        XCTAssertEqual(session.offsetMS, 0); XCTAssertFalse(session.canUseAutomaticSelection)
        XCTAssertTrue(prefs.offsets.isEmpty)
    }
}
