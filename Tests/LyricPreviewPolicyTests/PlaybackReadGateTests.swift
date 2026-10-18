import XCTest
@testable import LyricPreviewPolicy

final class PlaybackReadGateTests: XCTestCase {
    func testDisabledGateNeverStartsAndEnableRequiresInitialProbe() {
        var gate = PlaybackReadGate()
        XCTAssertNil(gate.begin())
        XCTAssertTrue(gate.enable())
        XCTAssertTrue(gate.begin()!.requiresProbe)
    }

    func testSingleFlightRejectsAnotherReadAndAnotherEnable() {
        var gate = PlaybackReadGate()
        XCTAssertTrue(gate.enable())
        let request = gate.begin()!
        XCTAssertNil(gate.begin())
        XCTAssertFalse(gate.enable())
        XCTAssertEqual(gate.pending?.token, request.token)
    }

    func testSuccessfulInitialReadUsesShorterPollingDeadline() {
        var gate = PlaybackReadGate()
        let now = ContinuousClock.now
        XCTAssertTrue(gate.enable())
        let first = gate.begin(at: now)!
        XCTAssertEqual(now.duration(to: first.deadline), .seconds(45))
        XCTAssertTrue(gate.finish(first.token, at: now.advanced(by: .seconds(30))))
        let next = gate.begin(at: now.advanced(by: .seconds(31)))!
        XCTAssertFalse(next.requiresProbe)
        XCTAssertEqual(now.advanced(by: .seconds(31)).duration(to: next.deadline), .seconds(8))
        XCTAssertGreaterThan(PlaybackReadGate.Request.probeTimeoutTicks, PlaybackReadGate.Request.propertyTimeoutTicks)
    }

    func testExpiryRetainsPendingSlotAndDiscardsLateResult() {
        var gate = PlaybackReadGate()
        let now = ContinuousClock.now
        XCTAssertTrue(gate.enable())
        let request = gate.begin(at: now)!
        XCTAssertFalse(gate.expire(at: request.deadline.advanced(by: .milliseconds(-1))))
        XCTAssertTrue(gate.expire(at: request.deadline))
        XCTAssertFalse(gate.enabled)
        XCTAssertNotNil(gate.pending)
        XCTAssertFalse(gate.enable())
        XCTAssertNil(gate.begin())
        XCTAssertFalse(gate.finish(request.token, at: request.deadline))
        XCTAssertNil(gate.pending)
        XCTAssertFalse(gate.enabled)
        XCTAssertTrue(gate.enable())
        XCTAssertTrue(gate.begin()!.requiresProbe)
    }

    func testLateCompletionCannotBeatExpiryIfTimerHasNotRun() {
        var gate = PlaybackReadGate()
        XCTAssertTrue(gate.enable())
        let request = gate.begin()!
        XCTAssertFalse(gate.finish(request.token, at: request.deadline))
        XCTAssertFalse(gate.enabled)
        XCTAssertNil(gate.pending)
    }

    func testStaleTokenCannotClearCurrentRequest() {
        var gate = PlaybackReadGate()
        XCTAssertTrue(gate.enable())
        let request = gate.begin()!
        XCTAssertFalse(gate.finish(UUID()))
        XCTAssertEqual(gate.pending?.token, request.token)
        XCTAssertTrue(gate.enabled)
    }

    func testStopDoesNotFreeInFlightSlotOrAcceptItsCompletion() {
        var gate = PlaybackReadGate()
        XCTAssertTrue(gate.enable())
        let request = gate.begin()!
        gate.stop()
        XCTAssertFalse(gate.enable())
        XCTAssertNotNil(gate.pending)
        XCTAssertFalse(gate.finish(request.token))
        XCTAssertFalse(gate.enabled)
        XCTAssertNil(gate.begin())
    }

    func testAuthorizedTimeoutCanResumeOnlyAfterOldWorkerReturns() {
        var gate = PlaybackReadGate()
        let now = ContinuousClock.now
        XCTAssertTrue(gate.enable())
        XCTAssertTrue(gate.finish(gate.begin(at: now)!.token, at: now))
        let request = gate.begin(at: now)!
        XCTAssertTrue(gate.expire(at: request.deadline))
        XCTAssertFalse(gate.resumeAfterTimeout(request.token))
        XCTAssertFalse(gate.finish(request.token, at: request.deadline))
        XCTAssertTrue(gate.didExpire(request.token))
        XCTAssertFalse(gate.resumeAfterTimeout(UUID()))
        XCTAssertTrue(gate.resumeAfterTimeout(request.token))
        XCTAssertFalse(gate.begin(at: request.deadline)!.requiresProbe)
    }

    func testInitialTimeoutNeverAllowsAutomaticResume() {
        var gate = PlaybackReadGate()
        XCTAssertTrue(gate.enable())
        let request = gate.begin()!
        XCTAssertFalse(gate.finish(request.token, at: request.deadline))
        XCTAssertTrue(gate.didExpire(request.token))
        XCTAssertFalse(gate.resumeAfterTimeout(request.token))
    }

    func testExplicitStopRevokesPendingTimeoutRecovery() {
        var gate = PlaybackReadGate()
        let now = ContinuousClock.now
        XCTAssertTrue(gate.enable())
        XCTAssertTrue(gate.finish(gate.begin(at: now)!.token, at: now))
        let request = gate.begin(at: now)!
        XCTAssertTrue(gate.expire(at: request.deadline))
        gate.stop()
        XCTAssertFalse(gate.finish(request.token, at: request.deadline))
        XCTAssertFalse(gate.resumeAfterTimeout(request.token))
    }
}
