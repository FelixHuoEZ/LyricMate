import LyricMateLocalization
import XCTest
@testable import LyricPreviewPolicy

final class PlaybackControlPolicyTests: XCTestCase {
    private let spotify = PlaybackProcessIdentity(processID: 123, bundleIdentifier: "com.spotify.client", launchDate: nil)

    func testFiveExplicitCommandsHaveDistinctMeanings() {
        XCTAssertEqual(PlaybackControlCommand.allCases.count, 5)
        XCTAssertEqual(Set(PlaybackControlCommand.allCases.map(\.title)).count, 5)
    }
    func testSeekForwardAndBackwardUseSeconds() throws {
        XCTAssertEqual(try PlaybackControlCommand.forward10.seekTarget(position: 20, duration: 240), 30)
        XCTAssertEqual(try PlaybackControlCommand.backward10.seekTarget(position: 20, duration: 240), 10)
    }
    func testSeekClampsStartAndAvoidsCrossingTrackEnd() throws {
        XCTAssertEqual(try PlaybackControlCommand.backward10.seekTarget(position: 3, duration: 240), 0)
        XCTAssertEqual(try PlaybackControlCommand.forward10.seekTarget(position: 237, duration: 240), 239.75)
        XCTAssertEqual(try PlaybackControlCommand.forward10.seekTarget(position: 0, duration: 0.1), 0)
    }
    func testInvalidPositionsAndNonSeekCommandsAreRejected() {
        for pair in [(Double.nan, 240.0), (.infinity, 240), (-1, 240), (10, .nan), (10, 0), (10, -1)] {
            XCTAssertThrowsError(try PlaybackControlCommand.forward10.seekTarget(position: pair.0, duration: pair.1))
        }
        XCTAssertThrowsError(try PlaybackControlCommand.nextTrack.seekTarget(position: 20, duration: 240))
    }
    func testOnePendingCommandRejectsRepeatedClicks() throws {
        var gate = PlaybackControlGate()
        let first = try XCTUnwrap(gate.begin(.togglePlayback, process: spotify, trackID: "track"))
        XCTAssertNil(gate.begin(.nextTrack, process: spotify, trackID: "track"))
        XCTAssertEqual(gate.pending?.token, first.token)
    }
    func testTimeoutKeepsSlotAndNeverCreatesRetry() throws {
        var gate = PlaybackControlGate()
        let request = try XCTUnwrap(gate.begin(.togglePlayback, process: spotify, trackID: "track"))
        XCTAssertFalse(gate.expire(at: request.deadline.advanced(by: .milliseconds(-1))))
        XCTAssertTrue(gate.expire(at: request.deadline))
        XCTAssertFalse(gate.expire(at: request.deadline))
        XCTAssertTrue(gate.isBusy)
        XCTAssertNil(gate.begin(.togglePlayback, process: spotify, trackID: "track"))
        XCTAssertTrue(gate.finish(request.token))
        XCTAssertFalse(gate.isBusy)
    }
    func testStaleCompletionCannotClearActiveCommand() throws {
        var gate = PlaybackControlGate()
        let request = try XCTUnwrap(gate.begin(.nextTrack, process: spotify, trackID: "track"))
        XCTAssertFalse(gate.finish(UUID()))
        XCTAssertEqual(gate.pending?.token, request.token)
        XCTAssertTrue(gate.finish(request.token))
    }
    func testInvalidTargetAndEmptyTrackAreRejected() {
        var gate = PlaybackControlGate()
        XCTAssertNil(gate.begin(.nextTrack, process: .init(processID: 123, bundleIdentifier: "other.app", launchDate: nil), trackID: "track"))
        XCTAssertNil(gate.begin(.nextTrack, process: .init(processID: 0, bundleIdentifier: "com.spotify.client", launchDate: nil), trackID: "track"))
        XCTAssertNil(gate.begin(.nextTrack, process: spotify, trackID: ""))
    }
    func testFailuresDoNotClaimPlaybackSuccess() {
        XCTAssertTrue(PlaybackControlFailure.event(-1712).message.contains(L10n.text("Control result unconfirmed (%1$@); no automatic retry.", "-1712")))
        XCTAssertTrue(PlaybackControlFailure.expired.message.contains(L10n.text("Action timed out. Result unconfirmed; no automatic retry.")))
        XCTAssertTrue(PlaybackControlFailure.event(-1743).message.contains(L10n.text("macOS has not allowed Spotify control. Check Automation permissions.")))
    }
}
