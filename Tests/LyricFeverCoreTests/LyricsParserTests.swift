import XCTest
@testable import LyricFeverCore

final class LyricsParserTests: XCTestCase {
    func testMilliseconds() {
        XCTAssertEqual(LyricsParser(lyrics: "[00:10.250]Alpha\n[01:02.003]Beta").lyrics.map(\.startTimeMS), [10250, 62003])
    }

    func testMultipleTagsHaveSameText() {
        let lines = LyricsParser(lyrics: "[00:10.00][00:20.00]Alpha").lyrics
        XCTAssertEqual(lines.map(\.startTimeMS), [10000, 20000])
        XCTAssertEqual(lines.map(\.words), ["Alpha", "Alpha"])
    }

    func testOffsetAtEitherEnd() {
        for input in ["[offset:250]\n[00:10]Alpha", "[00:10]Alpha\n[offset:250]"] {
            XCTAssertEqual(LyricsParser(lyrics: input).lyrics.first?.startTimeMS, 10250)
        }
    }

    func testNegativeOffsetOnlyOnce() {
        let parser = LyricsParser(lyrics: "[offset:-250]\n[00:10]Alpha")
        XCTAssertEqual(parser.lyrics.first?.startTimeMS, 9750)
        XCTAssertEqual(NetworkFetchReturn(lyrics: parser.lyrics, colorData: nil).processed(withSongName: "Song", duration: 20000).lyrics.first?.startTimeMS, 9750)
    }

    func testStableSorting() {
        let lines = LyricsParser(lyrics: "[00:20]B\n[00:10]A1\n[00:10]A2").lyrics
        XCTAssertEqual(lines.map(\.words), ["A1", "A2", "B"])
    }

    func testUnicodeAndBracketEnding() {
        let text = "\u{4E2D}\u{6587} e\u{301} don't [chorus]"
        XCTAssertEqual(LyricsParser(lyrics: "[00:10]" + text).lyrics.first?.words, text)
    }

    func testEnhancedLRCRemovesWordTimestampsWithoutChangingLineTiming() {
        let parser = LyricsParser(lyrics: "[00:47.416]<00:47.416>\u{6625}<00:47.855>\u{98CE}<00:48.326>\u{53C8}<00:49.150>\u{6765}<00:49.973><00:49.972>\u{4E86}<00:50.100>")
        XCTAssertEqual(parser.lyrics.map(\.words), ["\u{6625}\u{98CE}\u{53C8}\u{6765}\u{4E86}"])
        XCTAssertEqual(parser.lyrics.map(\.startTimeMS), [47416])
    }

    func testEnhancedLRCPreservesSpacesUnicodeAndSupportedTimestampPrecision() {
        let parser = LyricsParser(lyrics: "[00:01]<00:01>Hold <00:01.2>on, <00:01.23>e\u{301} <00:01.234>\u{4F60}\u{597D}\n[01:02:03.004]<01:02:03.004>Later")
        XCTAssertEqual(parser.lyrics.map(\.words), ["Hold on, e\u{301} \u{4F60}\u{597D}", "Later"])
        XCTAssertEqual(parser.lyrics.map(\.startTimeMS), [1000, 3723004])
    }

    func testEnhancedLRCStillAppliesOffsetsAndRepeatedLineTagsOnlyOnce() {
        let parser = LyricsParser(lyrics: "[00:10][00:20]<00:10.100>Alpha<00:11.200> Beta\n[offset:-250]")
        XCTAssertEqual(parser.lyrics.map(\.words), ["Alpha Beta", "Alpha Beta"])
        XCTAssertEqual(parser.lyrics.map(\.startTimeMS), [9750, 19750])
    }

    func testEnhancedLRCDoesNotStripLiteralOrInvalidAngleBrackets() {
        let text = "<chorus> <3 2<3>1 <00:60.123> <00:NaN> <00:01.1234> <25:00:00> <00:unfinished"
        XCTAssertEqual(LyricsParser(lyrics: "[00:10]" + text).lyrics.first?.words, text)
        XCTAssertEqual(LyricsParser(lyrics: "[00:10]<literal<00:10.100>Alpha> <00:11.200>Beta").lyrics.first?.words, "<literalAlpha> Beta")
    }

    func testEnhancedLRCEndTagsCanLeaveAnEmptyTimedLine() {
        let parser = LyricsParser(lyrics: "[00:01]<00:01.000>\n[00:02]<00:02.000>A<00:03.000>")
        XCTAssertEqual(parser.lyrics.map(\.words), ["", "A"])
        XCTAssertEqual(parser.lyrics.map(\.startTimeMS), [1000, 2000])
    }

    func testWordTimestampsAloneDoNotInventALineTimeline() {
        XCTAssertTrue(LyricsParser(lyrics: "<00:01.000>Untimed <00:02.000>words").lyrics.isEmpty)
    }

    func testLineEndingsBOMAndEscapedNewlines() {
        for input in ["\u{FEFF}[00:10]A\r\n[00:20]B", "[00:10]A\n[00:20]B", "[00:10]A\\n[00:20]B"] {
            XCTAssertEqual(LyricsParser(lyrics: input).lyrics.map(\.words), ["A", "B"])
        }
    }

    func testUnsynchronizedAndHeadersAreNotLyrics() {
        for input in ["plain text", "[ti:Title]\n[ar:Artist]", "", "[00:xx]Alpha", "[00:NaN]A", "[00:Infinity]A", "[00:10"] {
            XCTAssertTrue(LyricsParser(lyrics: input).lyrics.isEmpty, input)
        }
    }

    func testRejectsNegativeOverflowAndInvalidSeconds() {
        for input in ["[-01:10]A", "[999999999999999:10]A", "[00:60]A", "[01:99:00]A"] {
            XCTAssertTrue(LyricsParser(lyrics: input).lyrics.isEmpty)
        }
    }

    func testOffsetDoesNotClampNegativeTimeToZero() {
        XCTAssertTrue(LyricsParser(lyrics: "[00:00.100]A\n[offset:-250]").lyrics.isEmpty)
    }

    func testHourTimestampAndEmptyTimedLine() {
        let parser = LyricsParser(lyrics: "[01:02:03.004]A\n[01:02:04]")
        XCTAssertEqual(parser.lyrics.map(\.startTimeMS), [3723004, 3724000])
        XCTAssertEqual(parser.lyrics.last?.words, "")
    }

    func testDecoderRejectsNonFiniteAndMalformedTime() {
        for time in ["NaN", "Infinity", "bad", "-1"] {
            let data = Data("{\"startTimeMs\":\"\(time)\",\"words\":\"A\"}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(LyricLine.self, from: data))
        }
    }

    func testDisplayFooterIsNotDuplicated() {
        let raw = [LyricLine(startTime: 1000, words: "A"), LyricLine(startTime: 2000, words: "B")]
        let once = NetworkFetchReturn(lyrics: raw, colorData: nil).processed(withSongName: "Song", duration: 3000)
        let twice = once.processed(withSongName: "Song", duration: 3000)
        XCTAssertEqual(once.lyrics.count, 3)
        XCTAssertEqual(twice.lyrics.count, 3)
        XCTAssertEqual(raw.count, 2)
    }

    func testBlankLyricsDoNotCreateFakeFooter() {
        let result = NetworkFetchReturn(lyrics: [LyricLine(startTime: 1000, words: " "), LyricLine(startTime: 2000, words: "")], colorData: nil)
        XCTAssertTrue(result.processed(withSongName: "Song", duration: 3000).lyrics.isEmpty)
    }
}
