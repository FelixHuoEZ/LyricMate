import XCTest
@testable import LyricFeverCore

@MainActor
final class PreviewFilesTests: XCTestCase {
    private let spotifyID = "0123456789ABCDEFGHIJKL"
    private let lrc = Data("[ti:Song]\n[ar:Artist]\n[00:01]SyntheticPrivateLocal\n[00:04]SyntheticBeta".utf8)
    private func playback(id: String = "A", title: String = "Song", duration: Int = 30000) -> PlaybackSnapshot {
        .init(trackID: "spotify:track:" + id, trackName: title, artistName: "Artist", albumName: "Album", durationMS: duration, positionMS: 1500, isPlaying: false)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func defaults() -> UserDefaults {
        let name = "local.lyricmate.alpha.files.tests." + UUID().uuidString
        let value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }
    private func stores() -> (UserDefaults, LyricSourceStore, PreviewRecordingPreferences) {
        let d = defaults(); return (d, LyricSourceStore(defaults: d), PreviewRecordingPreferences(defaults: d))
    }
    private func index(id: String? = nil, filename: String = "1730652389036-69615623-Ab123xyz.ttml") -> Data {
        Data(#"{"id":"\#(id ?? spotifyID)","metadata":[["musicName",["Song"]],["artists",["Artist"]],["album",["Album"]],["spotifyId",["\#(id ?? spotifyID)"]]],"rawLyricFile":"\#(filename)"}"#.utf8)
    }
    private func ttml(id: String? = nil, line: String = "SyntheticWord", begin: String = "00:01.500", end: String = "00:04.000") -> Data {
        Data(#"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:amll="http://www.example.com/ns/amll" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><head><metadata><amll:meta key="spotifyId" value="\#(id ?? spotifyID)"/></metadata></head><body><div><p begin="\#(begin)" end="\#(end)">\#(line)</p></div></body></tt>"#.utf8)
    }
    func testLocalImportRestartAndNoCrossRecordingReuse() throws {
        let url = try directory(), local = PreviewLocalLyrics(directory: url)
        let plan = try local.prepare(lrc, playback: playback())
        let candidate = try local.install(plan, current: playback())
        XCTAssertEqual(candidate.sourceSongID, PreviewLocalLyrics.digest(lrc))
        XCTAssertEqual(candidate.durationMS, 30000)
        XCTAssertEqual(try PreviewLocalLyrics(directory: url).candidate(for: playback())?.lyrics.count, 2)
        XCTAssertNil(try local.candidate(for: playback(id: "B")))
        XCTAssertNil(try local.candidate(for: playback(duration: 30001)))
    }
    func testLocalImportRejectsPlainTextInvalidUTF8AndOversize() throws {
        let local = PreviewLocalLyrics(directory: try directory())
        for data in [Data("plain unsynchronized text".utf8), Data([0xff, 0xfe]), Data(repeating: 65, count: 1024 * 1024 + 1)] {
            XCTAssertThrowsError(try local.prepare(data, playback: playback()))
        }
    }
    func testLocalImportRejectsHeadersAndTimeBeyondDuration() throws {
        let local = PreviewLocalLyrics(directory: try directory())
        for value in ["[ti:Other]\n[00:01]Synthetic", "[ar:Cover]\n[00:01]Synthetic", "[01:00]Synthetic"] {
            XCTAssertThrowsError(try local.prepare(Data(value.utf8), playback: playback()))
        }
    }
    func testLocalStaleConfirmationAndModifiedBodyDoNotWrite() throws {
        let url = try directory(), local = PreviewLocalLyrics(directory: url), plan = try local.prepare(lrc, playback: playback())
        XCTAssertThrowsError(try local.install(plan, current: playback(id: "B")))
        let altered = PreviewLocalLyrics.Import(schemaVersion: 1, recording: plan.recording, fileSHA256: plan.fileSHA256, lrc: Data("[00:01]Changed".utf8))
        XCTAssertThrowsError(try local.install(altered, current: playback()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
    }
    func testLocalStorageRejectsSymlinkDirectoryAndEntry() throws {
        let root = try directory(), target = root.appendingPathComponent("target"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let local = PreviewLocalLyrics(directory: link)
        XCTAssertThrowsError(try local.install(local.prepare(lrc, playback: playback()), current: playback()))
        let regular = PreviewLocalLyrics(directory: target)
        let file = target.appendingPathComponent(PreviewLocalLyrics.digest(Data(playback().trackID.utf8)) + ".json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("missing"))
        // Broken links must not be followed or silently replaced either.
        XCTAssertThrowsError(try regular.install(regular.prepare(lrc, playback: playback()), current: playback()))
    }
    func testLocalModifiedStoredDigestRejectedAndOldFilePreserved() throws {
        let url = try directory(), local = PreviewLocalLyrics(directory: url)
        _ = try local.install(local.prepare(lrc, playback: playback()), current: playback())
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).first)
        let plan = try local.prepare(lrc, playback: playback())
        let bad = PreviewLocalLyrics.Import(schemaVersion: 1, recording: plan.recording, fileSHA256: String(repeating: "0", count: 64), lrc: lrc)
        let data = try JSONEncoder().encode(bad); try data.write(to: file)
        XCTAssertThrowsError(try local.candidate(for: playback()))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testLocalLibraryCountLimitAllowsReplacementNotNewRecording() throws {
        let root = try directory(), local = PreviewLocalLyrics(directory: root)
        _ = try local.install(local.prepare(lrc, playback: playback()), current: playback())
        for i in 0..<199 { try Data("Synthetic".utf8).write(to: root.appendingPathComponent("fixture-\(i).json")) }
        _ = try local.install(local.prepare(lrc, playback: playback()), current: playback())
        XCTAssertThrowsError(try local.install(local.prepare(lrc, playback: playback(id: "B")), current: playback(id: "B")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 200)
    }
    func testLocalLibraryTotalSizeBoundPreservesOldCandidate() throws {
        let root = try directory(), local = PreviewLocalLyrics(directory: root)
        _ = try local.install(local.prepare(lrc, playback: playback()), current: playback())
        try Data(repeating: 0, count: 32 * 1024 * 1024).write(to: root.appendingPathComponent("size-fixture.bin"))
        XCTAssertThrowsError(try local.install(local.prepare(lrc, playback: playback(id: "B")), current: playback(id: "B")))
        XCTAssertEqual(try local.candidate(for: playback())?.lyrics.count, 2)
    }
    func testRememberedLocalRestoresOffsetWithoutAnyProviderCall() throws {
        let (_, _, prefs) = stores(), local = PreviewLocalLyrics(directory: try directory())
        let value = try local.install(local.prepare(lrc, playback: playback()), current: playback())
        XCTAssertTrue(prefs.remember(value, playback: playback(), offsetMS: 500))
        let provider = FakeProvider("Never network") { _ in XCTFail("No network allowed"); return .init(lyrics: [], colorData: nil) }
        provider.searchAction = { _, _ in XCTFail("No search allowed"); return [] }
        let session = LyricPreviewSession(providers: [provider], preferences: prefs, localLyrics: local)
        session.updatePlayback(playback())
        XCTAssertEqual(session.selected?.sourceIdentity, "local-lrc:v1"); XCTAssertEqual(session.offsetMS, 500)
        XCTAssertFalse(session.isSearching)
    }
    func testBackupRoundTripHasMetadataNotLyricsOrCredentials() throws {
        let (_, sources, prefs) = stores(), local = PreviewLocalLyrics(directory: try directory())
        _ = try sources.importManifest(JSONEncoder().encode(manifest()))
        let candidate = try local.install(local.prepare(lrc, playback: playback()), current: playback())
        XCTAssertTrue(prefs.remember(candidate, playback: playback(), offsetMS: 450))
        let data = try PreviewBackup.export(sources: sources, preferences: prefs)
        let string = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(string.contains("SyntheticPrivateLocal")); XCTAssertFalse(string.contains("token")); XCTAssertFalse(string.contains("lrc"))
        let payload = try PreviewBackup.decode(data)
        XCTAssertEqual(payload.sources.count, 1); XCTAssertEqual(payload.preferences.count, 1)
        XCTAssertEqual(payload.preferences[0].offsetMS, 450)
    }
    func testBackupRestoreDisablesSourcesAndUndoSnapshotIsReal() throws {
        let (_, fromSources, fromPrefs) = stores()
        _ = try fromSources.importManifest(JSONEncoder().encode(manifest()))
        let input = try PreviewBackup.export(sources: fromSources, preferences: fromPrefs)
        let (d, sources, prefs) = stores()
        let previous = try PreviewBackup.export(sources: sources, preferences: prefs)
        let plan = try PreviewBackup.prepare(input, sources: sources, preferences: prefs)
        XCTAssertTrue(sources.sources.isEmpty)
        try PreviewBackup.restore(plan, sources: sources, preferences: prefs, defaults: d)
        XCTAssertEqual(sources.sources.count, 1); XCTAssertFalse(sources.sources[0].isEnabled)
        XCTAssertEqual(d.data(forKey: PreviewBackup.undoKey), previous)
        let undo = try PreviewBackup.prepare(previous, sources: sources, preferences: prefs)
        try PreviewBackup.restore(undo, sources: sources, preferences: prefs, defaults: d)
        XCTAssertTrue(sources.sources.isEmpty)
    }
    func testBackupChangedStateRejectsStalePlanWithoutUndoWrite() throws {
        let (d, sources, prefs) = stores()
        let data = try PreviewBackup.export(sources: sources, preferences: prefs)
        let plan = try PreviewBackup.prepare(data, sources: sources, preferences: prefs)
        _ = try sources.importManifest(JSONEncoder().encode(manifest()))
        XCTAssertThrowsError(try PreviewBackup.restore(plan, sources: sources, preferences: prefs, defaults: d))
        XCTAssertNil(d.data(forKey: PreviewBackup.undoKey)); XCTAssertEqual(sources.sources.count, 1)
    }
    private func changed(_ data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); edit(&root)
        return try JSONSerialization.data(withJSONObject: root)
    }
    func testBackupRejectsWrongVersionChecksumForeignAppUnknownKeysAndOversize() throws {
        let (_, sources, prefs) = stores(), data = try PreviewBackup.export(sources: sources, preferences: prefs)
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["schemaVersion"] = 9 }, { $0["sha256"] = "tampered" }, { $0["token"] = "secret" },
            { var p = $0["payload"] as! [String: Any]; p["application"] = "formal"; $0["payload"] = p }
        ]
        for edit in changes { XCTAssertThrowsError(try PreviewBackup.decode(changed(data, edit))) }
        XCTAssertThrowsError(try PreviewBackup.decode(Data(repeating: 65, count: PreviewBackup.maximumBytes + 1)))
    }
    func testBackupUnknownNestedCredentialFieldRejectedEvenWithUnchangedChecksum() throws {
        let (_, sources, prefs) = stores(); _ = try sources.importManifest(JSONEncoder().encode(manifest()))
        let data = try PreviewBackup.export(sources: sources, preferences: prefs)
        let altered = try changed(data) { root in
            var p = root["payload"] as! [String: Any], s = p["sources"] as! [[String: Any]]
            var m = s[0]["manifest"] as! [String: Any]; m["auth"] = ["type": "none", "token": "private-secret"]
            s[0]["manifest"] = m; p["sources"] = s; root["payload"] = p
        }
        XCTAssertThrowsError(try PreviewBackup.decode(altered))
    }
    func testReplacementRejectsDuplicateServicesIDsAndRecordingOffsets() throws {
        let (_, sources, prefs) = stores(), source = try sources.importManifest(JSONEncoder().encode(manifest()))
        XCTAssertThrowsError(try sources.replaceValidated([source, source]))
        XCTAssertThrowsError(try sources.replaceValidated([source, .init(id: UUID(), manifest: source.manifest, isEnabled: false)]))
        let bad = PreviewRecordingPreferences.Entry(recording: .init(playback()), candidateSHA256: String(repeating: "0", count: 64), offsetMS: 10001)
        XCTAssertThrowsError(try prefs.replaceValidated([bad])); XCTAssertTrue(prefs.entries.isEmpty)
    }
    func testBackupValidChecksumStillRejectsDuplicateAndOutOfRangePayload() throws {
        let source = LyricSourceConfiguration(id: UUID(), manifest: manifest(), isEnabled: true)
        let entry = PreviewRecordingPreferences.Entry(recording: .init(playback()), candidateSHA256: String(repeating: "0", count: 64), offsetMS: 0)
        let invalid = PreviewRecordingPreferences.Entry(recording: entry.recording, candidateSHA256: entry.candidateSHA256, offsetMS: 10001)
        let payloads = [
            PreviewBackup.Payload(application: "local.lyricmate.alpha", sources: [source, source], preferences: []),
            PreviewBackup.Payload(application: "local.lyricmate.alpha", sources: [], preferences: [entry, entry]),
            PreviewBackup.Payload(application: "local.lyricmate.alpha", sources: [], preferences: [invalid])
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        for payload in payloads {
            let doc = PreviewBackup.Document(schemaVersion: 1, payload: payload, sha256: PreviewLocalLyrics.digest(try encoder.encode(payload)))
            XCTAssertThrowsError(try PreviewBackup.decode(encoder.encode(doc)))
        }
    }
    func testRegistryRefreshesProviderWhenRestoredUUIDHasNewManifest() throws {
        let (_, store, _) = stores(), source = try store.importManifest(JSONEncoder().encode(manifest()))
        let registry = LyricSourceRegistry(store: store)
        let old = try XCTUnwrap(registry.enabledProviders.first as? CustomHTTPSourceProvider)
        try store.replaceValidated([.init(id: source.id, manifest: manifest(baseURL: "https://different.example.com/"), isEnabled: true)])
        let new = try XCTUnwrap(registry.enabledProviders.first as? CustomHTTPSourceProvider)
        XCTAssertFalse(old === new); XCTAssertNotEqual(old.manifest.baseURL, new.manifest.baseURL)
    }
    func testTTMLRetainsLineTimingExcludesTranslationsRomanizationAndBackground() throws {
        let line = #"<span begin="00:01.500" end="00:02.000">SyntheticMain</span><span ttm:role="x-translation">PRIVATE_TRANSLATION</span><span ttm:role="x-roman">PRIVATE_ROMAN</span><span ttm:role="x-bg">PRIVATE_BG</span> Tail"#
        let parsed = try PreviewTTMLParser.parse(ttml(line: line), spotifyID: spotifyID)
        XCTAssertEqual(parsed.count, 1); XCTAssertEqual(parsed[0].startTimeMS, 1500)
        XCTAssertEqual(parsed[0].words, "SyntheticMain Tail")
    }
    func testTTMLRejectsWrongIDNamespaceEntityMalformedTimeAndXML() {
        let valid = ttml()
        for data in [ttml(id: "Other"), ttml(begin: "nonsense"), ttml(begin: "00:05", end: "00:04"),
                     Data("<!DOCTYPE tt [<!ENTITY x SYSTEM 'file:///private'>]>".utf8) + valid,
                     Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "http://www.w3.org/ns/ttml", with: "https://wrong").utf8), Data("<broken".utf8)] {
            XCTAssertThrowsError(try PreviewTTMLParser.parse(data, spotifyID: spotifyID))
        }
    }
    func testTTMLSizeDepthAndMetaCountAreBounded() {
        for data in [Data(repeating: 65, count: 1024 * 1024 + 1),
                     ttml(line: String(repeating: "<span>", count: 70) + "Synthetic" + String(repeating: "</span>", count: 70)),
                     ttml(line: String(repeating: "<amll:meta key='x' value='y'/>", count: 300))] {
            XCTAssertThrowsError(try PreviewTTMLParser.parse(data, spotifyID: spotifyID))
        }
    }
    func testIndexValidFilenameAndLatestDuplicateWinsButPathsNeverImported() throws {
        let entries = try AMLLSource.decodeIndex(index() + Data("\n".utf8) + index(filename: "1730652389036-99999999-Ab123xyz.ttml"))
        XCTAssertEqual(entries.count, 1); XCTAssertTrue(entries[0].rawLyricFile.contains("99999999"))
        for name in ["../private.ttml", "https://evil/lyrics.ttml", "old.lrc"] { XCTAssertTrue(try AMLLSource.decodeIndex(index(filename: name)).isEmpty) }
        XCTAssertTrue(try AMLLSource.decodeIndex(index(id: "not-valid")).isEmpty)
        XCTAssertThrowsError(try AMLLSource.decodeIndex(Data("invalid JSON".utf8)))
    }
    func testAMLLManifestOnlyOfficialPublicBaseAllowed() throws {
        _ = try manifest(baseURL: AMLLSource.baseURL, format: .amllTTML).validatedURL()
        for url in ["https://raw.githubusercontent.com/other/repo/main/", AMLLSource.baseURL + "?token=secret", "http://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/"] {
            XCTAssertThrowsError(try manifest(baseURL: url, format: .amllTTML).validatedURL())
        }
    }
    func testAMLLRealFlowUsesBoundedRequestsAndAllowsOnlyProvisionalUnverifiedDisplay() async throws {
        let i = index(), t = ttml()
        let (http, _) = StubURLProtocol.session(host: "raw.githubusercontent.com") { req in
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"))
            return .init(headers: ["Content-Type": "text/plain"], data: req.url!.path.hasSuffix("index.jsonl") ? i : t)
        }
        defer { http.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: AMLLSource.baseURL, format: .amllTTML), client: LyricHTTPClient(session: http))
        let values = try await provider.search(trackName: "Song", artistName: "Artist")
        XCTAssertEqual(provider.requestCount, 2); XCTAssertEqual(values.count, 1); XCTAssertNil(values[0].durationMS)
        XCTAssertTrue(values[0].requiresManualSelection)
        XCTAssertEqual(PreviewRecordingMatcher.preferred(in: values, playback: playback(), track: "Song", artist: "Artist"), values[0].id)
        XCTAssertFalse(PreviewRecordingMatcher.assessment(values[0], track: "Song", artist: "Artist", playback: playback()).isReliableMatch)
        XCTAssertFalse(PreviewRecordingMatcher.eligibleForMemory(values[0], playback: playback()))
        _ = try await provider.search(trackName: "Song", artistName: "Artist"); XCTAssertEqual(provider.requestCount, 3)
        let formal = try await provider.fetchNetworkLyrics(request: request()); XCTAssertTrue(formal.lyrics.isEmpty)
        XCTAssertEqual(provider.requestCount, 3)
    }
    func testAMLLIndexFailureCachedAndNoFileRequestOrBroadenedSearch() async throws {
        let (http, _) = StubURLProtocol.session(host: "raw.githubusercontent.com") { _ in .init(status: 503) }
        defer { http.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: AMLLSource.baseURL, format: .amllTTML), client: LyricHTTPClient(session: http))
        for _ in 0..<2 {
            do { _ = try await provider.search(trackName: "Song", artistName: "Artist"); XCTFail("Must fail") } catch { XCTAssertEqual(error as? LyricSourceError, .httpStatus(503)) }
        }
        XCTAssertEqual(provider.requestCount, 1)
    }
    func testRawMimeAllowedOnlyWhenExplicitAndStillRejectsHTML() async throws {
        let (http, host) = StubURLProtocol.session { _ in .init(headers: ["Content-Type": "text/html"], data: Data("<html>login</html>".utf8)) }
        defer { http.invalidateAndCancel() }
        do { _ = try await LyricHTTPClient(session: http).get(URL(string: "https://\(host)/")!, mimeTypes: ["text/plain"]); XCTFail("HTML rejected") } catch { XCTAssertEqual(error as? LyricSourceError, .invalidResponse) }
    }
}
