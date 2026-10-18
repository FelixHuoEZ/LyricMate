#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
import Foundation

enum PlatformLyricSource: String, CaseIterable, Sendable {
    case kugou, netease, kuwo, qqMusic, migu

    var format: LyricSourceFormat { LyricSourceFormat(rawValue: rawValue)! }
    var name: String {
        switch self {
        case .kugou: return L10n.text("Kugou")
        case .netease: return L10n.text("NetEase Cloud Music")
        case .kuwo: return L10n.text("Kuwo Music")
        case .qqMusic: return L10n.text("QQ Music")
        case .migu: return L10n.text("Migu Music")
        }
    }
    var baseURL: String {
        switch self {
        case .kugou: return "https://songsearch.kugou.com/"
        case .netease: return "https://music.163.com/"
        case .kuwo: return "https://search.kuwo.cn/"
        case .qqMusic: return "https://c.y.qq.com/"
        case .migu: return "https://app.c.nf.migu.cn/"
        }
    }
    var manifest: LyricSourceManifest {
        .init(schemaVersion: 1, apiVersion: 1, name: name, baseURL: baseURL,
              capabilities: ["search", "syncedLyrics"], auth: .init(type: "none"), format: format)
    }
    var domains: String {
        switch self {
        case .kugou: return "songsearch.kugou.com · lyrics.kugou.com"
        case .netease: return "music.163.com"
        case .kuwo: return "search.kuwo.cn · m.kuwo.cn"
        case .qqMusic: return "c.y.qq.com"
        case .migu: return "app.c.nf.migu.cn · d.musicapp.migu.cn"
        }
    }
}

enum PlatformLyricError: Error, LocalizedError, Equatable {
    case businessStatus(Int)
    case untimedLyrics
    var errorDescription: String? {
        switch self {
        case .businessStatus(let code): return L10n.text("The platform returned error %1$@. This does not mean lyrics are unavailable.", String(describing: code))
        case .untimedLyrics: return L10n.text("Skipped a candidate without timing data; other candidates and sources are unaffected.")
        }
    }
}

// Public, anonymous lyric endpoints only. No audio URLs, cookies, scripts, or account keys.
@MainActor
final class PlatformLyricAPI {
    let source: PlatformLyricSource
    private let client: LyricHTTPClient
    private var discovered: [String: HTTPSourceSong] = [:]
    private var lyricURLs: [String: URL] = [:]

    init(source: PlatformLyricSource, client: LyricHTTPClient) {
        self.source = source
        self.client = client
    }

    private func url(_ base: String, _ path: String, _ query: [(String, String)]) throws -> URL {
        guard var parts = URLComponents(string: base + path) else { throw LyricSourceError.unsafeURL }
        parts.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = parts.url else { throw LyricSourceError.unsafeURL }
        return url
    }

    private func json(_ url: URL, referer: String? = nil, htmlLabel: Bool = false) async throws -> [String: Any] {
        var types: Set<String> = ["application/json", "text/plain", "text/javascript", "application/javascript"]
        if source == .qqMusic { types.insert("application/x-javascript") }
        // Some fixed endpoints label JSON as HTML/JS; only JSON objects are decoded, never executed.
        if htmlLabel { types.insert("text/html") }
        let data = try await client.get(url, mimeTypes: types, referer: referer)
        try Task.checkCancellation()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricSourceError.invalidResponse
        }
        return object
    }

    private func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }
    private func number(_ value: Any?) -> Double? { text(value).flatMap(Double.init) }
    private func strings(_ value: Any?) -> String {
        (value as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: "、")
    }
    private func validID(_ id: String) -> Bool {
        let pattern = source == .kugou ? #"^[a-fA-F0-9]{32}$"# : source == .qqMusic ? #"^[A-Za-z0-9]{1,64}$"# : #"^[0-9]{1,20}$"#
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    func candidates(track: String, artist: String) async throws -> [HTTPSourceSong] {
        discovered = [:]
        lyricURLs = [:]
        let query = [track, artist].filter { !$0.isEmpty }.joined(separator: " ")
        let root: [String: Any]
        let rows: [[String: Any]]
        switch source {
        case .migu:
            root = try await json(url(source.baseURL, "MIGUM2.0/v1.0/content/search_all.do", [("text", query),
                ("pageNo", "1"), ("pageSize", "5"), ("searchSwitch", "{\"song\":1}")]))
            guard root["code"] as? String == "000000", let result = root["songResultData"] as? [String: Any],
                  let values = result["result"] as? [[String: Any]] else { throw LyricSourceError.invalidResponse }
            rows = values
        case .netease:
            root = try await json(url(source.baseURL, "api/search/get", [("s", query), ("type", "1"), ("limit", "5"), ("offset", "0")]))
            guard number(root["code"]) == 200 else { throw LyricSourceError.invalidResponse }
            let result = root["result"] as? [String: Any] ?? [:]
            rows = result["songs"] as? [[String: Any]] ?? []
            guard result["songs"] != nil || number(result["songCount"]) == 0 else { throw LyricSourceError.invalidResponse }
        case .kugou:
            root = try await json(url(source.baseURL, "song_search_v2", [("keyword", query), ("platform", "AndroidFilter"),
                ("iscorrection", "1"), ("hifiquality", "0"), ("pagesize", "5"), ("PrivilegeFilter", "0"), ("page", "1")]))
            guard number(root["error_code"]) == 0, let data = root["data"] as? [String: Any],
                  let values = data["lists"] as? [[String: Any]] else { throw LyricSourceError.invalidResponse }
            rows = values
        case .kuwo:
            root = try await json(url(source.baseURL, "r.s", [("all", query), ("client", "kt"), ("pn", "0"), ("rn", "5"),
                ("ver", "kwplayer_ar_9.2.2.1"), ("vipver", "1"), ("show_copyright_off", "1"), ("newver", "1"),
                ("ft", "music"), ("cluster", "0"), ("strategy", "2012"), ("encoding", "utf8"), ("rformat", "json"),
                ("vermerge", "1"), ("mobi", "1"), ("issubtitle", "1")]))
            guard number(root["TOTAL"]) != nil, let values = root["abslist"] as? [[String: Any]] else {
                throw LyricSourceError.invalidResponse
            }
            rows = values
        case .qqMusic:
            root = try await json(url(source.baseURL, "soso/fcgi-bin/client_search_cp", [("w", query), ("p", "1"), ("n", "5"), ("format", "json")]), referer: "https://y.qq.com/")
            guard number(root["code"]) == 0, let data = root["data"] as? [String: Any],
                  let song = data["song"] as? [String: Any], let values = song["list"] as? [[String: Any]] else {
                throw LyricSourceError.invalidResponse
            }
            rows = values
        }
        var songs: [HTTPSourceSong] = []
        for row in rows.prefix(5) {
            let song: HTTPSourceSong
            switch source {
            case .migu:
                song = .init(id: text(row["id"]) ?? "", trackName: row["name"] as? String ?? "", artistName: strings(row["singers"]),
                             albumName: (row["albums"] as? [[String: Any]])?.first?["name"] as? String,
                             durationMs: nil, hasSyncedLyrics: (row["lyricUrl"] as? String)?.isEmpty == false)
                if song.hasSyncedLyrics {
                    guard let value = row["lyricUrl"] as? String, let address = Self.miguLyricURL(value) else { throw LyricSourceError.unsafeURL }
                    lyricURLs[song.id] = address
                }
            case .netease:
                song = .init(id: text(row["id"]) ?? "", trackName: row["name"] as? String ?? "", artistName: strings(row["artists"]),
                             albumName: (row["album"] as? [String: Any])?["name"] as? String,
                             durationMs: number(row["duration"]), hasSyncedLyrics: true)
            case .kugou:
                let title = row["SongName"] as? String ?? [row["OriSongName"] as? String, row["Suffix"] as? String].compactMap { $0 }.joined(separator: " ")
                song = .init(id: text(row["FileHash"]) ?? "", trackName: title, artistName: strings(row["Singers"]),
                             albumName: row["AlbumName"] as? String, durationMs: number(row["Duration"]).map { $0 * 1000 }, hasSyncedLyrics: true)
            case .kuwo:
                song = .init(id: (text(row["MUSICRID"]) ?? "").replacingOccurrences(of: "MUSIC_", with: ""),
                             trackName: row["SONGNAME"] as? String ?? "", artistName: (row["ARTIST"] as? String ?? "").replacingOccurrences(of: "&", with: "、"),
                             albumName: row["ALBUM"] as? String, durationMs: number(row["DURATION"]).map { $0 * 1000 }, hasSyncedLyrics: true)
            case .qqMusic:
                song = .init(id: text(row["songmid"]) ?? "", trackName: row["songname"] as? String ?? "", artistName: strings(row["singer"]),
                             albumName: row["albumname"] as? String, durationMs: number(row["interval"]).map { $0 * 1000 }, hasSyncedLyrics: true)
            }
            guard song.isValid, validID(song.id) else { throw LyricSourceError.invalidResponse }
            if discovered[song.id] == nil { songs.append(song); discovered[song.id] = song }
        }
        return songs
    }

    func lyrics(for song: HTTPSourceSong) async throws -> [LyricLine] {
        guard validID(song.id), let known = discovered[song.id], known.trackName == song.trackName,
              known.artistName == song.artistName, known.durationMs == song.durationMs else { throw LyricSourceError.invalidResponse }
        let root: [String: Any]
        let lrc: String
        switch source {
        case .migu:
            guard let address = lyricURLs[song.id] else { return [] }
            // The fixed CDN sometimes omits Content-Type; still require bounded UTF-8 LRC, never HTML.
            let data = try await client.get(address, mimeTypes: ["text/plain", "application/octet-stream"], allowMissingContentType: true)
            return try Self.miguLyrics(data)
        case .netease:
            root = try await json(url(source.baseURL, "api/song/lyric", [("id", song.id), ("lv", "-1"), ("tv", "-1"), ("kv", "-1")]))
            guard number(root["code"]) == 200 else { throw LyricSourceError.invalidResponse }
            if root["nolyric"] as? Bool == true || root["uncollected"] as? Bool == true { return [] }
            lrc = (root["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        case .qqMusic:
            root = try await json(url(source.baseURL, "lyric/fcgi-bin/fcg_query_lyric_new.fcg", [("songmid", song.id), ("format", "json"), ("nobase64", "1")]), referer: "https://y.qq.com/portal/player.html", htmlLabel: true)
            guard number(root["code"]) == 0, let value = root["lyric"] as? String else { throw LyricSourceError.invalidResponse }
            lrc = Self.decodeEntities(value)
        case .kuwo:
            let address = try url("https://m.kuwo.cn/", "newh5/singles/songinfoandlrc", [("musicId", song.id)])
            let initial = try await json(address, htmlLabel: true)
            // Only this known query failure is retried; never authentication, access or rate-limit errors.
            if number(initial["status"]) == 301, initial["msg"] as? String == "音乐查询失败" {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                root = try await json(address, htmlLabel: true)
            } else { root = initial }
            if let code = number(root["status"]), code.isFinite, code >= 0, code <= 999999, code != 200 {
                throw PlatformLyricError.businessStatus(Int(code))
            }
            guard number(root["status"]) == 200, let data = root["data"] as? [String: Any],
                  let info = data["songinfo"] as? [String: Any], text(info["id"]) == song.id else { throw LyricSourceError.invalidResponse }
            if let artist = info["artist"] as? String, !artist.isEmpty,
               PreviewRecordingMatcher.artistRelation(artist.replacingOccurrences(of: "&", with: "、"), song.artistName) != .normalized { throw LyricSourceError.invalidResponse }
            guard let rows = data["lrclist"] as? [[String: Any]] else { return [] }
            guard rows.count <= 10000 else { throw LyricSourceError.responseTooLarge }
            let lines = try rows.map { row -> LyricLine in
                guard let seconds = number(row["time"]), seconds.isFinite, seconds >= 0, seconds <= 86400,
                      let words = row["lineLyric"] as? String else { throw LyricSourceError.invalidResponse }
                return LyricLine(startTime: (seconds * 1000).rounded(), words: words)
            }.sorted { $0.startTimeMS < $1.startTimeMS }
            try Task.checkCancellation()
            return lines
        case .kugou:
            let index = try await json(url("https://lyrics.kugou.com/", "search", [("ver", "1"), ("man", "yes"), ("client", "pc"),
                ("keyword", song.trackName), ("hash", song.id), ("timelength", String(Int((song.durationMs ?? 0) / 1000))), ("lrctxt", "1")]))
            guard number(index["status"]) == 200, let candidates = index["candidates"] as? [[String: Any]] else { throw LyricSourceError.invalidResponse }
            guard let candidate = candidates.prefix(40).first(where: {
                number($0["krctype"]) == 2 && number($0["contenttype"]) == 0
                    && PreviewRecordingMatcher.normalized($0["song"] as? String ?? "") == PreviewRecordingMatcher.normalized(song.trackName)
                    && PreviewRecordingMatcher.artistRelation($0["singer"] as? String ?? "", song.artistName) == .normalized
                    && number($0["duration"]).map { abs($0 - (song.durationMs ?? -10000)) <= 2000 } == true
            }) else { return [] }
            guard let id = text(candidate["id"]), id.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil,
                  let key = candidate["accesskey"] as? String, key.range(of: #"^[a-fA-F0-9]{1,128}$"#, options: .regularExpression) != nil else { throw LyricSourceError.invalidResponse }
            // The anonymous per-lyric key stays in this request, never in saved song identity or diagnostics.
            root = try await json(url("https://lyrics.kugou.com/", "download", [("ver", "1"), ("client", "pc"), ("id", id),
                ("accesskey", key), ("fmt", "lrc"), ("charset", "utf8")]))
            guard number(root["status"]) == 200, root["fmt"] as? String == "lrc", let value = root["content"] as? String,
                  let decoded = Data(base64Encoded: value), let value = String(data: decoded, encoding: .utf8) else { throw LyricSourceError.invalidResponse }
            lrc = value
        }
        guard lrc.utf8.count <= 1024 * 1024 else { throw LyricSourceError.responseTooLarge }
        try Task.checkCancellation()
        return LyricsParser(lyrics: lrc).lyrics
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result), let valueRange = Range(match.range(at: 1), in: result) else { continue }
                let token = String(result[valueRange])
                let number = token.hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
                if let number, let scalar = UnicodeScalar(number) { result.replaceSubrange(range, with: String(scalar)) }
            }
        }
        for (entity, value) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }

    static func miguLyrics(_ data: Data) throws -> [LyricLine] {
        guard data.count <= 1024 * 1024 else { throw LyricSourceError.responseTooLarge }
        guard let raw = String(data: data, encoding: .utf8) else { throw LyricSourceError.invalidResponse }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        let hasMiguHeader = value.hasPrefix("@migu music@")
        if hasMiguHeader { value = String(value.dropFirst("@migu music@".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !value.isEmpty, !value.hasPrefix("<"), !value.hasPrefix("{"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw LyricSourceError.invalidResponse
        }
        guard hasMiguHeader || value.hasPrefix("[") else { throw LyricSourceError.invalidResponse }
        let lines = LyricsParser(lyrics: value).lyrics
        if !lines.isEmpty { return lines }
        // A known plain-text lyric header is not proof of a timing track. Do not invent timestamps.
        let packed = value.filter { !$0.isWhitespace }
        let looksEncoded = packed.count >= 128 && packed.range(of: #"^[A-Za-z0-9+/=]+$"#, options: .regularExpression) != nil
        if hasMiguHeader, !value.hasPrefix("["), !looksEncoded {
            throw PlatformLyricError.untimedLyrics
        }
        throw LyricSourceError.invalidResponse
    }

    static func miguLyricURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme == "https", parts.host == "d.musicapp.migu.cn",
              parts.port == nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == parts.path, !parts.path.contains(".."),
              parts.path.range(of: #"^/(?:prod/file-service/file-down|data/oss/resource)/[A-Za-z0-9/_\-.]+$"#, options: .regularExpression) != nil else { return nil }
        return parts.url
    }
}
