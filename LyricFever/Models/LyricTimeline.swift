import Foundation

enum LyricTimeline {
    // Positive offset delays the lyric display; it never changes the player's position.
    static func activeIndex(in lyrics: [LyricLine], positionMS: Double, offsetMS: Double = 0) -> Int? {
        guard positionMS.isFinite, offsetMS.isFinite, !lyrics.isEmpty else { return nil }
        let position = positionMS - offsetMS
        var low = 0
        var high = lyrics.count
        while low < high {
            let middle = low + (high - low) / 2
            if lyrics[middle].startTimeMS <= position { low = middle + 1 }
            else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }
}

struct PlaybackSnapshot: Equatable, Sendable {
    let trackID: String
    let trackName: String
    let artistName: String
    let albumName: String
    let durationMS: Int
    let positionMS: Double
    let isPlaying: Bool

    var isValid: Bool {
        !trackID.isEmpty && !trackName.isEmpty && !artistName.isEmpty
            && durationMS > 0 && durationMS <= 86_400_000
            && positionMS.isFinite && positionMS >= 0 && positionMS <= Double(durationMS) + 2000
    }
}
