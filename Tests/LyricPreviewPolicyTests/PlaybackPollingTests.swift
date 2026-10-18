import XCTest
@testable import LyricPreviewPolicy

final class PlaybackPollingTests: XCTestCase {
    func testMetadataCacheRequiresBothProcessAndRecordingIdentity() {
        var cache = PlaybackMetadataCache<String>()
        let now = ContinuousClock.now
        cache.store("A", processID: 1, trackID: "trackA", at: now)
        XCTAssertEqual(cache.value(processID: 1, trackID: "trackA", at: now), "A")
        XCTAssertNil(cache.value(processID: 2, trackID: "trackA", at: now))
        XCTAssertNil(cache.value(processID: 1, trackID: "trackB", at: now))
    }

    func testCacheExpiresAtThirtySecondsAndHitsDoNotExtendLifetime() {
        var cache = PlaybackMetadataCache<String>()
        let now = ContinuousClock.now
        cache.store("A", processID: 1, trackID: "A", at: now)
        XCTAssertEqual(cache.value(processID: 1, trackID: "A", at: now.advanced(by: .seconds(29))), "A")
        XCTAssertNil(cache.value(processID: 1, trackID: "A", at: now.advanced(by: .seconds(30))))
        XCTAssertNil(cache.value(processID: 1, trackID: "A", at: now.advanced(by: .seconds(-1))))
        cache.reset()
        XCTAssertNil(cache.value(processID: 1, trackID: "A", at: now))
    }

    func testCacheReplacementNeverRestoresAnOlderRecording() {
        var cache = PlaybackMetadataCache<String>()
        let now = ContinuousClock.now
        cache.store("A", processID: 1, trackID: "A", at: now)
        cache.store("B", processID: 1, trackID: "B", at: now)
        XCTAssertNil(cache.value(processID: 1, trackID: "A", at: now))
        XCTAssertEqual(cache.value(processID: 1, trackID: "B", at: now), "B")
    }

    func testReusedProcessIDCannotReuseAnotherLaunchMetadata() {
        var cache = PlaybackMetadataCache<String>()
        let launch = Date(timeIntervalSince1970: 100)
        cache.store("A", processID: 1, launchDate: launch, trackID: "A")
        XCTAssertEqual(cache.value(processID: 1, launchDate: launch, trackID: "A"), "A")
        XCTAssertNil(cache.value(processID: 1, launchDate: launch.addingTimeInterval(1), trackID: "A"))
        XCTAssertNil(cache.value(processID: 1, trackID: "A"))
    }

    func testPropertyTimeoutCannotExceedRemainingRoundBudget() throws {
        let now = ContinuousClock.now
        let budget = PlaybackReadBudget(deadline: now.advanced(by: .seconds(8)))
        XCTAssertEqual(try budget.timeoutTicks(maximum: 120, at: now), 120)
        XCTAssertEqual(try budget.timeoutTicks(maximum: 120, at: now.advanced(by: .milliseconds(7500))), 30)
        XCTAssertEqual(try budget.timeoutTicks(maximum: 120, at: now.advanced(by: .milliseconds(7999))), 1)
    }

    func testExpiredBudgetRejectsAnyFurtherPropertyRead() {
        let now = ContinuousClock.now
        let budget = PlaybackReadBudget(deadline: now)
        for time in [now, now.advanced(by: .seconds(20))] {
            XCTAssertThrowsError(try budget.timeoutTicks(maximum: 120, at: time)) {
                guard case PlaybackReadFailure.deadlineExceeded = $0 else { return XCTFail("Expected deadline failure") }
            }
        }
    }
}
