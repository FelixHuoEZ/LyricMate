import Foundation

struct AMLLIndexEntry: Decodable, Sendable {
    struct Pair: Decodable, Sendable {
        let key: String
        let values: [String]
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            key = try c.decode(String.self); values = try c.decode([String].self)
            guard c.isAtEnd else { throw LyricSourceError.invalidResponse }
        }
    }
    let id: String
    let metadata: [Pair]
    let rawLyricFile: String
    func values(_ key: String) -> [String] { metadata.filter { $0.key == key }.flatMap(\.values) }
    var valid: Bool {
        id.range(of: #"^[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil
            && rawLyricFile.range(of: #"^\d{10,16}-\d{1,20}-[A-Za-z0-9]{8}\.ttml$"#, options: .regularExpression) != nil
            && metadata.count <= 64 && metadata.allSatisfy { $0.values.count <= 64 && $0.values.allSatisfy { $0.utf8.count <= 2048 } }
            && !values("musicName").isEmpty && !values("artists").isEmpty && values("spotifyId").contains(id)
    }
}

final class PreviewTTMLParser: NSObject, XMLParserDelegate {
    private var lines: [LyricLine] = []
    private var metadata: [String: [String]] = [:]
    private var start: Double?
    private var end: Double?
    private var text = ""
    private var inLine = false
    private var skipDepth = 0
    private var failed = false
    private var depth = 0
    private var metaCount = 0

    static func parse(_ data: Data, spotifyID: String) throws -> [LyricLine] {
        guard data.count <= 1024 * 1024, let xml = String(data: data, encoding: .utf8),
              xml.range(of: #"<!\s*(DOCTYPE|ENTITY)"#, options: [.regularExpression, .caseInsensitive]) == nil else { throw LyricSourceError.invalidResponse }
        let delegate = PreviewTTMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.failed, delegate.metadata["spotifyId"]?.contains(spotifyID) == true else { throw LyricSourceError.invalidResponse }
        let lines = delegate.lines.sorted { $0.startTimeMS < $1.startTimeMS }
        guard !lines.isEmpty else { throw LyricSourceError.invalidResponse }
        return lines
    }
    private func time(_ value: String?) -> Double? {
        guard let value else { return nil }
        if value.hasSuffix("s"), let seconds = Double(value.dropLast()), seconds.isFinite, seconds >= 0, seconds <= 86400 { return seconds * 1000 }
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3,
              let seconds = Double(parts.last!), seconds.isFinite, seconds >= 0, seconds < 60,
              let minutes = Int(parts[parts.count - 2]), minutes >= 0, parts.count == 2 || minutes < 60 else { return nil }
        let hours = parts.count == 3 ? Int(parts[0]) : 0
        guard let hours, hours >= 0, hours <= 24, minutes <= 1440 else { return nil }
        let result = Double(hours * 3600 + minutes * 60) * 1000 + seconds * 1000
        return result <= 86_400_000 ? result : nil
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        depth += 1
        guard depth <= 64, depth != 1 || (name == "tt" && namespaceURI == "http://www.w3.org/ns/ttml") else {
            failed = true; parser.abortParsing(); return
        }
        if name == "meta", let key = a["key"], let value = a["value"] {
            metaCount += 1
            guard metaCount <= 256, key.utf8.count <= 128, value.utf8.count <= 2048 else { failed = true; parser.abortParsing(); return }
            metadata[key, default: []].append(value)
        }
        if skipDepth > 0 { skipDepth += 1; return }
        if a.contains(where: { $0.key.hasSuffix("role") && ["x-translation", "x-roman", "x-bg"].contains($0.value) }) { skipDepth = 1; return }
        if name == "p" {
            if inLine { failed = true }
            inLine = true; start = time(a["begin"]); end = time(a["end"]); text = ""
        }
        if inLine && name == "br" { text += " " }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inLine && skipDepth == 0 {
            text += string
            if text.utf8.count > 16384 { failed = true; parser.abortParsing() }
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if skipDepth > 0 { skipDepth -= 1; return }
        if name == "p" && inLine {
            defer { inLine = false }
            guard let start, let end, end >= start, lines.count < 20000 else { failed = true; return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { lines.append(.init(startTime: start, words: value)) }
        }
    }
}

@MainActor
final class AMLLSource {
    nonisolated static let baseURL = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/"
    private let client: LyricHTTPClient
    private var index: [AMLLIndexEntry]?
    private var indexFailure: Error?
    init(client: LyricHTTPClient) { self.client = client }

    static func decodeIndex(_ data: Data) throws -> [AMLLIndexEntry] {
        guard data.count <= 8 * 1024 * 1024, let string = String(data: data, encoding: .utf8) else { throw LyricSourceError.responseTooLarge }
        let rows = string.split(separator: "\n")
        guard rows.count <= 20000 else { throw LyricSourceError.responseTooLarge }
        var latest: [String: AMLLIndexEntry] = [:]
        for row in rows {
            guard row.utf8.count <= 32768 else { throw LyricSourceError.responseTooLarge }
            let entry = try JSONDecoder().decode(AMLLIndexEntry.self, from: Data(row.utf8))
            if entry.valid { latest[entry.id] = entry }
        }
        return latest.values.sorted { $0.id < $1.id }
    }
    private func entries() async throws -> [AMLLIndexEntry] {
        if let index { return index }
        if let indexFailure { throw indexFailure }
        do {
            let data = try await client.get(URL(string: Self.baseURL + "spotify-lyrics/index.jsonl")!, maximumBytes: 8 * 1024 * 1024,
                                            mimeTypes: ["text/plain", "application/json", "application/octet-stream"])
            let parsed = try Self.decodeIndex(data); index = parsed; return parsed
        } catch {
            if !(error is CancellationError) { indexFailure = error }
            throw error
        }
    }
    static func recordingID(_ uri: String?) -> String? {
        guard let uri, uri.hasPrefix("spotify:track:") else { return nil }
        let id = String(uri.dropFirst("spotify:track:".count))
        return id.count == 22 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) } ? id : nil
    }
    func candidates(track: String, artist: String, spotifyTrackID: String? = nil) async throws -> [HTTPSourceSong] {
        let all = try await entries()
        let exact = Self.recordingID(spotifyTrackID).flatMap { id in all.first { $0.id == id } }
        // A contradictory ID entry must not silently become a different recording.
        let matched = (exact.map { [$0] } ?? all).filter { entry in
            entry.values("musicName").contains { PreviewRecordingMatcher.normalized($0) == PreviewRecordingMatcher.normalized(track) }
                && (artist.isEmpty || (exact != nil
                    ? PreviewRecordingMatcher.artistRelation(entry.values("artists").joined(separator: "、"), artist) == .normalized
                    : PreviewRecordingMatcher.artistRelation(entry.values("artists").joined(separator: "、"), artist) != nil))
        }
        // One file per search; no claims about unknown recording duration or platform equivalence.
        return matched.prefix(1).map {
            HTTPSourceSong(id: $0.id, trackName: $0.values("musicName").first(where: { PreviewRecordingMatcher.normalized($0) == PreviewRecordingMatcher.normalized(track) }) ?? track,
                           artistName: $0.values("artists").joined(separator: "、"), albumName: $0.values("album").joined(separator: " / "),
                           durationMs: nil, hasSyncedLyrics: true)
        }
    }
    func lyrics(id: String) async throws -> [LyricLine] {
        guard let entry = try await entries().first(where: { $0.id == id }) else { throw LyricSourceError.invalidResponse }
        let data = try await client.get(URL(string: Self.baseURL + "raw-lyrics/" + entry.rawLyricFile)!,
                                        mimeTypes: ["text/plain", "application/xml", "text/xml", "application/octet-stream"])
        return try PreviewTTMLParser.parse(data, spotifyID: id)
    }
}
