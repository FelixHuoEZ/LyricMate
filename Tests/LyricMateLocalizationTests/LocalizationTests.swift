import XCTest
import LyricMateLocalization

final class LocalizationTests: XCTestCase {
    func testSystemLanguageResolutionAndFallback() {
        XCTAssertEqual(L10n.language(for: ["en-US"]), "en")
        XCTAssertEqual(L10n.language(for: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["zh-Hans-CN", "en"]), "zh-Hans")
        // Only Simplified Chinese is shipped; unsupported script variants use the English fallback.
        XCTAssertEqual(L10n.language(for: ["zh-Hant-TW"]), "en")
        XCTAssertEqual(L10n.language(for: ["en-GB", "zh-CN"]), "en")
        XCTAssertEqual(L10n.language(for: ["de-DE", "en"]), "en")
        XCTAssertEqual(L10n.language(for: []), "en")
    }

    func testBothResourceBundlesAreUsed() {
        XCTAssertEqual(L10n.localized("Search lyrics", preferences: ["en"]), "Search lyrics")
        XCTAssertEqual(L10n.localized("Search lyrics", preferences: ["zh-Hans"]), "搜索歌词")
        XCTAssertEqual(L10n.localized("Show next line", preferences: ["zh-CN"]), "显示下一句")
        XCTAssertEqual(L10n.localized("Search lyrics", preferences: ["fr"]), "Search lyrics")
    }

    func testInterpolatedTextIsNotRecursivelyInterpretedOrTranslated() {
        let title = "Synthetic 中文 %2$@ %@ 100%"
        XCTAssertEqual(L10n.localized("Next line: %1$@", preferences: ["en"], arguments: [title]), "Next line: " + title)
        XCTAssertEqual(L10n.localized("Next line: %1$@", preferences: ["zh-Hans"], arguments: [title]), "下一句：" + title)
        XCTAssertEqual(L10n.localized("%2$@ / %1$@", preferences: ["en"], arguments: ["A", "B"]), "B / A")
        XCTAssertEqual(L10n.localized("100%% %1$@", preferences: ["en"], arguments: [title]), "100% " + title)
    }

    func testMissingTranslationsAndArgumentsDoNotCrash() {
        XCTAssertEqual(L10n.localized("Future label", preferences: ["zh-Hans"]), "Future label")
        XCTAssertEqual(L10n.localized("Next line: %1$@", preferences: ["en"]), "Next line: %1$@")
        XCTAssertEqual(L10n.localized("literal %n %@", preferences: ["en"]), "literal %n %@")
    }

    func testEveryCatalogEntryIsLoadedForBothLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var keys: Set<String>?
        for language in L10n.supportedLanguages {
            let url = root.appendingPathComponent("Localization/Resources/" + language + ".lproj/Localizable.strings")
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            XCTAssertGreaterThan(table.count, 300)
            if let keys { XCTAssertEqual(Set(table.keys), keys) }
            keys = Set(table.keys)
            for (key, value) in table {
                var expected = value
                for index in 1...5 { expected = expected.replacingOccurrences(of: "%\(index)$@", with: "ARG\(index)") }
                expected = expected.replacingOccurrences(of: "%%", with: "%")
                XCTAssertEqual(L10n.localized(key, preferences: [language], arguments: (1...5).map { "ARG\($0)" }), expected, key)
            }
        }
    }
}
