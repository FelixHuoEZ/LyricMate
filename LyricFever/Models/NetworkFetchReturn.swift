//
//  NetworkFetchReturn.swift
//  Lyric Fever
//
//  Created by Avi Wadhwa on 2025-08-06.
//

import Foundation

struct NetworkFetchReturn: Sendable {
    let lyrics: [LyricLine]
    let colorData: Int32?

    func processed(withSongName songName: String, duration: Int) -> NetworkFetchReturn {
        let filtered = lyrics.filter { !$0.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard filtered.count > 1 else {
            return NetworkFetchReturn(lyrics: filtered, colorData: colorData)
        }
        if filtered.last?.words == "Now Playing: \(songName)" { return NetworkFetchReturn(lyrics: filtered, colorData: colorData) }

        let nowPlayingLine = LyricLine(startTime: Double(duration) + 5000, words: "Now Playing: \(songName)")
        return NetworkFetchReturn(lyrics: filtered + [nowPlayingLine], colorData: colorData)
    }
}
