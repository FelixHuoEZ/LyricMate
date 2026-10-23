//
//  LyricProvider.swift
//  Lyric Fever
//
//  Created by Avi Wadhwa on 2025-07-25.
//

@MainActor
protocol LyricProvider {
    var providerName: String { get }

    @MainActor
    func fetchNetworkLyrics(trackName: String, trackID: String, currentlyPlayingArtist: String?, currentAlbumName: String? ) async throws -> NetworkFetchReturn

    @MainActor
    func search(trackName: String, artistName: String) async throws -> [SongResult]

    func fetchNetworkLyrics(request: LyricFetchRequest) async throws -> NetworkFetchReturn
}

extension LyricProvider {
    func fetchNetworkLyrics(request: LyricFetchRequest) async throws -> NetworkFetchReturn {
        try await fetchNetworkLyrics(trackName: request.trackName, trackID: request.trackID,
                                     currentlyPlayingArtist: request.artistName, currentAlbumName: request.albumName)
    }
}

@MainActor
protocol LyricVersionProvider: LyricProvider {
    var versionSourceIdentity: String { get }
    func retrieveVersion(_ version: PreviewRecordingPreferences.VersionReference) async throws -> SongResult?
}
