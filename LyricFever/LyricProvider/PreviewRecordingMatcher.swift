#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
import Foundation

enum PreviewRecordingMatcher {
    enum ArtistRelation: Equatable { case normalized, verifiedAlias, searchLabel }
    struct Assessment: Equatable {
        let score: Int
        let isReliableMatch: Bool
        let canPreview: Bool
        let explanation: String
    }

    // Observed source labels, not proof of singer or recording identity.
    static let searchLabelGroups = [["孙燕姿", "Stefanie Sun", "Yanzi Sun"]]
    // Apple Music's curated singer page explicitly identifies these two names.
    private static let verifiedAliasGroups = [["薛之谦", "Joker Xue"]]

    static func normalized(_ value: String) -> String {
        LyricSongMatcher.normalized(value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value)
    }

    private static func artists(_ value: String) -> [String] {
        let split = value.replacingOccurrences(of: #"[、,，;；]|\s+(?:&|/|and|feat\.?|ft\.?)\s+"#,
                                              with: "\n", options: [.regularExpression, .caseInsensitive])
        return split.components(separatedBy: "\n").map(normalized).filter { !$0.isEmpty }.sorted()
    }

    static func artistRelation(_ lhs: String, _ rhs: String) -> ArtistRelation? {
        let left = artists(lhs), right = artists(rhs)
        guard !left.isEmpty, left.count == right.count else { return nil }
        if left == right { return .normalized }
        guard left.count == 1 else { return nil }
        if verifiedAliasGroups.contains(where: {
            let labels = $0.map(normalized)
            return labels.contains(left[0]) && labels.contains(right[0])
        }) { return .verifiedAlias }
        // A label group is used only for single-singer candidate discovery.
        guard searchLabelGroups.contains(where: {
            let labels = $0.map(normalized)
            return labels.contains(left[0]) && labels.contains(right[0])
        }) else { return nil }
        return .searchLabel
    }

    static func matches(_ candidate: SongResult, track: String, artist: String, allowSearchLabels: Bool = true) -> Bool {
        guard !normalized(track).isEmpty, normalized(candidate.songName) == normalized(track),
              let relation = artistRelation(candidate.artistName, artist) else { return false }
        return allowSearchLabels || relation != .searchLabel
    }

    @MainActor static func eligibleForMemory(_ candidate: SongResult, playback: PlaybackSnapshot) -> Bool {
        guard matches(candidate, track: playback.trackName, artist: playback.artistName),
              let duration = candidate.durationMS, abs(duration - playback.durationMS) <= 2000,
              candidate.sourceIdentity != nil, candidate.sourceSongID != nil else { return false }
        return LyricFetchPipeline.isValid(candidate.lyrics, durationMS: playback.durationMS)
    }

    @MainActor static func preferred(in results: [SongResult], playback: PlaybackSnapshot, track: String, artist: String) -> UUID? {
        guard normalized(track) == normalized(playback.trackName),
              artist.isEmpty || artistRelation(artist, playback.artistName) == .normalized else { return nil }
        // Stable ties follow source/search order. A score is metadata evidence, not sync accuracy.
        return results.enumerated().filter {
            assessment($0.element, track: track, artist: artist, playback: playback).canPreview
        }.max {
            let left = assessment($0.element, track: track, artist: artist, playback: playback).score
            let right = assessment($1.element, track: track, artist: artist, playback: playback).score
            return left == right ? $0.offset > $1.offset : left < right
        }?.element.id
    }

    @MainActor static func assessment(_ candidate: SongResult, track: String, artist: String, playback: PlaybackSnapshot?) -> Assessment {
        let titleMatches = !normalized(track).isEmpty && normalized(candidate.songName) == normalized(track)
        let currentQuery = playback.map {
            normalized(track) == normalized($0.trackName) && (artist.isEmpty || artistRelation(artist, $0.artistName) == .normalized)
        } == true
        let referenceArtist = artist.isEmpty && currentQuery ? playback?.artistName ?? "" : artist
        let relation = artistRelation(candidate.artistName, referenceArtist)
        var score = titleMatches ? 40 : 0
        let knownArtist = relation == .normalized || relation == .verifiedAlias
        score += knownArtist ? 30 : relation == .searchLabel ? 10 : 0
        var notes = [titleMatches ? L10n.text("Title/version +40") : L10n.text("Different title or version +0"),
                     relation == .normalized ? L10n.text("Full artist match +30") : relation == .verifiedAlias ? L10n.text("Verified artist alias +30") : relation == .searchLabel ? L10n.text("Artist search label +10 (confirmation needed)") : L10n.text("Different artist +0")]
        var durationMatches = false
        var tightDurationMatches = false
        if currentQuery, let playback, let duration = candidate.durationMS, duration >= 0, duration <= 86_400_000 {
            let delta = abs(Double(duration) - Double(playback.durationMS))
            durationMatches = delta <= 2000
            tightDurationMatches = delta <= 1000
            let points = delta <= 500 ? 20 : delta <= 1000 ? 18 : delta <= 2000 ? 15 : 0
            score += points
            notes.append(L10n.text("Duration difference %1$@ ms +%2$@", String(describing: Int(delta)), String(describing: points)))
        } else { notes.append(L10n.text("Unknown duration or no current recording reference +0")) }
        let albumMatches = currentQuery && playback.map {
            !normalized($0.albumName).isEmpty && normalized(candidate.albumName) == normalized($0.albumName)
        } == true
        if albumMatches {
            score += 10; notes.append(L10n.text("Album +10"))
        } else { notes.append(L10n.text("Different or unknown album +0")) }
        let valid = LyricFetchPipeline.isValid(candidate.lyrics, durationMS: currentQuery ? playback?.durationMS ?? 0 : 0)
        let validDuration = candidate.durationMS.map { (0...86_400_000).contains($0) } ?? true
        let artistEvidence = relation == .normalized || relation == .verifiedAlias && albumMatches && tightDurationMatches
        let reliable = currentQuery && titleMatches && artistEvidence && durationMatches
            && valid && validDuration && !candidate.requiresManualSelection && score >= 85
        if relation == .verifiedAlias && !artistEvidence { notes.append(L10n.text("A reliable alias match also needs the same album and a duration difference of at most 1 second")) }
        if candidate.requiresManualSelection { notes.append(L10n.text("Source recording metadata is unverified; provisional display only")) }
        if !valid { notes.append(L10n.text("Lyric timeline validation failed")) }
        if !validDuration { notes.append(L10n.text("Invalid candidate duration")) }
        return .init(score: score, isReliableMatch: reliable, canPreview: valid && validDuration,
                     explanation: notes.joined(separator: " · "))
    }
}
