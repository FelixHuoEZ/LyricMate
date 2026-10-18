import XCTest
@testable import LyricFeverCore

private final class PlatformRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    func record(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        values.append(request.url!)
        return values.count
    }
    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

@MainActor
final class PlatformLyricSourceTests: XCTestCase {
    private let hosts = ["music.163.com", "songsearch.kugou.com", "lyrics.kugou.com", "search.kuwo.cn", "m.kuwo.cn", "c.y.qq.com", "app.c.nf.migu.cn", "d.musicapp.migu.cn"]
    private let lrc = "[00:01.00]Synthetic first\n[00:02.50]Synthetic next"

    private func searchJSON(_ source: PlatformLyricSource, title: String = "Test 1997", artist: String = "Singer", id: String? = nil) -> [String: Any] {
        switch source {
        case .migu: return ["code": "000000", "songResultData": ["totalCount": "1", "result": [["id": id ?? "123", "name": title,
            "singers": [["name": artist]], "albums": [["name": "Album"]], "lyricUrl": "https://d.musicapp.migu.cn/data/oss/resource/fixture/lrc"]]]]
        case .netease: return ["code": 200, "result": ["songs": [["id": id ?? "123", "name": title, "artists": [["name": artist]], "album": ["name": "Album"], "duration": 30000]]]]
        case .kugou: return ["error_code": 0, "data": ["lists": [["FileHash": id ?? String(repeating: "A", count: 32), "SongName": title, "Singers": [["name": artist]], "AlbumName": "Album", "Duration": 30]]]]
        case .kuwo: return ["TOTAL": "1", "abslist": [["MUSICRID": "MUSIC_" + (id ?? "123"), "SONGNAME": title, "ARTIST": artist, "ALBUM": "Album", "DURATION": "30"]]]
        case .qqMusic: return ["code": 0, "data": ["song": ["list": [["songmid": id ?? "Mid123", "songname": title, "singer": [["name": artist]], "albumname": "Album", "interval": 30]]]]]
        }
    }
    private func reply(_ object: [String: Any], mime: String = "application/json") throws -> StubURLProtocol.Reply {
        .init(headers: ["Content-Type": mime], data: try JSONSerialization.data(withJSONObject: object))
    }
    private func provider(_ source: PlatformLyricSource, handler: @escaping (URLRequest) throws -> StubURLProtocol.Reply) throws -> (CustomHTTPSourceProvider, URLSession) {
        let session = StubURLProtocol.session(hosts: hosts, handler: handler)
        return (try CustomHTTPSourceProvider(manifest: source.manifest, client: LyricHTTPClient(session: session), requestDelay: 0), session)
    }

    func testPinnedManifestsRejectOtherHostsPathsPortsAndCredentials() async throws {
        for source in PlatformLyricSource.allCases {
            XCTAssertEqual(try source.manifest.validatedURL().absoluteString, source.baseURL)
            var portURL = URLComponents(string: source.baseURL)!
            portURL.port = 443
            for url in ["https://evil.example/", source.baseURL + "other/", portURL.string!, "https://user@" + source.baseURL.dropFirst(8)] {
                XCTAssertThrowsError(try manifest(baseURL: url, format: source.format).validatedURL())
            }
        }
    }

    func testAllSearchSchemasPreserveTitleYearFullArtistDurationAndIdentity() async throws {
        for source in PlatformLyricSource.allCases {
            let (provider, http) = try provider(source) { [self] request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.scheme, "https")
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertTrue(query.contains { $0.value == "Test 1997 Singer、Other" })
                return try reply(searchJSON(source, artist: "Singer、Other"))
            }
            defer { http.invalidateAndCancel() }
            let songs = try await provider.searchCandidates(trackName: "Test 1997", artistName: "Singer、Other")
            XCTAssertEqual(songs.count, 1)
            XCTAssertEqual(songs.first?.durationMs, source == .migu ? nil : 30000)
            XCTAssertEqual(songs.first?.trackName, "Test 1997"); XCTAssertEqual(songs.first?.artistName, "Singer、Other")
        }
    }

    func testNeteaseLRCAndQQEntitiesAreParsedThroughRealProvider() async throws {
        for source in [PlatformLyricSource.netease, .qqMusic] {
            let (provider, http) = try provider(source) { [self] request in
                if request.url!.path.contains("search") { return try reply(searchJSON(source), mime: source == .qqMusic ? "application/x-javascript" : "application/json") }
                if source == .netease { return try reply(["code": 200, "lrc": ["lyric": lrc]], mime: "text/plain") }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://y.qq.com/portal/player.html")
                return try reply(["code": 0, "lyric": lrc.replacingOccurrences(of: "[", with: "&#91;")], mime: "text/html")
            }
            defer { http.invalidateAndCancel() }
            let values = try await provider.search(trackName: "Test 1997", artistName: "Singer")
            XCTAssertEqual(values.count, 1); XCTAssertEqual(values.first?.lyrics.map(\.startTimeMS), [1000, 2500])
            XCTAssertEqual(values.first?.sourceIdentity, source.rawValue + "|" + source.baseURL)
            XCTAssertNotNil(values.first?.sourceSongID)
        }
    }

    func testKuwoJSONWithHTMLMimeStillRequiresMatchingSongIDAndValidTimes() async throws {
        let (provider, http) = try provider(.kuwo) { [self] request in
            if request.url!.host == "search.kuwo.cn" { return try reply(searchJSON(.kuwo)) }
            return try reply(["status": 200, "data": ["songinfo": ["id": "123", "artist": "Singer"],
                "lrclist": [["time": "2.5", "lineLyric": "Synthetic next"], ["time": "1.0", "lineLyric": "Synthetic first"]]]], mime: "text/html")
        }
        defer { http.invalidateAndCancel() }
        let values = try await provider.search(trackName: "Test 1997", artistName: "Singer")
        XCTAssertEqual(values.first?.lyrics.map(\.startTimeMS), [1000, 2500])
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testKugouSelectsPlainLCROfSameVersionAndNeverPersistsDownloadKey() async throws {
        let (provider, http) = try provider(.kugou) { [self] request in
            let url = request.url!
            if url.host == "songsearch.kugou.com" { return try reply(searchJSON(.kugou)) }
            if url.path == "/search" {
                return try reply(["status": 200, "candidates": [
                    ["id": "1", "krctype": 1, "contenttype": 0, "song": "Test 1997", "singer": "Singer", "duration": 30000, "accesskey": "AAAA"],
                    ["id": "2", "krctype": 2, "contenttype": 0, "song": "Test 1997", "singer": "Other", "duration": 30000, "accesskey": "BBBB"],
                    ["id": "3", "krctype": 2, "contenttype": 0, "song": "Test 1997", "singer": "Singer", "duration": 30000, "accesskey": "CCCC"]]])
            }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains { $0.name == "id" && $0.value == "3" })
            return try reply(["status": 200, "fmt": "lrc", "content": Data(lrc.utf8).base64EncodedString()])
        }
        defer { http.invalidateAndCancel() }
        let values = try await provider.search(trackName: "Test 1997", artistName: "Singer")
        XCTAssertEqual(values.first?.lyrics.count, 2); XCTAssertEqual(provider.requestCount, 3)
        XCTAssertEqual(values.first?.sourceSongID, String(repeating: "A", count: 32))
        XCTAssertFalse(values.first?.sourceIdentity?.contains("CCCC") ?? true)
    }

    func testWrongSingerRemixAndRemovedYearNeverFetchLyrics() async throws {
        for source in PlatformLyricSource.allCases {
            for (title, artist) in [("Test", "Singer"), ("Test 1997 (Remix)", "Singer"), ("Test 1997", "Cover Singer")] {
                let (provider, http) = try provider(source) { [self] _ in try reply(searchJSON(source, title: title, artist: artist)) }
                defer { http.invalidateAndCancel() }
                let values = try await provider.search(trackName: "Test 1997", artistName: "Singer")
                XCTAssertTrue(values.isEmpty); XCTAssertEqual(provider.requestCount, 1)
            }
        }
    }

    func testMalformedSearchIDsAndHTMLNeverBecomeNoLyrics() async throws {
        for source in PlatformLyricSource.allCases {
            for object in [searchJSON(source, id: "../secret?token=x"), ["unexpected": true]] {
                let (provider, http) = try provider(source) { [self] _ in try reply(object) }
                defer { http.invalidateAndCancel() }
                do { _ = try await provider.searchCandidates(trackName: "Test", artistName: "Singer"); XCTFail("Malformed response accepted") }
                catch { XCTAssertEqual(error as? LyricSourceError, .invalidResponse) }
            }
        }
    }

    func testLyricsCannotUseForgedOrStaleSearchCandidate() async throws {
        for source in PlatformLyricSource.allCases {
            let (provider, http) = try provider(source) { [self] _ in try reply(searchJSON(source)) }
            defer { http.invalidateAndCancel() }
            let songs = try await provider.searchCandidates(trackName: "Test 1997", artistName: "Singer")
            let song = try XCTUnwrap(songs.first)
            let fake = HTTPSourceSong(id: song.id, trackName: "Other", artistName: song.artistName, albumName: song.albumName, durationMs: song.durationMs, hasSyncedLyrics: true)
            do { _ = try await provider.lyrics(for: fake); XCTFail("Forged candidate accepted") }
            catch { XCTAssertEqual(error as? LyricSourceError, .invalidResponse) }
            XCTAssertEqual(provider.requestCount, 1)
        }
    }

    func testKuwoRejectsMismatchedIDNegativeTimeAndBusinessError() async throws {
        for object: [String: Any] in [
            ["status": 301, "msg": "temporary error"],
            ["status": 200, "data": ["songinfo": ["id": "999"], "lrclist": []]],
            ["status": 200, "data": ["songinfo": ["id": "123"], "lrclist": [["time": "-1", "lineLyric": "Synthetic"]]]]
        ] {
            let (provider, http) = try provider(.kuwo) { [self] request in
                if request.url?.host == "search.kuwo.cn" { return try reply(searchJSON(.kuwo)) }
                return try reply(object, mime: "text/html")
            }
            defer { http.invalidateAndCancel() }
            do { _ = try await provider.search(trackName: "Test 1997", artistName: "Singer"); XCTFail("Invalid lyric response accepted") }
            catch {
                if (object["status"] as? Int) == 301 { XCTAssertTrue(error is PlatformLyricError) }
                else { XCTAssertEqual(error as? LyricSourceError, .invalidResponse) }
            }
        }
    }

    func testMigrationIsIdempotentPreservesDisableDeleteAndBackupRestoresDisabled() async throws {
        let suite = "PlatformSources." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LyricSourceStore(defaults: defaults)
        try store.installPlatformDefaults()
        XCTAssertEqual(store.sources.count, 5); XCTAssertTrue(store.sources.allSatisfy(\.isEnabled))
        let first = store.sources[0]
        try store.setEnabled(first.id, false); try store.remove(store.sources[1].id)
        try store.installPlatformDefaults()
        XCTAssertEqual(store.sources.count, 4); XCTAssertFalse(store.sources[0].isEnabled)
        let preferences = PreviewRecordingPreferences(defaults: defaults)
        let data = try PreviewBackup.export(sources: store, preferences: preferences)
        let plan = try PreviewBackup.prepare(data, sources: store, preferences: preferences)
        try PreviewBackup.restore(plan, sources: store, preferences: preferences, defaults: defaults)
        XCTAssertTrue(store.sources.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(LyricSourceStore(defaults: defaults).sources, store.sources)
    }

    func testMigrationCannotPartiallyOverwriteFullOrCorruptStore() async throws {
        let suite = "PlatformSources." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LyricSourceStore(defaults: defaults)
        for n in 0..<14 { _ = try store.importManifest(JSONEncoder().encode(manifest(baseURL: "https://example.com/\(n)/"))) }
        let before = store.sources
        XCTAssertThrowsError(try store.installPlatformDefaults()); XCTAssertEqual(store.sources, before)
        defaults.set(Data("corrupt".utf8), forKey: LyricSourceStore.storageKey)
        let corrupt = LyricSourceStore(defaults: defaults)
        try corrupt.installPlatformDefaults()
        XCTAssertEqual(defaults.data(forKey: LyricSourceStore.storageKey), Data("corrupt".utf8))
    }

    func testHTTPFailuresAreErrorsAndRateLimitHasNoImmediateRetry() async throws {
        for source in PlatformLyricSource.allCases {
            for status in [401, 403, 429, 503] {
                let (provider, http) = try provider(source) { _ in .init(status: status) }
                defer { http.invalidateAndCancel() }
                do { _ = try await provider.search(trackName: "Test", artistName: "Singer"); XCTFail("Error silently ignored") }
                catch { XCTAssertEqual(error as? LyricSourceError, status == 429 ? .rateLimited : .httpStatus(status)) }
                XCTAssertEqual(provider.requestCount, 1)
                if status == 429 {
                    do { _ = try await provider.search(trackName: "Test", artistName: "Singer"); XCTFail("Rate limit ignored") }
                    catch { XCTAssertEqual(error as? LyricSourceError, .rateLimited) }
                    XCTAssertEqual(provider.requestCount, 1)
                }
            }
        }
    }

    func testNativeSourceFailureAndRateLimitDoNotHideIndependentLaterSource() async throws {
        for status in [429, 503] {
            let (bad, http) = try provider(.qqMusic) { _ in .init(status: status) }
            defer { http.invalidateAndCancel() }
            var calls = 0
            let later = FakeProvider("Later") { _ in .init(lyrics: [], colorData: nil) }
            later.searchAction = { [self] title, artist in
                calls += 1
                return [.init(lyricType: "Later", songName: title, albumName: "Album", artistName: artist, lyrics: LyricsParser(lyrics: lrc).lyrics)]
            }
            let model = LyricPreviewSession(providers: [bad, later])
            model.trackQuery = "Test 1997"; model.artistQuery = "Singer"
            await model.search()?.value
            XCTAssertEqual(calls, 1); XCTAssertEqual(model.results.count, 1); XCTAssertEqual(model.sourceErrors.count, 1)
        }
    }

    func testNativeSearchAndLyricRequestCountsStayBounded() async throws {
        let (provider, http) = try provider(.netease) { [self] request in
            if request.url!.path.contains("search") {
                return try reply(["code": 200, "result": ["songs": (1...20).map { n in
                    ["id": n, "name": "Test 1997", "artists": [["name": "Singer"]], "album": ["name": "Album"], "duration": 30000] as [String: Any]
                }]])
            }
            return try reply(["code": 200, "lrc": ["lyric": lrc]])
        }
        defer { http.invalidateAndCancel() }
        let result = try await provider.search(trackName: "Test 1997", artistName: "Singer")
        XCTAssertEqual(result.count, 2); XCTAssertEqual(provider.requestCount, 3)
    }

    func testNativeCancellationMakesNoFurtherRequests() async throws {
        let (provider, http) = try provider(.kuwo) { _ in .init(status: 503) }
        defer { http.invalidateAndCancel() }
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await provider.search(trackName: "Test 1997", artistName: "Singer")
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request continued") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testRealHTMLIsRejectedEvenOnMislabeledFixedJSONEndpoint() async throws {
        let (provider, http) = try provider(.kuwo) { [self] request in
            if request.url?.host == "search.kuwo.cn" { return try reply(searchJSON(.kuwo)) }
            return .init(headers: ["Content-Type": "text/html"], data: Data("<html>Sign in</html>".utf8))
        }
        defer { http.invalidateAndCancel() }
        do { _ = try await provider.search(trackName: "Test 1997", artistName: "Singer"); XCTFail("HTML accepted") }
        catch { XCTAssertEqual(error as? LyricSourceError, .invalidResponse) }
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testMiguPinnedCDNAllowsMissingMIMEButNotHTMLOrForgedURLs() async throws {
        for html in [false, true] {
            let (provider, http) = try provider(.migu) { [self] request in
                if request.url?.host == "app.c.nf.migu.cn" { return try reply(searchJSON(.migu)) }
                return .init(headers: [:], data: Data((html ? "<html>Sign in</html>" : lrc).utf8))
            }
            defer { http.invalidateAndCancel() }
            do {
                let values = try await provider.search(trackName: "Test 1997", artistName: "Singer")
                XCTAssertFalse(html)
                XCTAssertEqual(values.first?.lyrics.count, 2)
                XCTAssertNil(values.first?.durationMS)
                XCTAssertEqual(values.first?.requiresManualSelection, true)
            } catch { XCTAssertTrue(html); XCTAssertEqual(error as? LyricSourceError, .invalidResponse) }
            XCTAssertEqual(provider.requestCount, 2)
        }
        for value in ["http://d.musicapp.migu.cn/data/oss/resource/a", "https://evil.example/data/oss/resource/a",
                      "https://d.musicapp.migu.cn:443/data/oss/resource/a", "https://user@d.musicapp.migu.cn/data/oss/resource/a",
                      "https://d.musicapp.migu.cn/data/oss/resource/../a", "https://d.musicapp.migu.cn/data/oss/resource/%2E%2E/a",
                      "https://d.musicapp.migu.cn/data/oss/resource/a?token=x", "https://d.musicapp.migu.cn/audio/a"] {
            XCTAssertNil(PlatformLyricAPI.miguLyricURL(value))
        }
    }

    func testMiguUpgradeDoesNotReaddDeletedLegacySourcesOrEnableDisabledOnes() throws {
        let suite = "MiguUpgrade." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LyricSourceStore(defaults: defaults)
        _ = try store.importManifest(JSONEncoder().encode(PlatformLyricSource.qqMusic.manifest), enabled: false)
        defaults.set(true, forKey: "platformLyricSources.installed.v1")
        try store.installPlatformDefaults()
        XCTAssertEqual(store.sources.map(\.manifest.apiFormat), [.qqMusic, .migu])
        XCTAssertFalse(store.sources[0].isEnabled)
        try store.remove(store.sources[1].id)
        try store.installPlatformDefaults()
        XCTAssertEqual(store.sources.count, 1)
    }

    func testMiguKnownUntimedFileIsANoticeNotASourceFailure() async throws {
        let (provider, http) = try provider(.migu) { [self] request in
            if request.url?.host == "app.c.nf.migu.cn" { return try reply(searchJSON(.migu)) }
            return .init(headers: ["Content-Type": "application/octet-stream"], data: Data("@migu music@\nSynthetic lyric without timing\nAnother synthetic line".utf8))
        }
        defer { http.invalidateAndCancel() }
        var notes: [String] = [], failures = 0, results: [SongResult] = []
        try await PreviewSearchPipeline.search(track: "Test 1997", artist: "Singer", providers: [provider], validate: {},
            note: { notes.append($0) }, failure: { _, _ in failures += 1 }, append: { results += $0 })
        XCTAssertEqual(failures, 0)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(notes.contains { $0.contains("无时间轴") })
        XCTAssertEqual(notes.filter { $0.contains("无时间轴") }.count, 1)
        XCTAssertEqual(provider.requestCount, 4)
    }

    func testMiguHeaderAndBOMDoNotDiscardValidTimedLyrics() async throws {
        for prefix in ["\u{FEFF}", "@migu music@\n", "\u{FEFF}  @migu music@\r\n"] {
            let (provider, http) = try provider(.migu) { [self] request in
                if request.url?.host == "app.c.nf.migu.cn" { return try reply(searchJSON(.migu)) }
                return .init(headers: ["Content-Type": "text/plain"], data: Data((prefix + lrc).utf8))
            }
            defer { http.invalidateAndCancel() }
            let values = try await provider.search(trackName: "Test 1997", artistName: "Singer")
            XCTAssertEqual(values.first?.lyrics.map(\.startTimeMS), [1000, 2500])
        }
    }

    func testMiguUntimedCandidateDoesNotHideLaterTimedCandidate() async throws {
        let (provider, http) = try provider(.migu) { [self] request in
            if request.url?.host == "app.c.nf.migu.cn" {
                let first = (searchJSON(.migu)["songResultData"] as! [String: Any])["result"] as! [[String: Any]]
                var second = first[0]; second["id"] = "124"
                second["lyricUrl"] = "https://d.musicapp.migu.cn/data/oss/resource/fixture/timed"
                return try reply(["code": "000000", "songResultData": ["totalCount": "2", "result": first + [second]]])
            }
            return .init(headers: [:], data: Data((request.url!.path.hasSuffix("timed") ? lrc : "@migu music@\nSynthetic untimed words").utf8))
        }
        defer { http.invalidateAndCancel() }
        let values = try await provider.search(trackName: "Test 1997", artistName: "Singer")
        XCTAssertEqual(values.first?.sourceSongID, "124")
        XCTAssertEqual(values.first?.lyrics.count, 2)
        XCTAssertEqual(provider.requestCount, 3)
    }

    func testKuwoRetriesOnlyExplicitMusicQueryFailureOnce() async throws {
        let lyrics = PlatformRequestLog()
        let (provider, http) = try provider(.kuwo) { [self] request in
            if request.url?.host == "search.kuwo.cn" { return try reply(searchJSON(.kuwo)) }
            if lyrics.record(request) == 1 { return try reply(["status": 301, "msg": "音乐查询失败"], mime: "text/html") }
            return try reply(["status": 200, "data": ["songinfo": ["id": "123", "artist": "Singer"],
                "lrclist": [["time": "1", "lineLyric": "Synthetic first"], ["time": "2.5", "lineLyric": "Synthetic next"]]]], mime: "text/html")
        }
        defer { http.invalidateAndCancel() }
        let values = try await provider.search(trackName: "Test 1997", artistName: "Singer")
        XCTAssertEqual(values.first?.lyrics.count, 2)
        XCTAssertEqual(provider.requestCount, 3)
        let requests = lyrics.urls
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first, requests.last)
    }

    func testKuwoRepeatedFailureIsBoundedAndUnknownOrSecurityMessagesAreNotRetried() async throws {
        for message in ["音乐查询失败", "temporary error", "访问异常，请验证身份", "请登录"] {
            let searches = PlatformRequestLog()
            let (provider, http) = try provider(.kuwo) { [self] request in
                if request.url?.host == "search.kuwo.cn" { _ = searches.record(request); return try reply(searchJSON(.kuwo)) }
                return try reply(["status": 301, "msg": message], mime: "text/html")
            }
            defer { http.invalidateAndCancel() }
            var failures = 0
            try await PreviewSearchPipeline.search(track: "Test 1997", artist: "Singer", providers: [provider], validate: {},
                note: { _ in }, failure: { _, _ in failures += 1 }, append: { XCTAssertTrue($0.isEmpty) })
            XCTAssertEqual(failures, 1)
            XCTAssertEqual(provider.requestCount, message == "音乐查询失败" ? 3 : 2)
            XCTAssertEqual(searches.urls.count, 1)
        }
    }

    func testKuwoRetryCancellationAndHTTPRefusalsDoNotStartAnotherRequest() async throws {
        let lyrics = PlatformRequestLog()
        let (provider, http) = try provider(.kuwo) { [self] request in
            if request.url?.host == "search.kuwo.cn" { return try reply(searchJSON(.kuwo)) }
            _ = lyrics.record(request)
            return try reply(["status": 301, "msg": "音乐查询失败"], mime: "text/html")
        }
        defer { http.invalidateAndCancel() }
        let task = Task { try await provider.search(trackName: "Test 1997", artistName: "Singer") }
        for _ in 0..<1000 {
            if !lyrics.urls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(lyrics.urls.count, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled retry continued") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(provider.requestCount, 2)

        for status in [401, 403, 429] {
            let calls = PlatformRequestLog()
            let (denied, transport) = try self.provider(.kuwo) { [self] request in
                if request.url?.host == "search.kuwo.cn" { return try reply(searchJSON(.kuwo)) }
                if calls.record(request) == 1 { return try reply(["status": 301, "msg": "音乐查询失败"], mime: "text/html") }
                return .init(status: status)
            }
            defer { transport.invalidateAndCancel() }
            do { _ = try await denied.search(trackName: "Test 1997", artistName: "Singer"); XCTFail("Refusal ignored") }
            catch { XCTAssertEqual(error as? LyricSourceError, status == 429 ? .rateLimited : .httpStatus(status)) }
            XCTAssertEqual(denied.requestCount, 3)
        }
    }

    func testMiguUnrecognizedHTMLPackedOrEmptyBodiesAreNotUntimedNotices() throws {
        for text in ["@migu music@\n", "@migu music@\n<html>Access denied</html>", "@migu music@\n{\"error\":403}",
                     "@migu music@\n" + String(repeating: "A", count: 200), "Access denied", "[broken]"] {
            XCTAssertThrowsError(try PlatformLyricAPI.miguLyrics(Data(text.utf8))) {
                XCTAssertEqual($0 as? LyricSourceError, .invalidResponse)
            }
        }
    }
}
