import Foundation

struct HTTPSourceSong: Decodable, Sendable {
    struct EmbeddedLyrics: Sendable {
        let sourceURL: URL
        let text: String
    }
    let id: String
    let trackName: String
    let artistName: String
    let albumName: String?
    let durationMs: Double?
    let hasSyncedLyrics: Bool
    let embeddedLyrics: EmbeddedLyrics?

    // Custom HTTP JSON cannot inject the LRCLIB-only search payload.
    private enum CodingKeys: String, CodingKey {
        case id, trackName, artistName, albumName, durationMs, hasSyncedLyrics
    }

    init(id: String, trackName: String, artistName: String, albumName: String?, durationMs: Double?,
         hasSyncedLyrics: Bool, embeddedLyrics: EmbeddedLyrics? = nil) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.durationMs = durationMs
        self.hasSyncedLyrics = hasSyncedLyrics
        self.embeddedLyrics = embeddedLyrics
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), trackName: try values.decode(String.self, forKey: .trackName),
                  artistName: try values.decode(String.self, forKey: .artistName), albumName: try values.decodeIfPresent(String.self, forKey: .albumName),
                  durationMs: try values.decodeIfPresent(Double.self, forKey: .durationMs), hasSyncedLyrics: try values.decode(Bool.self, forKey: .hasSyncedLyrics))
    }

    var isValid: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.utf8.count <= 1024
            && !LyricSongMatcher.normalized(trackName).isEmpty && !LyricSongMatcher.normalized(artistName).isEmpty
            && (durationMs == nil || (durationMs!.isFinite && durationMs! >= 0 && durationMs! <= 86_400_000))
    }
}

enum LyricSongMatcher {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func candidates(_ songs: [HTTPSourceSong], request: LyricFetchRequest) -> [HTTPSourceSong] {
        guard let artist = request.artistName, !normalized(artist).isEmpty, !normalized(request.trackName).isEmpty else { return [] }
        let matching = songs.filter {
            $0.isValid && $0.hasSyncedLyrics && normalized($0.trackName) == normalized(request.trackName) && normalized($0.artistName) == normalized(artist)
                && ($0.durationMs == nil || request.durationMS <= 0 || abs($0.durationMs! - Double(request.durationMS)) <= 2000)
        }
        if matching.count <= 1 { return matching }
        if let album = request.albumName, !normalized(album).isEmpty {
            let exactAlbum = matching.filter { normalized($0.albumName ?? "") == normalized(album) }
            if exactAlbum.count == 1 { return exactAlbum }
        }
        // Identical titles can still be different masters. Leave ambiguous versions to manual search.
        return []
    }
}

@MainActor
final class CustomHTTPSourceProvider: LyricProvider {
    private struct SearchResponse: Decodable { let apiVersion: Int; let songs: [HTTPSourceSong] }
    private struct LyricsResponse: Decodable { let apiVersion: Int; let id: String; let syncedLyrics: String?; let instrumental: Bool }
    private struct LRCLIBRecord: Decodable {
        let id: Int
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: Double
        let instrumental: Bool
        let syncedLyrics: String?

        func song(sourceURL: URL) -> HTTPSourceSong {
            HTTPSourceSong(id: String(id), trackName: trackName, artistName: artistName, albumName: albumName,
                           durationMs: duration * 1000, hasSyncedLyrics: !instrumental && syncedLyrics != nil,
                           embeddedLyrics: instrumental ? nil : syncedLyrics.map { .init(sourceURL: sourceURL, text: $0) })
        }
    }

    let manifest: LyricSourceManifest
    let providerName: String
    private let baseURL: URL
    private let client: LyricHTTPClient
    private let delayNanoseconds: UInt64
    private let amll: AMLLSource?
    private let platform: PlatformLyricAPI?
    var searchObservation: (([HTTPSourceSong]) -> Void)?
    var candidateFailureObservation: ((String, Error) -> Void)?
    private(set) var searchNotices: [String] = []

    var requestCount: Int { client.requestCount }
    var lastHTTPReceipt: LyricHTTPReceipt? { client.lastReceipt }

    func reusesSearchLyrics(for song: HTTPSourceSong) -> Bool {
        manifest.apiFormat == .lrclib && song.hasSyncedLyrics && song.embeddedLyrics?.sourceURL == baseURL
    }

    init(manifest: LyricSourceManifest, client: LyricHTTPClient? = nil, requestDelay: Double = 0.25) throws {
        self.manifest = manifest
        providerName = manifest.name
        baseURL = try manifest.validatedURL()
        let http = client ?? LyricHTTPClient()
        self.client = http
        amll = manifest.apiFormat == .amllTTML ? AMLLSource(client: http) : nil
        platform = PlatformLyricSource(rawValue: manifest.apiFormat.rawValue).map { PlatformLyricAPI(source: $0, client: http) }
        delayNanoseconds = UInt64(max(0, requestDelay) * 1_000_000_000)
    }

    func fetchNetworkLyrics(trackName: String, trackID: String, currentlyPlayingArtist: String?, currentAlbumName: String?) async throws -> NetworkFetchReturn {
        try await fetchNetworkLyrics(request: LyricFetchRequest(generation: UUID(), trackID: trackID, trackName: trackName,
                                                               artistName: currentlyPlayingArtist, albumName: currentAlbumName, durationMS: 0))
    }

    func fetchNetworkLyrics(request: LyricFetchRequest) async throws -> NetworkFetchReturn {
        if manifest.apiFormat == .amllTTML { return NetworkFetchReturn(lyrics: [], colorData: nil) }
        return try await withLyricDeadline(seconds: 8) { [self] in
            let songs = try await searchCandidates(trackName: request.trackName, artistName: request.artistName ?? "")
            for song in LyricSongMatcher.candidates(songs, request: request).prefix(2) {
                let lyrics = try await lyrics(for: song)
                if LyricFetchPipeline.isValid(lyrics, durationMS: request.durationMS) {
                    return NetworkFetchReturn(lyrics: lyrics, colorData: nil)
                }
            }
            return NetworkFetchReturn(lyrics: [], colorData: nil)
        }
    }

    func search(trackName: String, artistName: String) async throws -> [SongResult] {
        try await search(trackName: trackName, artistName: artistName, spotifyTrackID: nil)
    }
    func search(trackName: String, artistName: String, spotifyTrackID: String?,
                onResult: (@MainActor (SongResult) throws -> Void)? = nil) async throws -> [SongResult] {
        searchNotices = []
        return try await withLyricDeadline(seconds: 8) { [self] in
            let candidates = try await searchCandidates(trackName: trackName, artistName: artistName, spotifyTrackID: spotifyTrackID)
            searchObservation?(candidates)
            var results: [SongResult] = []
            var firstCandidateFailure: Error?
            let ordered = platform == nil ? candidates : candidates.filter {
                PreviewRecordingMatcher.normalized($0.trackName) == PreviewRecordingMatcher.normalized(trackName)
                    && (artistName.isEmpty || [.normalized, .verifiedAlias].contains(PreviewRecordingMatcher.artistRelation($0.artistName, artistName)))
            }
            for song in ordered.prefix(platform == nil ? 5 : 2) where song.hasSyncedLyrics {
                try Task.checkCancellation()
                do {
                    let lines = try await lyrics(for: song)
                    try Task.checkCancellation()
                    if LyricFetchPipeline.isValid(lines) {
                        let result = SongResult(lyricType: providerName, songName: song.trackName, albumName: song.albumName ?? "",
                                                  artistName: song.artistName, lyrics: lines,
                                                  durationMS: song.durationMs.map { Int($0.rounded()) },
                                                  sourceIdentity: manifest.apiFormat.rawValue + "|" + baseURL.absoluteString,
                                                  sourceSongID: song.id, requiresManualSelection: manifest.apiFormat == .amllTTML || manifest.apiFormat == .migu)
                        results.append(result)
                        try onResult?(result)
                    }
                } catch {
                    try Task.checkCancellation()
                    if error as? PlatformLyricError == .untimedLyrics {
                        let message = PlatformLyricError.untimedLyrics.localizedDescription
                        if !searchNotices.contains(message) { searchNotices.append(message) }
                        continue
                    }
                    candidateFailureObservation?(song.id, error)
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    if error is FetchError { throw error }
                    if error as? LyricSourceError == .rateLimited { throw error }
                    if let sourceError = error as? LyricSourceError, case .httpStatus(let status) = sourceError, status == 401 || status == 403 { throw error }
                    if firstCandidateFailure == nil { firstCandidateFailure = error }
                }
            }
            // An unreachable candidate is not evidence that the source has no lyrics.
            if results.isEmpty, let firstCandidateFailure { throw firstCandidateFailure }
            return results
        }
    }

    func searchCandidates(trackName: String, artistName: String, spotifyTrackID: String? = nil) async throws -> [HTTPSourceSong] {
        guard !trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        if let amll { return try await amll.candidates(track: trackName, artist: artistName, spotifyTrackID: spotifyTrackID) }
        if let platform { return try await platform.candidates(track: trackName, artist: artistName) }
        let path = manifest.apiFormat == .lrclib ? "api/search" : "v1/search"
        var query = [URLQueryItem(name: "track_name", value: trackName), URLQueryItem(name: "limit", value: "5")]
        if !artistName.isEmpty { query.append(URLQueryItem(name: "artist_name", value: artistName)) }
        let data = try await client.get(endpoint(path, query: query))
        do {
            if manifest.apiFormat == .lrclib {
                let songs = try JSONDecoder().decode([LRCLIBRecord].self, from: data).prefix(5).map { $0.song(sourceURL: baseURL) }
                guard songs.allSatisfy(\.isValid) else { throw LyricSourceError.invalidResponse }
                return Array(songs)
            }
            let response = try JSONDecoder().decode(SearchResponse.self, from: data)
            guard response.apiVersion == 1 else { throw LyricSourceError.unsupportedVersion }
            guard response.songs.prefix(5).allSatisfy(\.isValid) else { throw LyricSourceError.invalidResponse }
            return Array(response.songs.prefix(5))
        } catch let error as LyricSourceError { throw error }
        catch { throw LyricSourceError.invalidResponse }
    }

    func lyrics(for song: HTTPSourceSong) async throws -> [LyricLine] {
        try Task.checkCancellation()
        guard song.isValid else { throw LyricSourceError.invalidResponse }
        if let amll { return try await amll.lyrics(id: song.id) }
        if let platform {
            if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
            return try await platform.lyrics(for: song)
        }
        if manifest.apiFormat == .lrclib {
            guard let id = Int(song.id), id >= 0 else { throw LyricSourceError.invalidResponse }
            if reusesSearchLyrics(for: song), let embedded = song.embeddedLyrics {
                let lines = LyricsParser(lyrics: embedded.text).lyrics
                try Task.checkCancellation()
                return lines
            }
        }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        let data: Data
        let lrc: String?
        do {
            if manifest.apiFormat == .lrclib {
                guard let id = Int(song.id), id >= 0 else { throw LyricSourceError.invalidResponse }
                data = try await client.get(endpoint("api/get/\(id)"))
                let record = try JSONDecoder().decode(LRCLIBRecord.self, from: data)
                guard String(record.id) == song.id, record.trackName == song.trackName, record.artistName == song.artistName else { throw LyricSourceError.invalidResponse }
                lrc = record.instrumental ? nil : record.syncedLyrics
            } else {
                data = try await client.get(endpoint("v1/lyrics", query: [URLQueryItem(name: "id", value: song.id)]))
                let response = try JSONDecoder().decode(LyricsResponse.self, from: data)
                guard response.apiVersion == 1 else { throw LyricSourceError.unsupportedVersion }
                guard response.id == song.id else { throw LyricSourceError.invalidResponse }
                lrc = response.instrumental ? nil : response.syncedLyrics
            }
        } catch let error as LyricSourceError { throw error }
        catch is DecodingError { throw LyricSourceError.invalidResponse }
        catch { throw error }
        return lrc.map { LyricsParser(lyrics: $0).lyrics } ?? []
    }

    private func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { throw LyricSourceError.unsafeURL }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw LyricSourceError.unsafeURL }
        return url
    }
}
