// LyricsParser.swift
// Original parser by Scott Rong, 2017. Copyright Scott Rong.

import Foundation

public class LyricsParser {
    public var header = LyricsHeader()
    var lyrics: [LyricLine] = []

    public init(lyrics text: String) {
        var input = text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        if input.hasPrefix("\""), input.hasSuffix("\""), input.count >= 2 {
            input.removeFirst()
            input.removeLast()
        }
        for rawLine in input.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if parseHeader(line) { continue }
            parseLine(line)
        }

        // Offset is in milliseconds and applies to all lines, even when declared last.
        lyrics = lyrics.enumerated().compactMap { index, line -> (Int, LyricLine)? in
            let time = line.startTimeMS + header.offset
            guard time.isFinite, time >= 0, time <= 86_400_000 else { return nil }
            return (index, LyricLine(startTime: time, words: line.words))
        }.sorted {
            $0.1.startTimeMS == $1.1.startTimeMS ? $0.0 < $1.0 : $0.1.startTimeMS < $1.1.startTimeMS
        }.map { $0.1 }
    }

    private func parseHeader(_ line: String) -> Bool {
        guard line.hasPrefix("["), line.hasSuffix("]"), let colon = line.firstIndex(of: ":") else { return false }
        let key = String(line[line.index(after: line.startIndex)..<colon])
        let value = String(line[line.index(after: colon)..<line.index(before: line.endIndex)])
        switch key {
        case "ti": header.title = value
        case "ar": header.author = value
        case "al": header.album = value
        case "by": header.by = value
        case "re": header.editor = value
        case "ve": header.version = value
        case "offset":
            if let offset = Double(value), offset.isFinite, abs(offset) <= 86_400_000 {
                header.offset = offset
            }
        default: return false
        }
        return true
    }

    private func parseLine(_ line: String) {
        var remaining = line
        var times: [Double] = []
        while remaining.hasPrefix("["), let close = remaining.firstIndex(of: "]") {
            let tag = String(remaining[remaining.index(after: remaining.startIndex)..<close])
            guard let time = timestamp(tag) else { break }
            times.append(time)
            remaining = String(remaining[remaining.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        guard !times.isEmpty else { return }
        let words = removingWordTimestamps(from: remaining)
        lyrics += times.map { LyricLine(startTime: $0, words: words) }
    }

    private func removingWordTimestamps(from text: String) -> String {
        guard text.contains("<") else { return text }
        var words = String()
        words.reserveCapacity(text.utf8.count)
        var literalStart = text.startIndex
        var tagStart: String.Index?
        for index in text.indices {
            switch text[index] {
            case "<": tagStart = index
            case ">":
                if let start = tagStart, timestamp(String(text[text.index(after: start)..<index])) != nil {
                    // Enhanced LRC word tags are metadata; the outer line time remains authoritative.
                    words.append(contentsOf: text[literalStart..<start])
                    literalStart = text.index(after: index)
                }
                tagStart = nil
            default: break
            }
        }
        words.append(contentsOf: text[literalStart...])
        return words
    }

    private func timestamp(_ tag: String) -> Double? {
        let parts = tag.components(separatedBy: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let wholeParts = parts.dropLast()
        guard wholeParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let minute = Double(parts[parts.count - 2]),
              let last = parts.last,
              let second = Double(last),
              last.range(of: #"^\d{1,2}(\.\d{1,3})?$"#, options: .regularExpression) != nil,
              second < 60 else { return nil }
        let hour = parts.count == 3 ? Double(parts[0]) ?? .infinity : 0
        guard parts.count == 2 || minute < 60 else { return nil }
        let time = ((hour * 3600 + minute * 60 + second) * 1000).rounded()
        guard time.isFinite, time >= 0, time <= 86_400_000 else { return nil }
        return time
    }
}
