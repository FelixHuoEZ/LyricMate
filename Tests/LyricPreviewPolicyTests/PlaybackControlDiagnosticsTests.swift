import XCTest
@testable import LyricPreviewPolicy

final class PlaybackControlDiagnosticsTests: XCTestCase {
    private func request(at now: ContinuousClock.Instant = .now) -> PlaybackControlRequest {
        var gate = PlaybackControlGate()
        return gate.begin(.togglePlayback, process: .init(processID: 12345, bundleIdentifier: "com.spotify.client", launchDate: nil),
                          trackID: "private-track-sentinel", at: now)!
    }

    func testTimingsAndFreshReadAreCorrelatedWithoutRecordingMetadata() throws {
        let log = PlaybackControlDiagnostics(logsToSystem: false)
        let request = request(at: .now.advanced(by: .milliseconds(-250)))
        log.begin(request)
        log.workerStarted(request.token)
        log.mark(request.token, stage: .trackValidation, status: .started)
        log.mark(request.token, stage: .trackValidation, status: .succeeded)
        log.workerFinished(request.token, failure: nil)
        log.uiReceived(request.token)
        log.mark(request.token, stage: .readbackWait, status: .started)
        let readID = UUID()
        log.readbackStarted(request.token, readID: readID)
        log.mark(request.token, stage: .readback, status: .succeeded)
        let entry = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(entry.readRequestID, readID)
        XCTAssertGreaterThanOrEqual(entry.totalToReadbackMS ?? 0, 250)
        XCTAssertGreaterThanOrEqual(entry.events.first { $0.stage == .queue }?.elapsedMS ?? 0, 250)
        XCTAssertTrue(entry.events.contains { $0.stage == .uiDelivery })
        let body = String(decoding: try JSONEncoder().encode(log.entries), as: UTF8.self)
        XCTAssertFalse(body.contains("private-track-sentinel"))
        XCTAssertFalse(body.contains("processID"))
        XCTAssertFalse(body.contains("trackID"))
    }

    func testRetainsOnlyTwentyCommandsAndSixtyFourEventsEach() {
        let log = PlaybackControlDiagnostics(logsToSystem: false)
        let first = request(); log.begin(first)
        for _ in 0..<20 { log.begin(request()) }
        XCTAssertEqual(log.entries.count, 20)
        XCTAssertFalse(log.entries.contains { $0.requestID == first.token })
        let last = log.entries.last!.requestID
        for _ in 0..<80 { log.mark(last, stage: .command, status: .started) }
        XCTAssertEqual(log.entries.last?.events.count, 64)
    }

    func testUnknownAndDuplicateCallbacksCannotCreateOrReplaceRecords() {
        let log = PlaybackControlDiagnostics(logsToSystem: false)
        let request = request(); log.begin(request); log.begin(request)
        log.workerStarted(UUID()); log.uiReceived(UUID()); log.readbackStarted(UUID(), readID: UUID())
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.events.count, 1)
    }

    func testFailureKindsAndNumericCodesAreFixedAndTimeoutDoesNotEraseWorkerHistory() {
        let log = PlaybackControlDiagnostics(logsToSystem: false)
        let request = request(); log.begin(request); log.workerStarted(request.token)
        log.mark(request.token, stage: .deadline, status: .expired)
        log.workerFinished(request.token, failure: .event(-1743))
        log.uiReceived(request.token)
        XCTAssertTrue(log.entries[0].events.contains { $0.stage == .deadline && $0.status == .expired })
        let failure = log.entries[0].events.first { $0.failureKind != nil }
        XCTAssertEqual(failure?.failureKind, "permission_denied")
        XCTAssertEqual(failure?.errorCode, -1743)
        XCTAssertEqual(PlaybackControlFailure.unexpected.diagnosticKind, "unexpected")
        XCTAssertNil(PlaybackControlFailure.unexpected.errorCode)
    }
}
