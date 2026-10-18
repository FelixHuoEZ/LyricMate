import XCTest
@testable import LyricFeverCore

@MainActor
final class PreviewV4Tests: XCTestCase {
    private let currentID = "Z123456789ABCDEFGHIJKL"
    private let olderID = "0123456789ABCDEFGHIJKL"
    private func snapshot(_ id: String = "A", title: String = "Song", artist: String = "Artist", duration: Int = 30000) -> PlaybackSnapshot {
        .init(trackID: "spotify:track:" + id, trackName: title, artistName: artist, albumName: "Album", durationMS: duration, positionMS: 1500, isPlaying: false)
    }
    private func local() throws -> PreviewLocalLyrics {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-v4-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return PreviewLocalLyrics(directory: root.appendingPathComponent("lyrics"))
    }
    private func install(_ store: PreviewLocalLyrics, id: String = "A", body: String = "[00:01]Synthetic") throws {
        let p = snapshot(id)
        _ = try store.install(store.prepare(Data(body.utf8), playback: p), current: p)
    }
    private func index(_ id: String, title: String = "Song", artist: String = "Artist", number: String = "69615623") -> String {
        #"{"id":"\#(id)","metadata":[["musicName",["\#(title)"]],["artists",["\#(artist)"]],["spotifyId",["\#(id)"]]],"rawLyricFile":"1730652389036-\#(number)-Ab123xyz.ttml"}"#
    }
    private func provider(_ index: String) throws -> (CustomHTTPSourceProvider, URLSession) {
        let (http, _) = StubURLProtocol.session(host: "raw.githubusercontent.com") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let id = request.url!.path.contains("99999999") ? "Z123456789ABCDEFGHIJKL" : "0123456789ABCDEFGHIJKL"
            let ttml = #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:amll="http://www.example.com/ns/amll"><head><metadata><amll:meta key="spotifyId" value="\#(id)"/></metadata></head><body><div><p begin="1s" end="3s">Synthetic</p></div></body></tt>"#
            return .init(headers: ["Content-Type": "text/plain"], data: Data((request.url!.path.hasSuffix("index.jsonl") ? index : ttml).utf8))
        }
        return (try CustomHTTPSourceProvider(manifest: manifest(baseURL: AMLLSource.baseURL, format: .amllTTML), client: LyricHTTPClient(session: http), requestDelay: 0), http)
    }
    func testStrictSpotifyIDParsing() {
        XCTAssertEqual(AMLLSource.recordingID("spotify:track:" + currentID), currentID)
        for value in ["", "spotify:track:A", "spotify:track:" + currentID + "?x", "https://open.spotify.com/track/" + currentID, "spotify:track:" + String(repeating: "é", count: 22)] {
            XCTAssertNil(AMLLSource.recordingID(value))
        }
    }
    func testIDWinsOverSortedTitleDuplicateAndUnknownDurationOnlyAllowsProvisionalDisplay() async throws {
        let (p, http) = try provider(index(olderID) + "\n" + index(currentID, number: "99999999")); defer { http.invalidateAndCancel() }
        let values = try await p.search(trackName: "Song", artistName: "Artist", spotifyTrackID: "spotify:track:" + currentID)
        XCTAssertEqual(values.map(\.sourceSongID), [currentID]); XCTAssertEqual(p.requestCount, 2)
        XCTAssertTrue(values[0].requiresManualSelection); XCTAssertNil(values[0].durationMS)
        XCTAssertEqual(PreviewRecordingMatcher.preferred(in: values, playback: snapshot(currentID), track: "Song", artist: "Artist"), values[0].id)
        XCTAssertFalse(PreviewRecordingMatcher.assessment(values[0], track: "Song", artist: "Artist", playback: snapshot(currentID)).isReliableMatch)
        XCTAssertFalse(PreviewRecordingMatcher.eligibleForMemory(values[0], playback: snapshot(currentID)))
    }
    func testContradictoryExactIDDoesNotFetchDifferentVersion() async throws {
        for (title, artist) in [("Song Live", "Artist"), ("Song", "Other"), ("Song", "Artist feat Guest")] {
            let (p, http) = try provider(index(olderID) + "\n" + index(currentID, title: title, artist: artist, number: "99999999"))
            let values = try await p.search(trackName: "Song", artistName: "Artist", spotifyTrackID: "spotify:track:" + currentID)
            XCTAssertTrue(values.isEmpty); XCTAssertEqual(p.requestCount, 1); http.invalidateAndCancel()
        }
    }
    func testIDAbsentRetainsOneManualFallbackAndCachedIndex() async throws {
        let (p, http) = try provider(index(olderID)); defer { http.invalidateAndCancel() }
        let values = try await p.search(trackName: "Song", artistName: "Artist", spotifyTrackID: "spotify:track:" + currentID)
        XCTAssertEqual(values.first?.sourceSongID, olderID)
        _ = try await p.search(trackName: "Song", artistName: "Artist", spotifyTrackID: "spotify:track:" + currentID)
        XCTAssertEqual(p.requestCount, 3)
    }
    func testSessionOnlyUsesAvailableMatchingPlaybackContext() async throws {
        for mode in 0..<3 {
            let (p, http) = try provider(index(olderID) + "\n" + index(currentID, number: "99999999"))
            let s = LyricPreviewSession(providers: [p])
            s.updatePlayback(snapshot(currentID, title: mode == 2 ? "Other" : "Song"), autoSearch: false)
            if mode == 1 { s.updatePlayback(nil, autoSearch: false) }
            s.trackQuery = "Song"; s.artistQuery = "Artist"
            await s.search()?.value
            XCTAssertEqual(s.results.first?.sourceSongID, mode == 0 ? currentID : olderID)
            XCTAssertEqual(s.selectedID, mode == 0 ? s.results.first?.id : nil)
            http.invalidateAndCancel()
        }
    }
    func testCatalogArchiveRestoreSurvivesRestartAndPreservesBytes() throws {
        let store = try local(); try install(store)
        let initial = try store.catalog(); XCTAssertEqual(initial.activeCount, 1); XCTAssertEqual(initial.invalidCount, 0)
        let active = try XCTUnwrap(initial.entries.first)
        XCTAssertEqual(active.recording.id, snapshot().trackID)
        try store.archive(active)
        XCTAssertNil(try store.candidate(for: snapshot()))
        let restarted = PreviewLocalLyrics(directory: store.directory), recycled = try restarted.catalog()
        XCTAssertEqual(recycled.activeCount, 0); XCTAssertEqual(recycled.archivedCount, 1)
        let archived = try XCTUnwrap(recycled.entries.first)
        XCTAssertEqual(archived.storedSHA256, active.storedSHA256)
        try restarted.restore(archived)
        XCTAssertEqual(try restarted.catalog().archivedCount, 0)
        XCTAssertEqual(try restarted.candidate(for: snapshot())?.lyrics.first?.words, "Synthetic")
    }
    func testStaleDeleteSnapshotCannotDeleteReplacement() throws {
        let store = try local(); try install(store)
        let old = try XCTUnwrap(store.catalog().entries.first)
        try install(store, body: "[00:01]NewSynthetic")
        XCTAssertThrowsError(try store.archive(old))
        XCTAssertEqual(try store.candidate(for: snapshot())?.lyrics.first?.words, "NewSynthetic")
        XCTAssertEqual(try store.catalog().archivedCount, 0)
    }
    func testRestoreNeverOverwritesNewBinding() throws {
        let store = try local(); try install(store)
        try store.archive(XCTUnwrap(store.catalog().entries.first))
        let archived = try XCTUnwrap(store.catalog().entries.first)
        try install(store, body: "[00:01]Replacement")
        XCTAssertThrowsError(try store.restore(archived))
        XCTAssertEqual(try store.candidate(for: snapshot())?.lyrics.first?.words, "Replacement")
        XCTAssertEqual(try store.catalog().archivedCount, 1)
    }
    func testTamperedArchiveIsNotRestoredOrRemoved() throws {
        let store = try local(); try install(store); try store.archive(XCTUnwrap(store.catalog().entries.first))
        let e = try XCTUnwrap(store.catalog().entries.first), file = store.archiveDirectory.appendingPathComponent(e.filename)
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try store.restore(e)); XCTAssertEqual(try store.catalog().invalidCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testForgedEntryCannotEscapeLibrary() throws {
        let store = try local(); try install(store)
        let e = try XCTUnwrap(store.catalog().entries.first)
        let forged = PreviewLocalLyrics.Entry(filename: "../outside.json", recording: e.recording, storedSHA256: e.storedSHA256, bytes: e.bytes, archived: false)
        XCTAssertThrowsError(try store.archive(forged)); XCTAssertNotNil(try store.candidate(for: snapshot()))
    }
    func testSymlinkArchiveDirectoryOrEntryNeverFollowed() throws {
        let store = try local(); try install(store)
        let e = try XCTUnwrap(store.catalog().entries.first)
        try FileManager.default.createSymbolicLink(at: store.archiveDirectory, withDestinationURL: store.directory)
        XCTAssertThrowsError(try store.archive(e)); XCTAssertThrowsError(try store.catalog())
        try FileManager.default.removeItem(at: store.archiveDirectory)
        try store.archive(e)
        let archived = try XCTUnwrap(store.catalog().entries.first), path = store.archiveDirectory.appendingPathComponent(archived.filename)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: store.directory.appendingPathComponent("missing"))
        XCTAssertThrowsError(try store.restore(archived)); XCTAssertThrowsError(try store.catalog())
    }
    func testArchiveCapacityRejectsAndKeepsActiveFile() throws {
        let store = try local(); try install(store)
        try FileManager.default.createDirectory(at: store.archiveDirectory, withIntermediateDirectories: true)
        for i in 0..<200 { try Data("Synthetic".utf8).write(to: store.archiveDirectory.appendingPathComponent("bad-\(i).json")) }
        XCTAssertThrowsError(try store.archive(XCTUnwrap(store.catalog().entries.first)))
        XCTAssertNotNil(try store.candidate(for: snapshot()))
        XCTAssertEqual(try store.catalog().invalidCount, 200)
    }
    func testFullActiveLibraryCanArchiveThenRestoreButNotAdd201st() throws {
        let store = try local()
        for i in 0..<200 { try install(store, id: "R\(i)") }
        let catalog = try store.catalog(); XCTAssertEqual(catalog.activeCount, 200); XCTAssertEqual(catalog.entries.count, 200)
        XCTAssertThrowsError(try install(store, id: "Overflow"))
        try store.archive(XCTUnwrap(catalog.entries.first))
        let archived = try XCTUnwrap(store.catalog().entries.first(where: \.archived))
        try store.restore(archived); XCTAssertEqual(try store.catalog().activeCount, 200)
    }
    func testRestoreRejectsFullLibraryWithoutLosingRecovery() throws {
        let store = try local(); try install(store)
        try store.archive(XCTUnwrap(store.catalog().entries.first))
        let e = try XCTUnwrap(store.catalog().entries.first)
        for i in 0..<200 { try install(store, id: "R\(i)") }
        XCTAssertThrowsError(try store.restore(e)); XCTAssertEqual(try store.catalog().archivedCount, 1)
    }
    func testArchiveSizeLimitDoesNotMoveFile() throws {
        let store = try local(); try install(store)
        let e = try XCTUnwrap(store.catalog().entries.first)
        try FileManager.default.createDirectory(at: store.archiveDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 32 * 1024 * 1024).write(to: store.archiveDirectory.appendingPathComponent("synthetic.bin"))
        XCTAssertThrowsError(try store.archive(e)); XCTAssertNotNil(try store.candidate(for: snapshot()))
    }
    func testLibraryChangeClearsOnlyCurrentSessionAndNoNetwork() throws {
        let store = try local(); try install(store)
        let s = LyricPreviewSession(providers: [], localLyrics: store)
        s.updatePlayback(snapshot(), autoSearch: false)
        s.presentLocal(try XCTUnwrap(store.candidate(for: snapshot())))
        s.offsetMS = 500
        s.localLibraryChanged(recordingID: snapshot("B").trackID); XCTAssertNotNil(s.selected)
        s.localLibraryChanged(recordingID: snapshot().trackID)
        XCTAssertTrue(s.results.isEmpty); XCTAssertNil(s.selected); XCTAssertEqual(s.offsetMS, 0)
    }
    func testSameIDWithChangedMetadataInvalidatesOldSelection() throws {
        let store = try local(); try install(store)
        let s = LyricPreviewSession(providers: [], localLyrics: store)
        s.updatePlayback(snapshot(), autoSearch: false)
        s.presentLocal(try XCTUnwrap(store.candidate(for: snapshot())))
        s.updatePlayback(snapshot(title: "Song Live"), autoSearch: false)
        XCTAssertNil(s.selected); XCTAssertTrue(s.results.isEmpty); XCTAssertEqual(s.offsetMS, 0)
    }
    func testTwentyThousandLinesAndHundredThousandLookupsAreBounded() throws {
        let store = try local(), p = snapshot(duration: 1200000)
        let text = (0..<20000).map { String(format: "[%02d:%02d.%02d]Synthetic%05d", $0 / 6000, ($0 / 100) % 60, $0 % 100, $0) }.joined(separator: "\n")
        let start = Date()
        let candidate = try store.install(store.prepare(Data(text.utf8), playback: p), current: p)
        XCTAssertEqual(candidate.lyrics.count, 20000)
        for i in 0..<100000 { XCTAssertEqual(LyricTimeline.activeIndex(in: candidate.lyrics, positionMS: Double(i % 20000) * 10), i % 20000) }
        let elapsed = Date().timeIntervalSince(start)
        print("V4_STRESS long-lines=20000 lookups=100000 seconds=\(elapsed)")
        XCTAssertLessThan(elapsed, 15)
        XCTAssertEqual(try store.catalog().entries.count, 1)
    }
    func testTwoHundredRapidTrackChangesCannotPublishStaleSearchOrOffset() async throws {
        let p = FakeProvider("Synthetic") { _ in .init(lyrics: [], colorData: nil) }
        p.searchAction = { track, artist in
            try? await Task.sleep(nanoseconds: 500000)
            return [SongResult(lyricType: "Synthetic", songName: track, albumName: "Album", artistName: artist,
                               lyrics: [LyricLine(startTime: 1000, words: track)], durationMS: 30000)]
        }
        let s = LyricPreviewSession(providers: [p])
        var tasks: [Task<Void, Never>] = []
        let start = Date()
        for i in 0..<200 {
            s.updatePlayback(snapshot("R\(i)", title: "Song\(i)"), autoSearch: false)
            XCTAssertTrue(s.results.isEmpty); XCTAssertNil(s.selected); XCTAssertEqual(s.offsetMS, 0)
            if let task = s.search() { tasks.append(task) }
            await Task.yield()
        }
        for task in tasks { await task.value }
        XCTAssertEqual(s.selected?.songName, "Song199"); XCTAssertEqual(s.results.count, 1); XCTAssertEqual(s.offsetMS, 0)
        let elapsed = Date().timeIntervalSince(start)
        print("V4_STRESS rapid-track-changes=200 seconds=\(elapsed)"); XCTAssertLessThan(elapsed, 15)
    }
}
