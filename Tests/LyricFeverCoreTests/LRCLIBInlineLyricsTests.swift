import XCTest
@testable import LyricFeverCore

@MainActor
final class LRCLIBInlineLyricsTests: XCTestCase {
    private func record(id: Int = 42, track: String = "Song", artist: String = "Artist", album: String = "Album",
                        duration: Double = 30, instrumental: Bool = false, lyrics: String? = "[00:01]SyntheticAlpha\n[00:02]SyntheticBeta") throws -> Data {
        var fields: [String: Any] = ["id": id, "trackName": track, "artistName": artist, "albumName": album,
                                     "duration": duration, "instrumental": instrumental]
        fields["syncedLyrics"] = lyrics.map { $0 as Any } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: fields)
    }

    func testSearchEmbeddedLyricsDoNotRequireAnIDDownload() async throws {
        let data = try record()
        let (session, host) = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/search", "Embedded lyrics must not be downloaded again")
            return .init(data: Data(("[" + String(decoding: data, as: UTF8.self) + "]").utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: session), requestDelay: 0)
        let results = try await provider.search(trackName: "Song", artistName: "Artist")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.lyrics.map(\.words), ["SyntheticAlpha", "SyntheticBeta"])
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testAutomaticMatchingReusesTheSameSearchLyrics() async throws {
        let data = try record()
        let (session, host) = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/search")
            return .init(data: Data(("[" + String(decoding: data, as: UTF8.self) + "]").utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: session), requestDelay: 0)
        let result = try await provider.fetchNetworkLyrics(request: request())
        XCTAssertEqual(result.lyrics.count, 2)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testEnhancedSearchLyricsAreNormalizedBeforePresentation() async throws {
        let data = try record(lyrics: "[00:01]<00:01.000>Synthetic<00:01.500>Alpha<00:01.900>\n[00:02]<00:02.000>Synthetic<00:02.500>Beta")
        let (session, host) = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/search")
            return .init(data: Data(("[" + String(decoding: data, as: UTF8.self) + "]").utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: session), requestDelay: 0)
        let results = try await provider.search(trackName: "Song", artistName: "Artist")
        let lines = try XCTUnwrap(results.first).lyrics
        XCTAssertEqual(lines.map(\.words), ["SyntheticAlpha", "SyntheticBeta"])
        XCTAssertEqual(lines.map(\.startTimeMS), [1000, 2000])
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testEnhancedDownloadedLyricsUseTheSameNormalization() async throws {
        let data = try record(lyrics: "[00:01]<00:01.000>SyntheticAlpha\n[00:02]<00:02.000>SyntheticBeta")
        let (session, host) = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/get/42")
            return .init(data: data)
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: session), requestDelay: 0)
        let candidate = HTTPSourceSong(id: "42", trackName: "Song", artistName: "Artist", albumName: "Album", durationMs: 30000, hasSyncedLyrics: true)
        let lines = try await provider.lyrics(for: candidate)
        XCTAssertEqual(lines.map(\.words), ["SyntheticAlpha", "SyntheticBeta"])
        XCTAssertEqual(lines.map(\.startTimeMS), [1000, 2000])
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testFiveCandidatesRequireOnlyOneNetworkInvocation() async throws {
        let records = try (1...5).map { String(decoding: try record(id: $0), as: UTF8.self) }.joined(separator: ",")
        let (session, host) = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/search")
            return .init(data: Data(("[" + records + "]").utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: session))
        let results = try await provider.search(trackName: "Song", artistName: "Artist")
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testInstrumentalRecordCannotExposeEmbeddedLyricText() async throws {
        let data = try record(instrumental: true)
        let (session, host) = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/search")
            return .init(data: Data(("[" + String(decoding: data, as: UTF8.self) + "]").utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: session))
        let candidates = try await provider.searchCandidates(trackName: "Song", artistName: "Artist")
        XCTAssertFalse(try XCTUnwrap(candidates.first).hasSyncedLyrics)
        XCTAssertNil(candidates.first?.embeddedLyrics)
        let results = try await provider.search(trackName: "Song", artistName: "Artist")
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testInvalidEmbeddedTimelineIsNotRetriedOrPresentedAsValid() async throws {
        for lyrics in ["Plain untimed text", "[00:NaN]SyntheticInvalid", ""] {
            let data = try record(lyrics: lyrics)
            let (session, host) = StubURLProtocol.session { request in
                XCTAssertEqual(request.url?.path, "/api/search")
                return .init(data: Data(("[" + String(decoding: data, as: UTF8.self) + "]").utf8))
            }
            defer { session.invalidateAndCancel() }
            let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: session))
            let results = try await provider.search(trackName: "Song", artistName: "Artist")
            XCTAssertTrue(results.isEmpty)
            XCTAssertEqual(provider.requestCount, 1)
        }
    }

    func testCancelledEmbeddedReadDoesNotReturnLyricsOrStartANetworkRead() async throws {
        let data = try record()
        let (session, host) = StubURLProtocol.session { _ in .init(data: Data(("[" + String(decoding: data, as: UTF8.self) + "]").utf8)) }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: session))
        let candidates = try await provider.searchCandidates(trackName: "Song", artistName: "Artist")
        let candidate = try XCTUnwrap(candidates.first)
        let task = Task { @MainActor in try await provider.lyrics(for: candidate) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled read must not return cached/search lyrics") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testOtherSourceCannotReuseTheFirstSourcesSearchPayload() async throws {
        let first = try record(lyrics: "[00:01]SyntheticOldSource")
        let fresh = try record(lyrics: "[00:01]SyntheticFreshSource")
        let (sessionA, hostA) = StubURLProtocol.session { _ in .init(data: Data(("[" + String(decoding: first, as: UTF8.self) + "]").utf8)) }
        let (sessionB, hostB) = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/get/42")
            return .init(data: fresh)
        }
        defer { sessionA.invalidateAndCancel(); sessionB.invalidateAndCancel() }
        let providerA = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(hostA)/", format: .lrclib), client: LyricHTTPClient(session: sessionA))
        let providerB = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(hostB)/", format: .lrclib), client: LyricHTTPClient(session: sessionB), requestDelay: 0)
        let candidates = try await providerA.searchCandidates(trackName: "Song", artistName: "Artist")
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertFalse(providerB.reusesSearchLyrics(for: candidate))
        let lines = try await providerB.lyrics(for: candidate)
        XCTAssertEqual(lines.map(\.words), ["SyntheticFreshSource"])
        XCTAssertEqual(providerB.requestCount, 1)
    }

    func testSearchPayloadStaysBoundToItsImmutableCandidateNotAnIDCache() async throws {
        let a = try record(track: "A", lyrics: "[00:01]SyntheticA")
        let b = try record(track: "B", lyrics: "[00:01]SyntheticB")
        let (session, host) = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/search")
            let track = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "track_name" })?.value
            return .init(data: Data(("[" + String(decoding: track == "A" ? a : b, as: UTF8.self) + "]").utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: session))
        let candidatesA = try await provider.searchCandidates(trackName: "A", artistName: "Artist")
        let candidateA = try XCTUnwrap(candidatesA.first)
        let candidatesB = try await provider.searchCandidates(trackName: "B", artistName: "Artist")
        let candidateB = try XCTUnwrap(candidatesB.first)
        let linesA = try await provider.lyrics(for: candidateA)
        let linesB = try await provider.lyrics(for: candidateB)
        XCTAssertEqual(candidateA.id, candidateB.id)
        XCTAssertEqual(linesA.map(\.words), ["SyntheticA"])
        XCTAssertEqual(linesB.map(\.words), ["SyntheticB"])
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testCustomProtocolCannotInjectAnEmbeddedSearchPayload() async throws {
        let (session, host) = StubURLProtocol.session { request in
            if request.url!.path.hasSuffix("search") {
                return .init(data: Data(#"{"apiVersion":1,"songs":[{"id":"a","trackName":"Song","artistName":"Artist","hasSyncedLyrics":true,"embeddedLyrics":{"sourceURL":"https://fake.example.com/","text":"[00:01]Injected"}}]}"#.utf8))
            }
            return .init(data: Data(#"{"apiVersion":1,"id":"a","syncedLyrics":"[00:01]SyntheticFresh","instrumental":false}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/"), client: LyricHTTPClient(session: session), requestDelay: 0)
        let candidates = try await provider.searchCandidates(trackName: "Song", artistName: "Artist")
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertNil(candidate.embeddedLyrics)
        let lines = try await provider.lyrics(for: candidate)
        XCTAssertEqual(lines.map(\.words), ["SyntheticFresh"])
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testNegativeSourceIDCannotBypassTheExistingIDGuard() async throws {
        let data = try record(id: -1)
        let (session, host) = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/search")
            return .init(data: Data(("[" + String(decoding: data, as: UTF8.self) + "]").utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: session))
        do { _ = try await provider.search(trackName: "Song", artistName: "Artist"); XCTFail("Negative source ID must be rejected") }
        catch { XCTAssertEqual(error as? LyricSourceError, .invalidResponse) }
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testEmbeddedLyricsDoNotRelaxVersionAmbiguityOrDurationMatching() async throws {
        let first = try record(id: 1)
        let second = try record(id: 2)
        let (session, host) = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.path, "/api/search")
            return .init(data: Data(("[" + String(decoding: first, as: UTF8.self) + "," + String(decoding: second, as: UTF8.self) + "]").utf8))
        }
        defer { session.invalidateAndCancel() }
        let provider = try CustomHTTPSourceProvider(manifest: manifest(baseURL: "https://\(host)/", format: .lrclib), client: LyricHTTPClient(session: session))
        let ambiguous = try await provider.fetchNetworkLyrics(request: request())
        let wrongDuration = try await provider.fetchNetworkLyrics(request: request(duration: 50000))
        XCTAssertTrue(ambiguous.lyrics.isEmpty)
        XCTAssertTrue(wrongDuration.lyrics.isEmpty)
        XCTAssertEqual(provider.requestCount, 2)
    }
}
