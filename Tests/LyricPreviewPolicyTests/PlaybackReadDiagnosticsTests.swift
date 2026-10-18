import XCTest
@testable import LyricPreviewPolicy

final class PlaybackReadDiagnosticsTests: XCTestCase {
    private let started = PlaybackReadDiagnostic(observedAt: Date(timeIntervalSince1970: 1), stage: "probe.playerState", status: "started", elapsedMS: 0, errorCode: nil)
    private let failed = PlaybackReadDiagnostic(observedAt: Date(timeIntervalSince1970: 31), stage: "probe.playerState", status: "failed", elapsedMS: 30000, errorCode: -1712)

    func testCompletionBeforeProgressPreservesFullFailureWithoutDuplicates() {
        var journal = PlaybackReadDiagnostics()
        let token = UUID()
        journal.begin(token)
        XCTAssertTrue(journal.complete([started, failed], for: token))
        XCTAssertFalse(journal.progress(started, for: token))
        XCTAssertFalse(journal.progress(failed, for: token))
        XCTAssertFalse(journal.complete([started, failed], for: token))
        XCTAssertEqual(journal.events, [started, failed])
    }

    func testProgressIsVisibleAndReplacedByOrderedAuthoritativeBatch() {
        var journal = PlaybackReadDiagnostics()
        let token = UUID()
        journal.begin(token)
        XCTAssertTrue(journal.progress(failed, for: token))
        XCTAssertTrue(journal.progress(started, for: token))
        XCTAssertEqual(journal.events, [failed, started])
        XCTAssertTrue(journal.complete([started, failed], for: token))
        XCTAssertEqual(journal.events, [started, failed])
    }

    func testOldRequestCannotOverwriteNewDiagnosticsOrClearPendingRequest() {
        var journal = PlaybackReadDiagnostics()
        let old = UUID()
        let new = UUID()
        journal.begin(old)
        XCTAssertTrue(journal.complete([started, failed], for: old))
        journal.begin(new)
        XCTAssertFalse(journal.progress(failed, for: old))
        XCTAssertFalse(journal.complete([failed], for: old))
        XCTAssertTrue(journal.progress(started, for: new))
        XCTAssertTrue(journal.complete([started], for: new))
        XCTAssertEqual(journal.events, [started, failed, started])
    }

    func testCapacityAndResetApplyToInflightAndCompletedRecords() {
        var journal = PlaybackReadDiagnostics()
        let token = UUID()
        journal.begin(token)
        for _ in 0..<250 { XCTAssertTrue(journal.progress(started, for: token)) }
        XCTAssertEqual(journal.events.count, 200)
        XCTAssertTrue(journal.complete(Array(repeating: started, count: 250) + [failed], for: token))
        XCTAssertEqual(journal.events.count, 200)
        XCTAssertEqual(journal.events.last, failed)
        journal.reset()
        XCTAssertTrue(journal.events.isEmpty)
        XCTAssertFalse(journal.complete([failed], for: token))
    }

    func testFailureSurvivesSuccessfulPollingAndManualReconnect() {
        var journal = PlaybackReadDiagnostics()
        let failedToken = UUID()
        journal.begin(failedToken)
        XCTAssertTrue(journal.progress(failed, for: failedToken))
        XCTAssertTrue(journal.complete([started, failed], for: failedToken))
        for _ in 0..<250 {
            let token = UUID()
            journal.begin(token)
            XCTAssertTrue(journal.complete([started], for: token))
        }
        XCTAssertFalse(journal.events.contains(failed))
        XCTAssertEqual(journal.failures, [failed])
        journal.reset()
        XCTAssertTrue(journal.events.isEmpty)
        XCTAssertEqual(journal.failures, [failed])
        XCTAssertFalse(journal.complete([failed], for: failedToken))
        XCTAssertEqual(journal.failures, [failed])
    }

    func testFailureJournalIsBoundedAndHasNoSuccessfulEvents() {
        var journal = PlaybackReadDiagnostics()
        for index in 0..<30 {
            let token = UUID()
            let event = PlaybackReadDiagnostic(observedAt: Date(timeIntervalSince1970: Double(index)),
                                               stage: "track.artist", status: "failed", elapsedMS: index, errorCode: -1712)
            journal.begin(token)
            XCTAssertTrue(journal.progress(event, for: token))
            XCTAssertTrue(journal.complete([started, event], for: token))
        }
        XCTAssertEqual(journal.failures.count, 20)
        XCTAssertEqual(journal.failures.first?.elapsedMS, 10)
        XCTAssertEqual(journal.failures.last?.elapsedMS, 29)
        XCTAssertTrue(journal.failures.allSatisfy { $0.status == "failed" })
    }

    func testWatchdogEvidenceSurvivesLateCompletionAndReconnect() throws {
        var journal = PlaybackReadDiagnostics()
        let token = UUID()
        let date = Date(timeIntervalSince1970: 40)
        journal.begin(token)
        XCTAssertFalse(journal.recordDeadline(for: UUID(), elapsedMS: 8000, at: date))
        XCTAssertTrue(journal.recordDeadline(for: token, elapsedMS: 8000, at: date))
        XCTAssertFalse(journal.recordDeadline(for: token, elapsedMS: 8000, at: date.addingTimeInterval(1)))
        XCTAssertTrue(journal.complete([started, failed], for: token))
        journal.reset()
        XCTAssertEqual(journal.failures.map(\.status), ["expired", "failed"])
        let encoded = try JSONEncoder().encode(journal.failures)
        XCTAssertEqual(try JSONDecoder().decode([PlaybackReadDiagnostic].self, from: encoded), journal.failures)
    }
}
