import XCTest
@testable import LyricFeverCore

final class LyricTimelineTests: XCTestCase {
    let lines = [LyricLine(startTime: 1000, words: "Alpha"), LyricLine(startTime: 2500, words: "Beta"), LyricLine(startTime: 4000, words: "Gamma")]

    func testIntroAndExactBoundaries() {
        XCTAssertNil(LyricTimeline.activeIndex(in: lines, positionMS: 999))
        XCTAssertEqual(LyricTimeline.activeIndex(in: lines, positionMS: 1000), 0)
        XCTAssertEqual(LyricTimeline.activeIndex(in: lines, positionMS: 2499), 0)
        XCTAssertEqual(LyricTimeline.activeIndex(in: lines, positionMS: 2500), 1)
    }

    func testPositiveOffsetDelaysAndNegativeOffsetAdvancesWithoutMutatingLyrics() {
        XCTAssertNil(LyricTimeline.activeIndex(in: lines, positionMS: 1000, offsetMS: 250))
        XCTAssertEqual(LyricTimeline.activeIndex(in: lines, positionMS: 1250, offsetMS: 250), 0)
        XCTAssertEqual(LyricTimeline.activeIndex(in: lines, positionMS: 750, offsetMS: -250), 0)
        XCTAssertEqual(lines[0].startTimeMS, 1000)
    }

    func testBackwardAndForwardSeeksDoNotDependOnPreviousIndex() {
        XCTAssertEqual(LyricTimeline.activeIndex(in: lines, positionMS: 4500), 2)
        XCTAssertEqual(LyricTimeline.activeIndex(in: lines, positionMS: 1100), 0)
        XCTAssertEqual(LyricTimeline.activeIndex(in: lines, positionMS: 3500), 1)
        XCTAssertNil(LyricTimeline.activeIndex(in: lines, positionMS: 0))
    }

    func testLastLineDoesNotResetTrackOrNeedFakeFooter() {
        XCTAssertEqual(LyricTimeline.activeIndex(in: lines, positionMS: 10000), 2)
        XCTAssertEqual(lines.count, 3)
    }

    func testDuplicateTimestampSelectsLastStableLineWithoutDeletingRows() {
        let duplicates = [LyricLine(startTime: 1000, words: "Alpha"), LyricLine(startTime: 1000, words: "Beta")]
        XCTAssertEqual(LyricTimeline.activeIndex(in: duplicates, positionMS: 1000), 1)
        XCTAssertEqual(duplicates.count, 2)
    }

    func testEmptyAndNonfiniteInputsDoNotHighlight() {
        XCTAssertNil(LyricTimeline.activeIndex(in: [], positionMS: 1000))
        XCTAssertNil(LyricTimeline.activeIndex(in: lines, positionMS: .nan))
        XCTAssertNil(LyricTimeline.activeIndex(in: lines, positionMS: .infinity))
        XCTAssertNil(LyricTimeline.activeIndex(in: lines, positionMS: 1000, offsetMS: .nan))
    }
}
