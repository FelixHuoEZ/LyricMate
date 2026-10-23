#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
import Foundation
import CryptoKit
import Observation

@MainActor
@Observable
final class PreviewRecordingPreferences {
    struct Recording: Codable, Equatable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let durationMS: Int
        init(_ snapshot: PlaybackSnapshot) {
            id = snapshot.trackID; title = snapshot.trackName; artist = snapshot.artistName
            album = snapshot.albumName; durationMS = snapshot.durationMS
        }
        var valid: Bool {
            let prefix = "spotify:track:"
            let suffix = String(id.dropFirst(prefix.count))
            return id.hasPrefix(prefix) && !suffix.isEmpty && suffix.count <= 128
                && suffix.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
                && !title.isEmpty && !artist.isEmpty && title.utf8.count <= 2048
                && artist.utf8.count <= 2048 && album.utf8.count <= 2048 && durationMS > 0 && durationMS <= 86_400_000
        }
    }
    // A source digest is matched only against enabled providers, never used as a URL.
    struct VersionReference: Codable, Equatable, Sendable {
        let sourceSHA256: String
        let songID: String
        let title: String
        let artist: String
        let album: String
        let durationMS: Int

        init?(_ candidate: SongResult) {
            guard let source = candidate.sourceIdentity, let id = candidate.sourceSongID,
                  let duration = candidate.durationMS else { return nil }
            sourceSHA256 = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
            songID = id; title = candidate.songName; artist = candidate.artistName
            album = candidate.albumName; durationMS = duration
            guard valid else { return nil }
        }
        var valid: Bool {
            Self.validDigest(sourceSHA256) && !songID.isEmpty && songID.utf8.count <= 1024
                && !title.isEmpty && !artist.isEmpty && title.utf8.count <= 2048
                && artist.utf8.count <= 2048 && album.utf8.count <= 2048
                && durationMS > 0 && durationMS <= 86_400_000
        }
        private static func validDigest(_ value: String) -> Bool {
            value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
        }
    }
    struct Entry: Codable, Equatable {
        let recording: Recording
        let candidateSHA256: String
        let offsetMS: Double
        let version: VersionReference?
        init(recording: Recording, candidateSHA256: String, offsetMS: Double, version: VersionReference? = nil) {
            self.recording = recording; self.candidateSHA256 = candidateSHA256
            self.offsetMS = offsetMS; self.version = version
        }
        var valid: Bool {
            recording.valid && candidateSHA256.count == 64
                && candidateSHA256.allSatisfy { "0123456789abcdef".contains($0) }
                && offsetMS.isFinite && abs(offsetMS) <= 10000 && (version?.valid ?? true)
        }
    }
    struct PairKey: Hashable {
        // Neither a display title nor a transient candidate UUID is a persistence key.
        let trackID: String
        let candidateSHA256: String
    }
    struct PairOffset: Codable, Equatable {
        let recording: Recording
        let candidateSHA256: String
        let offsetMS: Double
        init(_ entry: Entry) {
            recording = entry.recording; candidateSHA256 = entry.candidateSHA256; offsetMS = entry.offsetMS
        }
        var key: PairKey { PairKey(trackID: recording.id, candidateSHA256: candidateSHA256) }
        var valid: Bool { Entry(recording: recording, candidateSHA256: candidateSHA256, offsetMS: offsetMS).valid }
    }
    private struct Stored: Codable {
        let schemaVersion: Int
        let entries: [Entry]
        var offsets: [PairOffset]? = nil
    }
    private struct CandidateIdentity: Encodable {
        struct Line: Encodable { let timestampMS: Double; let text: String }
        let source: String
        let sourceID: String
        let title: String
        let artist: String
        let album: String
        let durationMS: Int?
        let lines: [Line]
    }
    static let storageKey = "previewRecordingChoices.v1"
    static let maximumEntries = 200
    static let maximumOffsets = 200
    private(set) var entries: [Entry] = []
    private(set) var offsets: [PairOffset] = []
    private(set) var loadError: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            guard data.count <= 256 * 1024 else { throw LyricSourceError.responseTooLarge }
            let saved = try JSONDecoder().decode(Stored.self, from: data)
            guard saved.schemaVersion == 1 else { throw LyricSourceError.invalidResponse }
            try Self.validate(saved.entries, offsets: saved.offsets ?? [])
            entries = saved.entries
            offsets = saved.offsets ?? []
        } catch { loadError = L10n.text("Saved recording choices could not be read. No selection or offset restored; existing records were not deleted.") }
    }

    static func fingerprint(_ candidate: SongResult) -> String? {
        guard let source = candidate.sourceIdentity, !source.isEmpty, source.utf8.count <= 2048,
              let id = candidate.sourceSongID, !id.isEmpty, id.utf8.count <= 1024 else { return nil }
        let identity = CandidateIdentity(source: source, sourceID: id, title: candidate.songName, artist: candidate.artistName,
                                         album: candidate.albumName, durationMS: candidate.durationMS,
                                         lines: candidate.lyrics.map { .init(timestampMS: $0.startTimeMS, text: $0.words) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(identity) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func remember(_ candidate: SongResult, playback: PlaybackSnapshot, offsetMS: Double) -> Bool {
        let recording = Recording(playback)
        guard recording.valid, PreviewRecordingMatcher.eligibleForMemory(candidate, playback: playback),
              let fingerprint = Self.fingerprint(candidate), let version = VersionReference(candidate),
              offsetMS.isFinite, abs(offsetMS) <= 10000 else { return false }
        let entry = Entry(recording: recording, candidateSHA256: fingerprint, offsetMS: offsetMS,
                          version: version)
        var history = offsets
        // Preserve an older hash-only choice before changing its preferred version.
        if let previous = entries.first(where: { $0.recording.id == recording.id }) {
            let previousOffset = PairOffset(previous)
            if !history.contains(where: { $0.key == previousOffset.key }) { history.append(previousOffset) }
        }
        let pair = PairOffset(entry)
        history.removeAll { $0.key == pair.key }
        history.append(pair)
        return save(Array((entries.filter { $0.recording.id != recording.id } + [entry]).suffix(Self.maximumEntries)),
                    offsets: Array(history.suffix(Self.maximumOffsets)))
    }

    func restoration(in candidates: [SongResult], playback: PlaybackSnapshot) -> (id: UUID, offsetMS: Double)? {
        guard let entry = entry(for: playback) else { return nil }
        let matching = candidates.filter {
            (entry.version == nil || VersionReference($0) == entry.version)
                && PreviewRecordingMatcher.eligibleForMemory($0, playback: playback) && Self.fingerprint($0) == entry.candidateSHA256
        }
        guard matching.count == 1 else { return nil }
        return (matching[0].id, entry.offsetMS)
    }

    func entry(for playback: PlaybackSnapshot) -> Entry? {
        entries.first { $0.recording == Recording(playback) }
    }

    func offset(for candidate: SongResult, playback: PlaybackSnapshot) -> Double? {
        guard Recording(playback).valid, PreviewRecordingMatcher.eligibleForMemory(candidate, playback: playback),
              let fingerprint = Self.fingerprint(candidate) else { return nil }
        if let current = entry(for: playback), current.candidateSHA256 == fingerprint { return current.offsetMS }
        return offsets.first { $0.recording == Recording(playback) && $0.candidateSHA256 == fingerprint }?.offsetMS
    }

    @discardableResult
    func forget(_ trackID: String) -> Bool {
        save(entries.filter { $0.recording.id != trackID }, offsets: offsets.filter { $0.recording.id != trackID })
    }

    static func validate(_ entries: [Entry], offsets: [PairOffset]) throws {
        guard entries.count <= maximumEntries, entries.allSatisfy(\.valid),
              Set(entries.map { $0.recording.id }).count == entries.count,
              offsets.count <= maximumOffsets, offsets.allSatisfy(\.valid),
              Set(offsets.map(\.key)).count == offsets.count else { throw LyricSourceError.invalidResponse }
        let indexed = Dictionary(uniqueKeysWithValues: offsets.map { ($0.key, $0) })
        for entry in entries {
            let active = PairOffset(entry)
            if let stored = indexed[active.key], stored != active { throw LyricSourceError.invalidResponse }
        }
        guard try JSONEncoder().encode(Stored(schemaVersion: 1, entries: entries, offsets: offsets.isEmpty ? nil : offsets)).count <= 256 * 1024 else {
            throw LyricSourceError.responseTooLarge
        }
    }

    func replaceValidated(_ updated: [Entry], offsets updatedOffsets: [PairOffset]? = nil) throws {
        let history = updatedOffsets ?? []
        try Self.validate(updated, offsets: history)
        guard save(updated, offsets: history) else { throw LyricSourceError.invalidResponse }
    }

    private func save(_ updated: [Entry], offsets updatedOffsets: [PairOffset]) -> Bool {
        guard (try? Self.validate(updated, offsets: updatedOffsets)) != nil,
              let data = try? JSONEncoder().encode(Stored(schemaVersion: 1, entries: updated, offsets: updatedOffsets.isEmpty ? nil : updatedOffsets)) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        entries = updated; offsets = updatedOffsets; loadError = nil
        return true
    }
}
