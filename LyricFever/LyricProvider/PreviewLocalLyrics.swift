import Foundation
import CryptoKit

@MainActor
final class PreviewLocalLyrics {
    struct Import: Codable {
        let schemaVersion: Int
        let recording: PreviewRecordingPreferences.Recording
        let fileSHA256: String
        let lrc: Data
    }
    struct Entry: Identifiable {
        let filename: String
        let recording: PreviewRecordingPreferences.Recording
        let storedSHA256: String
        let bytes: Int
        let archived: Bool
        var id: String { (archived ? "archive/" : "active/") + filename }
    }
    struct Catalog {
        let entries: [Entry]
        let activeCount: Int
        let archivedCount: Int
        let activeBytes: Int
        let archivedBytes: Int
        let invalidCount: Int
    }
    var archiveDirectory: URL { directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-archive", isDirectory: true) }
    let directory: URL
    init(directory: URL) { self.directory = directory }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func prepare(_ data: Data, playback: PlaybackSnapshot) throws -> Import {
        let record = PreviewRecordingPreferences.Recording(playback)
        guard record.valid, data.count <= 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw LyricSourceError.invalidResponse }
        let parser = LyricsParser(lyrics: text)
        guard LyricFetchPipeline.isValid(parser.lyrics, durationMS: playback.durationMS), parser.lyrics.count <= 20000,
              parser.lyrics.allSatisfy({ $0.words.utf8.count <= 16384 }) else { throw LyricSourceError.invalidResponse }
        if let title = parser.header.title, !title.isEmpty,
           PreviewRecordingMatcher.normalized(title) != PreviewRecordingMatcher.normalized(playback.trackName) { throw LyricSourceError.invalidResponse }
        if let artist = parser.header.author, !artist.isEmpty,
           PreviewRecordingMatcher.artistRelation(artist, playback.artistName) != .normalized { throw LyricSourceError.invalidResponse }
        return Import(schemaVersion: 1, recording: record, fileSHA256: Self.digest(data), lrc: data)
    }
    private func path(_ id: String) -> URL { directory.appendingPathComponent(Self.digest(Data(id.utf8)) + ".json") }
    private func checkedDirectory() throws {
        if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw LyricSourceError.unsafeURL }
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw LyricSourceError.unsafeURL }
        } else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }
    func install(_ value: Import, current: PlaybackSnapshot) throws -> SongResult {
        guard value.recording == PreviewRecordingPreferences.Recording(current), value.fileSHA256 == Self.digest(value.lrc) else { throw FetchError.staleTrack }
        let checked = try prepare(value.lrc, playback: current)
        try checkedDirectory()
        let url = path(current.trackID)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw LyricSourceError.unsafeURL }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
        // Directory enumeration can canonicalize /tmp or attach a different URL base.
        let filename = url.lastPathComponent
        guard files.count < 200 || files.contains(where: { $0.lastPathComponent == filename }) else { throw LyricSourceError.sourceLimit }
        let total = try files.filter { $0.lastPathComponent != filename }.reduce(0) { sum, file in
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LyricSourceError.unsafeURL }
            return sum + (values.fileSize ?? 0)
        }
        let data = try JSONEncoder().encode(checked)
        guard total + data.count <= 32 * 1024 * 1024 else { throw LyricSourceError.responseTooLarge }
        try data.write(to: url, options: .atomic)
        return candidate(checked, playback: current)
    }
    func candidate(for playback: PlaybackSnapshot) throws -> SongResult? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try checkedDirectory()
        let url = path(playback.trackID)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw LyricSourceError.unsafeURL }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LyricSourceError.unsafeURL }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 2 * 1024 * 1024 else { throw LyricSourceError.responseTooLarge }
        let stored = try JSONDecoder().decode(Import.self, from: data)
        guard stored.schemaVersion == 1, stored.fileSHA256 == Self.digest(stored.lrc) else { throw LyricSourceError.invalidResponse }
        guard stored.recording == PreviewRecordingPreferences.Recording(playback) else { return nil }
        _ = try prepare(stored.lrc, playback: playback)
        return candidate(stored, playback: playback)
    }
    private func candidate(_ value: Import, playback: PlaybackSnapshot) -> SongResult {
        SongResult(lyricType: "本地 LRC", songName: playback.trackName, albumName: playback.albumName, artistName: playback.artistName,
                   lyrics: LyricsParser(lyrics: String(decoding: value.lrc, as: UTF8.self)).lyrics, durationMS: playback.durationMS,
                   sourceIdentity: "local-lrc:v1", sourceSongID: value.fileSHA256)
    }

    private func checkedFolder(_ url: URL, create: Bool = false) throws -> Bool {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw LyricSourceError.unsafeURL }
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw LyricSourceError.unsafeURL }
            return true
        }
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return create
    }
    private func files(in folder: URL) throws -> [URL] {
        guard try checkedFolder(folder) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard urls.count <= 200 else { throw LyricSourceError.sourceLimit }
        var bytes = 0
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw LyricSourceError.unsafeURL }
            bytes += values.fileSize ?? 0
        }
        guard bytes <= 32 * 1024 * 1024 else { throw LyricSourceError.responseTooLarge }
        return urls
    }
    private func read(_ url: URL) throws -> (Import, Data) {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw LyricSourceError.unsafeURL }
        guard (values.fileSize ?? 0) <= 2 * 1024 * 1024 else { throw LyricSourceError.responseTooLarge }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 2 * 1024 * 1024 else { throw LyricSourceError.responseTooLarge }
        let value = try JSONDecoder().decode(Import.self, from: data)
        guard value.schemaVersion == 1, value.recording.valid, value.lrc.count <= 1024 * 1024,
              value.fileSHA256 == Self.digest(value.lrc) else { throw LyricSourceError.invalidResponse }
        return (value, data)
    }
    func catalog() throws -> Catalog {
        var entries: [Entry] = [], invalid = 0, activeBytes = 0, archivedBytes = 0
        let active = try files(in: directory), archived = try files(in: archiveDirectory)
        for (urls, isArchive) in [(active, false), (archived, true)] {
            for url in urls {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if isArchive { archivedBytes += size } else { activeBytes += size }
                do {
                    let (value, data) = try read(url)
                    let name = path(value.recording.id).lastPathComponent
                    guard isArchive ? Self.validArchiveName(url.lastPathComponent, suffix: name) : url.lastPathComponent == name else { throw LyricSourceError.invalidResponse }
                    entries.append(Entry(filename: url.lastPathComponent, recording: value.recording, storedSHA256: Self.digest(data), bytes: data.count, archived: isArchive))
                } catch { invalid += 1 }
            }
        }
        entries.sort { ($0.archived ? "1" : "0") + $0.recording.title + $0.filename < ($1.archived ? "1" : "0") + $1.recording.title + $1.filename }
        return Catalog(entries: entries, activeCount: active.count, archivedCount: archived.count, activeBytes: activeBytes, archivedBytes: archivedBytes, invalidCount: invalid)
    }
    private static func validArchiveName(_ name: String, suffix: String) -> Bool {
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil && String(parts[1]) == suffix
    }
    private func validated(_ entry: Entry) throws -> (URL, Import, Data) {
        let name = path(entry.recording.id).lastPathComponent
        guard entry.archived ? Self.validArchiveName(entry.filename, suffix: name) : entry.filename == name else { throw LyricSourceError.unsafeURL }
        let folder = entry.archived ? archiveDirectory : directory
        guard try checkedFolder(folder) else { throw LyricSourceError.invalidResponse }
        let url = folder.appendingPathComponent(entry.filename)
        let (value, data) = try read(url)
        guard Self.digest(data) == entry.storedSHA256, value.recording == entry.recording else { throw FetchError.staleTrack }
        return (url, value, data)
    }
    private func room(in folder: URL, adding bytes: Int) throws {
        let urls = try files(in: folder)
        guard urls.count < 200 else { throw LyricSourceError.sourceLimit }
        let total = try urls.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard total + bytes <= 32 * 1024 * 1024 else { throw LyricSourceError.responseTooLarge }
    }
    func archive(_ entry: Entry) throws {
        guard !entry.archived else { throw LyricSourceError.invalidResponse }
        let (url, _, data) = try validated(entry)
        try room(in: archiveDirectory, adding: data.count)
        _ = try checkedFolder(archiveDirectory, create: true)
        try FileManager.default.moveItem(at: url, to: archiveDirectory.appendingPathComponent(UUID().uuidString + "_" + entry.filename))
    }
    func restore(_ entry: Entry) throws {
        guard entry.archived else { throw LyricSourceError.invalidResponse }
        let (url, value, data) = try validated(entry)
        let r = value.recording
        _ = try prepare(value.lrc, playback: .init(trackID: r.id, trackName: r.title, artistName: r.artist, albumName: r.album,
                                                  durationMS: r.durationMS, positionMS: 0, isPlaying: false))
        let target = path(r.id)
        guard (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw LyricSourceError.unsafeURL }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw LyricSourceError.invalidResponse }
        try room(in: directory, adding: data.count)
        _ = try checkedFolder(directory, create: true)
        try FileManager.default.moveItem(at: url, to: target)
    }
}
