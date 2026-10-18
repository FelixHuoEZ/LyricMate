import XCTest
@testable import LyricFeverCore

@MainActor
final class CustomHTTPSourceTests: XCTestCase {
    private let lyrics = Data(#"{"apiVersion":1,"id":"opaque-id","syncedLyrics":"[00:01]Alpha\n[00:02]Beta","instrumental":false}"#.utf8)
    private let search = Data(#"{"apiVersion":1,"songs":[{"id":"opaque-id","trackName":"Song","artistName":"Artist","albumName":"Album","durationMs":30000,"hasSyncedLyrics":true}]}"#.utf8)

    func testSearchFetchAndPathPrefix() async throws {
        let search = self.search
        let lyrics = self.lyrics
        let (session, host) = StubURLProtocol.session { req in
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertNotNil(req.value(forHTTPHeaderField: "User-Agent"))
            if req.url!.path == "/prefix/v1/search" { return .init(data: search) }
            XCTAssertEqual(req.url!.path, "/prefix/v1/lyrics")
            XCTAssertEqual(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "opaque-id")
            return .init(data: lyrics)
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/prefix"), client: LyricHTTPClient(session: session), requestDelay: 0)
        let result = try await provider.fetchNetworkLyrics(request: request())
        XCTAssertEqual(result.lyrics.map(\.words), ["Alpha", "Beta"])
    }

    func testSpecialCharactersAreEncoded() async throws {
        let track = "A & B + / ? # \u{4E2D}"
        let (session, host) = StubURLProtocol.session { req in
            let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first(where: { $0.name == "track_name" })?.value, track)
            XCTAssertEqual(query.first(where: { $0.name == "artist_name" })?.value, "Artist & Other")
            return .init(data: Data(#"{"apiVersion":1,"songs":[]}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session), requestDelay: 0)
        let result = try await provider.searchCandidates(trackName: track, artistName: "Artist & Other")
        XCTAssertTrue(result.isEmpty)
    }

    func testHTTPFailuresRemainErrors() async throws {
        for status in [401, 403, 500, 502, 503, 302] {
            let (session, host) = StubURLProtocol.session { _ in .init(status: status, data: Data("error".utf8)) }
            defer { session.invalidateAndCancel() }
            do { _ = try await LyricHTTPClient(session: session).get(URL(string: "https://\(host)/")!); XCTFail("Expected HTTP failure") }
            catch { XCTAssertEqual(error as? LyricSourceError, .httpStatus(status)) }
        }
    }

    func testRateLimitPreventsImmediateSecondRequest() async throws {
        var calls = 0
        let (session, host) = StubURLProtocol.session { _ in
            calls += 1
            return .init(status: 429, headers: ["Retry-After": "60"], data: Data("not JSON".utf8))
        }
        defer { session.invalidateAndCancel() }
        let client = LyricHTTPClient(session: session)
        for _ in 0..<2 {
            do { _ = try await client.get(URL(string: "https://\(host)/")!); XCTFail("Expected rate limit") }
            catch { XCTAssertEqual(error as? LyricSourceError, .rateLimited) }
        }
        XCTAssertEqual(calls, 1)
    }

    func testRejectsHTMLAndMissingContentType() async throws {
        for headers in [["Content-Type": "text/html"], [:]] {
            let (session, host) = StubURLProtocol.session { _ in .init(headers: headers, data: Data("<html>Login</html>".utf8)) }
            defer { session.invalidateAndCancel() }
            do { _ = try await LyricHTTPClient(session: session).get(URL(string: "https://\(host)/")!); XCTFail("Expected invalid response") }
            catch { XCTAssertEqual(error as? LyricSourceError, .invalidResponse) }
        }
    }

    func testStreamingLimitWithMissingOrFalseLength() async throws {
        for length in [nil, "1"] {
            var headers = ["Content-Type": "application/json"]
            if let length { headers["Content-Length"] = length }
            let (session, host) = StubURLProtocol.session { _ in .init(headers: headers, data: Data(repeating: 65, count: 17)) }
            defer { session.invalidateAndCancel() }
            do { _ = try await LyricHTTPClient(session: session).get(URL(string: "https://\(host)/")!, maximumBytes: 16); XCTFail("Expected size failure") }
            catch { XCTAssertEqual(error as? LyricSourceError, .responseTooLarge) }
        }
    }

    func testResponseExactlyAtLimitIsAccepted() async throws {
        let (session, host) = StubURLProtocol.session { _ in .init(data: Data(repeating: 65, count: 16)) }
        defer { session.invalidateAndCancel() }
        let data = try await LyricHTTPClient(session: session).get(URL(string: "https://\(host)/")!, maximumBytes: 16)
        XCTAssertEqual(data.count, 16)
    }

    func testMalformedJSONAndUnsupportedAPI() async throws {
        for payload in ["{broken", "{\"apiVersion\":2,\"songs\":[]}", "{\"apiVersion\":1}"] {
            let (session, host) = StubURLProtocol.session { _ in .init(data: Data(payload.utf8)) }
            defer { session.invalidateAndCancel() }
            let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session))
            do { _ = try await provider.searchCandidates(trackName: "Song", artistName: "Artist"); XCTFail("Expected invalid data") }
            catch { XCTAssertNotNil(error as? LyricSourceError) }
        }
    }

    func testLyricsResponseIDMustMatchCandidate() async throws {
        let search = self.search
        let (session, host) = StubURLProtocol.session { req in
            .init(data: req.url!.path.hasSuffix("search") ? search : Data(#"{"apiVersion":1,"id":"wrong-id","syncedLyrics":"[00:01]A","instrumental":false}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session), requestDelay: 0)
        do { _ = try await provider.fetchNetworkLyrics(request: request()); XCTFail("Expected wrong ID failure") }
        catch { XCTAssertEqual(error as? LyricSourceError, .invalidResponse) }
    }

    func testSearchCandidateLimit() async throws {
        let songs = (0..<50).map { ["id": String($0), "trackName": "Song", "artistName": "Artist", "hasSyncedLyrics": false] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["apiVersion": 1, "songs": songs])
        let (session, host) = StubURLProtocol.session { _ in .init(data: data) }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session))
        let result = try await provider.searchCandidates(trackName: "Song", artistName: "Artist")
        XCTAssertEqual(result.count, 5)
    }

    func testAmbiguousAutomaticSearchDoesNotFetchLyrics() async throws {
        let data = Data(#"{"apiVersion":1,"songs":[{"id":"a","trackName":"Song","artistName":"Artist","hasSyncedLyrics":true},{"id":"b","trackName":"Song","artistName":"Artist","hasSyncedLyrics":true}]}"#.utf8)
        let (session, host) = StubURLProtocol.session { req in
            XCTAssertTrue(req.url!.path.hasSuffix("search"))
            return .init(data: data)
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session), requestDelay: 0)
        let result = try await provider.fetchNetworkLyrics(request: request())
        XCTAssertTrue(result.lyrics.isEmpty)
    }

    func testLRCLIBAdapterUsesReadOnlySearchAndUncachedIDFetch() async throws {
        let record = #"{"id":42,"trackName":"Song","artistName":"Artist","albumName":"Album","duration":30,"instrumental":false,"syncedLyrics":"[00:01]A\n[00:02]B"}"#
        let (session, host) = StubURLProtocol.session { req in
            XCTAssertEqual(req.httpMethod, "GET")
            if req.url!.path == "/api/search" { return .init(data: Data(("[" + record + "]").utf8)) }
            XCTAssertEqual(req.url!.path, "/api/get/42")
            return .init(data: Data(record.utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: session), requestDelay: 0)
        let result = try await provider.fetchNetworkLyrics(request: request())
        XCTAssertEqual(result.lyrics.count, 2)
        let candidates = try await provider.search(trackName: "Song", artistName: "Artist")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.durationMS, 30000)
        XCTAssertEqual(provider.requestCount, 2)
        let uncached = HTTPSourceSong(id: "42", trackName: "Song", artistName: "Artist", albumName: "Album", durationMs: 30000, hasSyncedLyrics: true)
        let lines = try await provider.lyrics(for: uncached)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(provider.requestCount, 3)
    }

    func testInvalidCandidateMetadataIsRejected() async throws {
        for song in [
            #"{"id":"","trackName":"Song","artistName":"Artist","hasSyncedLyrics":true}"#,
            #"{"id":"a","trackName":"Song","artistName":"Artist","durationMs":-1,"hasSyncedLyrics":true}"#,
            #"{"id":"a","trackName":"Song","artistName":"Artist","durationMs":1e308,"hasSyncedLyrics":true}"#
        ] {
            let payload = Data(("{\"apiVersion\":1,\"songs\":[" + song + "]}").utf8)
            let (session, host) = StubURLProtocol.session { _ in .init(data: payload) }
            defer { session.invalidateAndCancel() }
            let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session))
            do { _ = try await provider.searchCandidates(trackName: "Song", artistName: "Artist"); XCTFail("Invalid candidate must fail") }
            catch { XCTAssertEqual(error as? LyricSourceError, .invalidResponse) }
        }
    }

    func testLyricsNetworkCancellationIsPreserved() async throws {
        let (session, host) = StubURLProtocol.session { _ in throw URLError(.cancelled) }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session), requestDelay: 0)
        let song = HTTPSourceSong(id: "a", trackName: "Song", artistName: "Artist", albumName: nil, durationMs: nil, hasSyncedLyrics: true)
        do { _ = try await provider.lyrics(for: song); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }

    func testLyricsTransportFailureIsNotReportedAsMalformedJSON() async throws {
        let (session, host) = StubURLProtocol.session { _ in throw URLError(.notConnectedToInternet) }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session), requestDelay: 0)
        let song = HTTPSourceSong(id: "a", trackName: "Song", artistName: "Artist", albumName: nil, durationMs: nil, hasSyncedLyrics: true)
        do { _ = try await provider.lyrics(for: song); XCTFail("Expected network failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testHangingResponseIsCancelledAtInjectedDeadline() async throws {
        let deadline = ManualDeadline()
        let stopped = expectation(description: "Timed-out URL task cancelled")
        let (session, host) = StubURLProtocol.session { _ in
            Task { await deadline.fire() }
            return .init(finish: false, onStop: { stopped.fulfill() })
        }
        defer { session.invalidateAndCancel() }
        let client = LyricHTTPClient(session: session, timeout: { await deadline.wait() })
        do { _ = try await client.get(URL(string: "https://\(host)/")!); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? LyricSourceError, .timeout) }
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testOversizedStreamCancelsUnderlyingURLTask() async throws {
        let stopped = expectation(description: "Oversized URL task cancelled")
        let (session, host) = StubURLProtocol.session { _ in
            .init(data: Data(repeating: 65, count: 17), finish: false, onStop: { stopped.fulfill() })
        }
        defer { session.invalidateAndCancel() }
        do { _ = try await LyricHTTPClient(session: session).get(URL(string: "https://\(host)/")!, maximumBytes: 16); XCTFail("Expected size failure") }
        catch { XCTAssertEqual(error as? LyricSourceError, .responseTooLarge) }
        await fulfillment(of: [stopped], timeout: 1)
    }
}
