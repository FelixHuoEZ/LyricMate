import XCTest
@testable import LyricPreviewPolicy

final class PreviewLyricWrappingTests: XCTestCase {
    private func assertFits(_ text: String, size: Double = 30, width: Double, file: StaticString = #filePath, line: UInt = #line) -> PreviewWrappedLine {
        let plan = PreviewLyricWrapping.wrap(text, fontSize: size, width: width)
        XCTAssertFalse(plan.needsDisclosure, "size=\(size), width=\(width), natural width=\(PreviewLyricWrapping.width(text, size: size * 0.85)), \(plan.fragments)", file: file, line: line)
        XCTAssertEqual(plan.fragments.joined(), text, file: file, line: line)
        XCTAssertLessThanOrEqual(plan.fragments.count, 3, file: file, line: line)
        for part in plan.fragments {
            XCTAssertLessThanOrEqual(PreviewLyricWrapping.width(part, size: plan.fontSize), width + 0.01, file: file, line: line)
        }
        return plan
    }

    func testShortTextKeepsOriginalFontAndOneRow() {
        let plan = assertFits("短句 · Hello", width: 632)
        XCTAssertEqual(plan.fontSize, 30)
        XCTAssertEqual(plan.fragments.count, 1)
    }

    func testChineseAndEnglishAtSupportedFontsAndScreenWidths() {
        let texts = ["风吹过街角的时候，我们依然记得，曾经一起走过的路。", "Evening comes, we will find our way back home.", "今晚一起 say hello，明天也一起向前走。"]
        for size in [20.0, 30, 48] {
            for width in [420.0, 632, 960] {
                for text in texts { _ = assertFits(text, size: size, width: width) }
            }
        }
    }

    func testEnglishWordsAndContractionsStayIntact() {
        let text = "We don't stop believing when tomorrow is another beautiful day"
        let plan = assertFits(text, width: 420)
        for part in plan.fragments.dropLast() {
            XCTAssertTrue(part.last?.isWhitespace == true, "Unexpected word split: \(plan.fragments)")
        }
    }

    func testPunctuationDoesNotStartOrEndWrongRow() {
        let plan = assertFits("他说：“我们一起往前走。”（别回头），直到故事的最后！", width: 360)
        for part in plan.fragments {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse("，。！？；：）”》」".contains(trimmed.first!))
            XCTAssertFalse("（“《「".contains(trimmed.last!))
        }
    }

    func testEmojiAndCombiningCharactersAreNeverSplit() {
        let text = "一起 👨‍👩‍👧‍👦 看着天空 🇨🇳 微笑 👩🏽‍🚀 cafe\u{301}，明天继续向前走"
        let plan = assertFits(text, width: 420)
        let original = Set(text)
        XCTAssertTrue(plan.fragments.flatMap(Array.init).allSatisfy { original.contains($0) })
    }

    func testNumberAndUnitStayTogether() {
        let plan = assertFits("走过了1997年以后，等到30秒再出发，走过120米的街道", width: 370)
        for part in plan.fragments.dropLast() {
            XCTAssertFalse(part.last?.isNumber == true)
        }
    }

    func testOnlyOverwideWordCanUseEmergencyBreaks() {
        let text = "Supercalifragilisticexpialidocious"
        let plan = assertFits(text, width: 200)
        XCTAssertGreaterThan(plan.fragments.count, 1)
    }

    func testThreeRowsBeforeReducedFont() {
        let text = String(repeating: "风", count: 30)
        let plan = assertFits(text, width: 310)
        XCTAssertEqual(plan.fragments.count, 3)
        XCTAssertEqual(plan.fontSize, 30)
    }

    func testReductionIsBoundedAndOverflowIsExplicit() {
        let reduced = assertFits(String(repeating: "风", count: 33), width: 310)
        XCTAssertEqual(reduced.fontSize, 25.5)
        let huge = PreviewLyricWrapping.wrap(String(repeating: "长", count: 10000), fontSize: 48, width: 420)
        XCTAssertTrue(huge.needsDisclosure)
        XCTAssertEqual(huge.fontSize, 40.8, accuracy: 0.001)
        XCTAssertLessThanOrEqual(huge.fragments.count, 3)
        XCTAssertTrue(huge.fragments.last?.hasSuffix("…") == true)
        let narrow = PreviewLyricWrapping.wrap("When the evening comes, we will find our way back home again.", fontSize: 48, width: 420)
        XCTAssertTrue(narrow.needsDisclosure)
        for part in narrow.fragments.dropLast() { XCTAssertTrue(part.last?.isWhitespace == true) }
    }

    func testDeterministicAndNonfiniteInputsBounded() {
        let text = "风吹过很长的街道，直到我们看见下一次日出。"
        XCTAssertEqual(PreviewLyricWrapping.wrap(text, fontSize: 30, width: 350), PreviewLyricWrapping.wrap(text, fontSize: 30, width: 350))
        let invalid = PreviewLyricWrapping.wrap(text, fontSize: .nan, width: .infinity)
        XCTAssertEqual(invalid.fontSize, 30)
        XCTAssertFalse(invalid.needsDisclosure)
    }

    @MainActor func testSongMetricsStablePromotionAndBoundedCache() {
        let cache = PreviewLyricWrapCache()
        let id = UUID()
        let texts = [String(repeating: "风", count: 60), "short", "short"]
        cache.configure(identity: id, texts: texts, fontSize: 30, screenWidth: 800)
        let metrics = cache.metrics
        let next = cache.plan(texts[0])
        func unexpectedScan() -> [String] { XCTFail("Playback ticks must not scan the song"); return [] }
        cache.configure(identity: id, texts: unexpectedScan(), fontSize: 30, screenWidth: 800)
        XCTAssertEqual(cache.configurationCount, 1)
        XCTAssertEqual(metrics, cache.metrics)
        XCTAssertEqual(cache.plan(texts[0]), next)
        XCTAssertEqual(metrics.rows, 3)
        for index in 0..<1000 { _ = cache.plan("synthetic \(index)") }
        XCTAssertLessThanOrEqual(cache.cachedCount, 256)
        cache.configure(identity: id, texts: texts, fontSize: 48, screenWidth: 800)
        XCTAssertEqual(cache.configurationCount, 2)
        cache.configure(identity: id, texts: texts, fontSize: 48, screenWidth: 600)
        XCTAssertEqual(cache.configurationCount, 3)
        XCTAssertLessThanOrEqual(cache.metrics.width, 568)
    }

    @MainActor func testTwentyThousandLinesAndCachedTicks() {
        let cache = PreviewLyricWrapCache()
        let texts = (0..<20000).map { "Synthetic line \($0)" }
        let id = UUID()
        let started = Date()
        cache.configure(identity: id, texts: texts, fontSize: 30, screenWidth: 1080)
        let preparation = Date().timeIntervalSince(started)
        let ticks = Date()
        for _ in 0..<1000 {
            cache.configure(identity: id, texts: texts, fontSize: 30, screenWidth: 1080)
            _ = cache.plan(texts[0]); _ = cache.plan(texts[1])
        }
        XCTAssertLessThan(preparation, 5)
        XCTAssertLessThan(Date().timeIntervalSince(ticks), 1)
        XCTAssertEqual(cache.configurationCount, 1)
        XCTAssertEqual(cache.metrics.rows, 1)
    }
}
