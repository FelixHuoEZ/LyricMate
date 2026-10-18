import AppKit
import CoreText
import NaturalLanguage

struct PreviewWrappedLine: Equatable {
    let fragments: [String]
    let fontSize: Double
    let needsDisclosure: Bool
    var lineHeight: Double { ceil(fontSize * 1.45) }
}

struct PreviewFloatingTextMetrics: Equatable {
    var width = 720.0
    var fontSize = 30.0
    var rows = 1
    var textWidth: Double { max(1, width - PreviewFloatingLayoutPolicy.horizontalChrome) }
    var blockHeight: Double { ceil(fontSize * 1.45) * Double(rows) }
    var nextScale: Double { max(16, fontSize * 0.72) / fontSize }
    var stride: Double { blockHeight + 5 }
    func viewportHeight(showsNextLine: Bool) -> Double {
        blockHeight + (showsNextLine ? blockHeight * nextScale + 5 : 0)
    }
}

/// Uses native Unicode line-break opportunities; word tokenization is only a soft preference.
enum PreviewLyricWrapping {
    static func font(_ size: Double) -> NSFont {
        NSFont(name: "AvenirNext-DemiBold", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }

    static func attributed(_ text: String, size: Double) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font(size)])
    }

    static func width(_ text: String, size: Double) -> Double {
        let line = CTLineCreateWithAttributedString(attributed(text, size: size))
        return max(0, CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
    }

    static func wrap(_ text: String, fontSize: Double, width: Double) -> PreviewWrappedLine {
        let size = fontSize.isFinite ? min(48, max(20, fontSize)) : 30
        let available = width.isFinite ? max(1, width) : 632
        // The display projection is already bounded. Keep this entry point bounded as well.
        let bounded = String(text.prefix(400))
        let overflow = text.count > 400
        for scale in [1.0, 0.85] {
            let actual = size * scale
            if let lines = split(bounded, size: actual, width: available) {
                return PreviewWrappedLine(fragments: lines, fontSize: actual, needsDisclosure: overflow)
            }
        }
        let actual = size * 0.85
        let fragments = split(bounded, size: actual, width: available, allowPartial: true)
            ?? (Self.width("…", size: actual) <= available ? ["…"] : [])
        return PreviewWrappedLine(fragments: fragments, fontSize: actual, needsDisclosure: true)
    }

    private static func split(_ text: String, size: Double, width: Double, allowPartial: Bool = false) -> [String]? {
        if Self.width(text, size: size) <= width { return [text] }
        let ns = text as NSString
        let length = ns.length
        let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: length),
                                               kCFStringTokenizerUnitLineBreak, nil)
        var legal = Set<Int>([length])
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            legal.insert(range.location + range.length)
        }
        var graphemes: [Int] = []
        var cursor = 0
        while cursor < length {
            cursor = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: cursor))
            graphemes.append(cursor)
        }
        legal.formIntersection(graphemes)
        let opening = Set("（([{〈《「『【〔〖‘“")
        let closing = Set("）)]}〉》」』】〕〗、，。！？；：,.!?;:’”%％")
        func allowed(_ end: Int) -> Bool {
            guard end < length else { return true }
            let before = ns.substring(to: end).last!
            let after = ns.substring(from: end).first!
            if opening.contains(before) || closing.contains(after) { return false }
            if before.isNumber && (after.isNumber || "年月日时分秒点元米克度%％".contains(after)) { return false }
            return true
        }
        legal = legal.filter(allowed)
        let words = NLTokenizer(unit: .word)
        words.string = text
        var wordEnds = Set<Int>()
        words.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            wordEnds.insert(NSRange(range, in: text).upperBound)
            return true
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed(text, size: size))
        var measured: [Range<Int>: Double] = [:]
        func measure(_ start: Int, _ end: Int) -> Double {
            let key = start..<end
            if let cached = measured[key] { return cached }
            let result = Self.width(ns.substring(with: NSRange(location: start, length: end - start)), size: size)
            measured[key] = result
            return result
        }
        func ends(_ start: Int) -> [Int] {
            let fit = min(length, start + CTTypesetterSuggestClusterBreak(typesetter, start, width))
            let normal = legal.filter { $0 > start && $0 <= fit && measure(start, $0) <= width + 0.01 }.sorted()
            if !normal.isEmpty { return normal }
            // Only an indivisible over-wide token gets emergency grapheme breaks.
            return graphemes.filter { $0 > start && $0 <= fit && allowed($0) && measure(start, $0) <= width + 0.01 }
        }
        var end = 0
        var count = 0
        var greedy: [Int] = [0]
        while end < length && count < 3 {
            guard let next = ends(end).last else { return nil }
            end = next; count += 1; greedy.append(end)
        }
        if allowPartial && end < length, greedy.count >= 2 {
            let lastStart = greedy[greedy.count - 2]
            let lastEnd = ends(lastStart).last { boundary in
                Self.width(ns.substring(with: NSRange(location: lastStart, length: boundary - lastStart)) + "…", size: size) <= width
            } ?? lastStart
            greedy[greedy.count - 1] = lastEnd
            var fragments = zip(greedy, greedy.dropFirst()).map {
                ns.substring(with: NSRange(location: $0, length: $1 - $0))
            }
            fragments[fragments.count - 1] += "…"
            return fragments
        }
        guard end == length, count <= 3 else { return nil }
        struct Path { let offsets: [Int]; let cost: Double }
        var paths = [Path(offsets: [0], cost: 0)]
        let target = Self.width(text, size: size) / Double(count)
        for row in 0..<count {
            var next: [Path] = []
            for path in paths {
                let start = path.offsets.last!
                for boundary in ends(start) where (row == count - 1) == (boundary == length) {
                    let part = ns.substring(with: NSRange(location: start, length: boundary - start))
                    let used = measure(start, boundary)
                    let balance = pow((used - target) / max(1, width), 2) * 10
                    let last = part.trimmingCharacters(in: .whitespacesAndNewlines).last
                    let penalty = boundary == length ? 0 : last.map { "。！？.!?".contains($0) ? 0 : "，、；：,;:".contains($0) ? 0.15 : wordEnds.contains(boundary) || $0.isWhitespace ? 0.35 : 1.2 } ?? 1.2
                    let orphan = row == count - 1 && used < width * 0.25 ? 2.0 : 0
                    next.append(Path(offsets: path.offsets + [boundary], cost: path.cost + balance + penalty + orphan))
                }
            }
            paths = Array(next.sorted { $0.cost == $1.cost ? $0.offsets.lexicographicallyPrecedes($1.offsets) : $0.cost < $1.cost }.prefix(24))
        }
        let offsets = paths.first?.offsets ?? greedy
        return zip(offsets, offsets.dropFirst()).map {
            ns.substring(with: NSRange(location: $0, length: $1 - $0))
        }
    }
}

@MainActor
final class PreviewLyricWrapCache {
    private(set) var metrics = PreviewFloatingTextMetrics()
    private(set) var configurationCount = 0
    private(set) var cachedCount = 0
    private var key: String?
    private var plans: [String: PreviewWrappedLine] = [:]

    func configure(identity: UUID?, texts: @autoclosure () -> [String], fontSize: Double, screenWidth: Double) {
        let size = fontSize.isFinite ? min(48, max(20, fontSize)) : 30
        let screen = screenWidth.isFinite && screenWidth > 0 ? screenWidth : 1440
        let newKey = "\(identity?.uuidString ?? "nil")/\(size)/\(screen)"
        guard key != newKey else { return }
        key = newKey; configurationCount += 1; plans.removeAll(keepingCapacity: true); cachedCount = 0
        let lines = texts()
        let cap = PreviewFloatingLayoutPolicy.width(textWidth: .greatestFiniteMagnitude, screenWidth: screen)
        var widest = 0.0
        for text in lines {
            widest = max(widest, PreviewLyricWrapping.width(String(text.prefix(400)), size: size))
            if widest + PreviewFloatingLayoutPolicy.horizontalChrome >= cap { break }
        }
        metrics = PreviewFloatingTextMetrics(width: PreviewFloatingLayoutPolicy.width(textWidth: widest, screenWidth: screen), fontSize: size)
        if widest > metrics.textWidth {
            for text in lines {
                let line = plan(text)
                metrics.rows = max(metrics.rows, line.fragments.count)
                if metrics.rows >= 3 { break }
            }
        }
    }

    func plan(_ text: String) -> PreviewWrappedLine {
        if let cached = plans[text] { return cached }
        let result = PreviewLyricWrapping.wrap(text, fontSize: metrics.fontSize, width: metrics.textWidth)
        if plans.count >= 256 { plans.removeAll(keepingCapacity: true) }
        plans[text] = result; cachedCount = plans.count
        return result
    }
}
