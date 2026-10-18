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
    struct Entry: Codable {
        let recording: Recording
        let candidateSHA256: String
        let offsetMS: Double
        var valid: Bool {
            recording.valid && candidateSHA256.count == 64
                && candidateSHA256.allSatisfy { "0123456789abcdef".contains($0) }
                && offsetMS.isFinite && abs(offsetMS) <= 10000
        }
    }
    private struct Stored: Codable { let schemaVersion: Int; let entries: [Entry] }
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
    private(set) var entries: [Entry] = []
    private(set) var loadError: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            guard data.count <= 256 * 1024 else { throw LyricSourceError.responseTooLarge }
            let saved = try JSONDecoder().decode(Stored.self, from: data)
            guard saved.schemaVersion == 1, saved.entries.count <= Self.maximumEntries,
                  saved.entries.allSatisfy(\.valid), Set(saved.entries.map { $0.recording.id }).count == saved.entries.count else {
                throw LyricSourceError.invalidResponse
            }
            entries = saved.entries
        } catch { loadError = "录音记忆无法读取；未恢复任何选择或偏移，原记录未删除。" }
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
              let fingerprint = Self.fingerprint(candidate), offsetMS.isFinite, abs(offsetMS) <= 10000 else { return false }
        let entry = Entry(recording: recording, candidateSHA256: fingerprint, offsetMS: offsetMS)
        return save(Array((entries.filter { $0.recording.id != recording.id } + [entry]).suffix(Self.maximumEntries)))
    }

    func restoration(in candidates: [SongResult], playback: PlaybackSnapshot) -> (id: UUID, offsetMS: Double)? {
        guard let entry = entries.first(where: { $0.recording == Recording(playback) }) else { return nil }
        let matching = candidates.filter {
            PreviewRecordingMatcher.eligibleForMemory($0, playback: playback) && Self.fingerprint($0) == entry.candidateSHA256
        }
        guard matching.count == 1 else { return nil }
        return (matching[0].id, entry.offsetMS)
    }

    func forget(_ trackID: String) { _ = save(entries.filter { $0.recording.id != trackID }) }

    func replaceValidated(_ updated: [Entry]) throws {
        guard updated.count <= Self.maximumEntries, updated.allSatisfy(\.valid),
              Set(updated.map { $0.recording.id }).count == updated.count, save(updated) else { throw LyricSourceError.invalidResponse }
    }

    private func save(_ updated: [Entry]) -> Bool {
        guard let data = try? JSONEncoder().encode(Stored(schemaVersion: 1, entries: updated)), data.count <= 256 * 1024 else { return false }
        defaults.set(data, forKey: Self.storageKey)
        entries = updated; loadError = nil
        return true
    }
}
