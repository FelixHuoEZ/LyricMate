import XCTest
@testable import LyricPreviewPolicy

final class PlaybackReadRecoveryTests: XCTestCase {
    func testInitialReadNeverRetriesEvenKnownTransientFailures() {
        for failure in [PlaybackReadFailure.bridgeUnavailable, .trackChanged, .eventFailed(-1712), .eventFailed(-1743), .deadlineExceeded] {
            var recovery = PlaybackReadRecovery()
            XCTAssertEqual(recovery.failed(failure, initialRead: true), .stop)
            XCTAssertEqual(recovery.retryCount, 0)
        }
    }

    func testDenialsAndUnknownFailuresStopInAnAuthorizedSession() {
        for failure in [PlaybackReadFailure.eventFailed(-1743), .eventFailed(-600), .eventFailed(-1),
                        .missingApplication, .missingProperty("name"), .invalidSnapshot] {
            var recovery = PlaybackReadRecovery()
            XCTAssertEqual(recovery.failed(failure, initialRead: false), .stop)
        }
    }

    func testTransientReplyTimeoutHasABoundedCooldown() {
        var recovery = PlaybackReadRecovery()
        let now = ContinuousClock.now
        XCTAssertEqual(recovery.failed(.eventFailed(-1712), initialRead: false, at: now), .retry(after: .seconds(1)))
        XCTAssertFalse(recovery.isReady(at: now.advanced(by: .milliseconds(999))))
        XCTAssertTrue(recovery.isReady(at: now.advanced(by: .seconds(1))))
    }

    func testOnlyTwoRecoveryReadsAreAllowedPerFailureEpisode() {
        var recovery = PlaybackReadRecovery()
        let now = ContinuousClock.now
        XCTAssertEqual(recovery.failed(.bridgeUnavailable, initialRead: false, at: now), .retry(after: .seconds(1)))
        XCTAssertEqual(recovery.failed(.trackChanged, initialRead: false, at: now.advanced(by: .seconds(1))), .retry(after: .seconds(2)))
        XCTAssertFalse(recovery.isReady(at: now.advanced(by: .milliseconds(2999))))
        XCTAssertTrue(recovery.isReady(at: now.advanced(by: .seconds(3))))
        XCTAssertEqual(recovery.failed(.eventFailed(-1712), initialRead: false, at: now.advanced(by: .seconds(3))), .stop)
        XCTAssertEqual(recovery.retryCount, 2)
    }

    func testRecoveryWindowExpiresAtTheExactBoundary() {
        var recovery = PlaybackReadRecovery()
        let now = ContinuousClock.now
        _ = recovery.failed(.bridgeUnavailable, initialRead: false, at: now)
        XCTAssertFalse(recovery.isExpired(at: now.advanced(by: .milliseconds(9999))))
        XCTAssertTrue(recovery.isExpired(at: now.advanced(by: .seconds(10))))
        XCTAssertFalse(recovery.isReady(at: now.advanced(by: .seconds(10))))
        XCTAssertEqual(recovery.failed(.bridgeUnavailable, initialRead: false, at: now.advanced(by: .seconds(10))), .stop)
    }

    func testCooldownCannotExtendBeyondTheRecoveryWindow() {
        var recovery = PlaybackReadRecovery()
        let now = ContinuousClock.now
        _ = recovery.failed(.bridgeUnavailable, initialRead: false, at: now)
        XCTAssertEqual(recovery.failed(.trackChanged, initialRead: false, at: now.advanced(by: .seconds(8))), .stop)
    }

    func testSuccessOrExplicitEnableResetTheRecoveryBudget() {
        var recovery = PlaybackReadRecovery()
        let now = ContinuousClock.now
        _ = recovery.failed(.bridgeUnavailable, initialRead: false, at: now)
        _ = recovery.failed(.bridgeUnavailable, initialRead: false, at: now.advanced(by: .seconds(1)))
        recovery.reset()
        XCTAssertEqual(recovery.retryCount, 0)
        XCTAssertTrue(recovery.isReady(at: now.advanced(by: .seconds(20))))
        XCTAssertEqual(recovery.failed(.eventFailed(-1712), initialRead: false, at: now.advanced(by: .seconds(20))), .retry(after: .seconds(1)))
    }

    func testWatchdogExpiryCannotOpenARecoveryReadSlot() {
        var gate = PlaybackReadGate()
        var recovery = PlaybackReadRecovery()
        let now = ContinuousClock.now
        XCTAssertTrue(gate.enable())
        let initial = gate.begin(at: now)!
        XCTAssertTrue(gate.finish(initial.token, at: now))
        let read = gate.begin(at: now)!
        XCTAssertTrue(gate.expire(at: read.deadline))
        XCTAssertNotNil(gate.pending)
        XCTAssertFalse(gate.finish(read.token, at: read.deadline))
        _ = recovery.failed(.eventFailed(-1712), initialRead: false, at: read.deadline)
        XCTAssertNil(gate.begin(at: read.deadline.advanced(by: .seconds(1))))
        XCTAssertFalse(gate.enabled)
    }

    func testLateRepliesUseOriginalDeadlineNotArrivalToBoundRecovery() {
        var recovery = PlaybackReadRecovery()
        let deadline = ContinuousClock.now
        XCTAssertEqual(recovery.failed(.deadlineExceeded, initialRead: false, at: deadline), .retry(after: .seconds(1)))
        XCTAssertTrue(recovery.isReady(at: deadline.advanced(by: .seconds(5))))
        XCTAssertTrue(recovery.isExpired(at: deadline.advanced(by: .seconds(10))))
        XCTAssertEqual(recovery.failed(.deadlineExceeded, initialRead: false, at: deadline.advanced(by: .seconds(10))), .stop)
    }
}
