import XCTest
@testable import LyricPreviewPolicy

final class PlaybackIncidentTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-incidents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func incidents(_ directory: URL) throws -> [PlaybackIncident] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try decoder.decode(PlaybackIncident.self, from: Data(contentsOf: $0)) }
    }
    private func event(_ stage: String = "track.duration", status: String = "succeeded", elapsed: Int = 1500) -> PlaybackReadDiagnostic {
        .init(observedAt: Date(), stage: stage, status: status, elapsedMS: elapsed, errorCode: nil)
    }
    private func snapshot(_ id: UUID = UUID(), date: Date = Date(), events: [PlaybackIncidentEvent] = []) -> PlaybackIncident {
        .init(schemaVersion: 1, sessionID: UUID(), requestID: id, detectedAt: date, updatedAt: date, processID: 1,
              initialProbe: false, budgetMS: 8000, reasons: ["reader_failed"], detectedStage: nil,
              activeStage: nil, outcome: nil, recovery: nil, workerFailure: nil, timing: .init(), events: events)
    }

    func testKnownWorkerFailuresUseOnlyFixedKindsAndNumericCodes() async throws {
        let cases: [(PlaybackReadFailure, PlaybackIncident.WorkerFailure.Kind, Int?)] = [
            (.missingApplication, .missingApplication, nil), (.bridgeUnavailable, .bridgeUnavailable, nil),
            (.missingProperty("private-property-and-token"), .missingProperty, nil),
            (.eventFailed(-1743), .permissionDenied, -1743), (.eventFailed(-1712), .eventTimeout, -1712),
            (.eventFailed(-50), .eventFailed, -50), (.trackChanged, .trackChanged, nil),
            (.invalidSnapshot, .invalidSnapshot, nil), (.deadlineExceeded, .deadlineExceeded, nil)
        ]
        let dir = try directory(), store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        for (failure, kind, code) in cases {
            let id = UUID()
            recorder.queued(id, processID: 1, probe: false, deadline: .now.advanced(by: .seconds(8)))
            recorder.workerStarted(id)
            recorder.workerFinished(id, succeeded: false, failure: .init(failure))
            recorder.uiReceived(id); recorder.outcome(id, .stopped)
            await store.flush()
            let saved = try XCTUnwrap(incidents(dir).first { $0.requestID == id })
            XCTAssertEqual(saved.workerFailure, .init(kind: kind, errorCode: code))
            XCTAssertEqual(saved.events.first { $0.requestID == id && $0.stage == "request.worker.finished" }?.errorCode, code)
            XCTAssertEqual(saved.reasons, ["worker_failure"])
        }
        let encoded = try JSONEncoder().encode(incidents(dir))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private-property-and-token"))
    }

    func testUnknownWorkerFailureRemainsExplicitlyUnclassified() async throws {
        let dir = try directory(), store = PlaybackIncidentStore(directory: dir, maintenance: false), id = UUID()
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        recorder.queued(id, processID: 1, probe: false, deadline: .now.advanced(by: .seconds(8)))
        recorder.workerFinished(id, succeeded: false)
        await store.flush()
        XCTAssertEqual(try incidents(dir).first?.workerFailure, .init(kind: .unclassified))
    }

    func testLegacyV1IncidentWithoutWorkerFailureStillDecodes() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let original = snapshot()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        object.removeValue(forKey: "workerFailure")
        let saved = try decoder.decode(PlaybackIncident.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(saved.schemaVersion, 1); XCTAssertEqual(saved.requestID, original.requestID)
        XCTAssertNil(saved.workerFailure)
    }

    func testSuccessfulSlowReadHasNoWorkerFailureCategory() async throws {
        let dir = try directory(), store = PlaybackIncidentStore(directory: dir, maintenance: false), id = UUID()
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        recorder.queued(id, processID: 1, probe: false, deadline: .now.advanced(by: .seconds(8)))
        recorder.property(id, event: event())
        recorder.workerFinished(id, succeeded: true, failure: .init(kind: .unexpectedError))
        await store.flush()
        XCTAssertNil(try incidents(dir).first?.workerFailure)
    }

    func testMonotonicQueueWorkerAndUIDeliveryAreSeparate() async throws {
        let dir = try directory(), id = UUID(), start = ContinuousClock.now
        let store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let recorder = PlaybackIncidentRecorder(store: store, slowMS: 100, schedulesDeadlines: false)
        recorder.queued(id, processID: 17, probe: false, deadline: start.advanced(by: .seconds(8)), at: start)
        recorder.workerStarted(id, at: start.advanced(by: .milliseconds(50)))
        recorder.workerFinished(id, succeeded: true, at: start.advanced(by: .milliseconds(170)))
        recorder.uiReceived(id, at: start.advanced(by: .milliseconds(520)))
        recorder.outcome(id, .accepted, at: start.advanced(by: .milliseconds(521)))
        await store.flush()
        let saved = try XCTUnwrap(incidents(dir).first)
        XCTAssertEqual(saved.timing.queueMS, 50); XCTAssertEqual(saved.timing.workerMS, 120)
        XCTAssertEqual(saved.timing.deliveryMS, 350); XCTAssertEqual(saved.timing.totalToUIMS, 520)
        XCTAssertEqual(saved.reasons, ["slow_ui_delivery"]); XCTAssertEqual(saved.outcome, "accepted")
        XCTAssertEqual(saved.events.map(\.sequence), saved.events.map(\.sequence).sorted())
    }

    func testWatchdogSavesBlockedStepWithoutWorkerOrUIReturning() async throws {
        let dir = try directory(), id = UUID()
        let store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let recorder = PlaybackIncidentRecorder(store: store)
        recorder.queued(id, processID: 7, probe: false, deadline: .now.advanced(by: .milliseconds(80)))
        recorder.workerStarted(id)
        recorder.property(id, event: event("track.artist", status: "started", elapsed: 0))
        try await Task.sleep(for: .milliseconds(250)); await store.flush()
        let saved = try XCTUnwrap(incidents(dir).first)
        XCTAssertEqual(saved.activeStage, "track.artist")
        XCTAssertTrue(saved.reasons.contains("deadline_worker_pending"))
        XCTAssertNil(saved.timing.workerMS); XCTAssertNil(saved.timing.deliveryMS)
        XCTAssertNil(saved.workerFailure)
    }

    func testDeadlineDistinguishesWorkerReturnFromPendingUI() async throws {
        let dir = try directory(), id = UUID(), start = ContinuousClock.now
        let store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        recorder.queued(id, processID: 1, probe: false, deadline: start.advanced(by: .milliseconds(100)), at: start)
        recorder.workerStarted(id, at: start)
        recorder.workerFinished(id, succeeded: true, at: start.advanced(by: .milliseconds(10)))
        recorder.deadlineReached(id, at: start.advanced(by: .milliseconds(101)))
        await store.flush()
        XCTAssertEqual(try incidents(dir).first?.reasons, ["deadline_ui_pending"])
        XCTAssertEqual(try incidents(dir).first?.timing.workerMS, 10)
    }

    func testLateRecoveryUpdatesSameFileAndKeepsInitialEvidence() async throws {
        let dir = try directory(), id = UUID(), start = ContinuousClock.now
        let store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        recorder.queued(id, processID: 1, probe: false, deadline: start.advanced(by: .seconds(8)), at: start)
        recorder.workerStarted(id, at: start)
        recorder.property(id, event: event("playerPosition", status: "started", elapsed: 0), at: start)
        recorder.deadlineReached(id, at: start.advanced(by: .seconds(8)))
        await store.flush()
        recorder.property(id, event: event("playerPosition", elapsed: 8500), at: start.advanced(by: .milliseconds(8500)))
        recorder.workerFinished(id, succeeded: true, at: start.advanced(by: .milliseconds(8500)))
        recorder.uiReceived(id, at: start.advanced(by: .milliseconds(8510)))
        recorder.outcome(id, .retryScheduled, at: start.advanced(by: .milliseconds(8511)))
        await store.flush()
        let saved = try incidents(dir)
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved[0].outcome, "retryScheduled")
        XCTAssertTrue(saved[0].reasons.contains("deadline_worker_pending"))
        XCTAssertTrue(saved[0].events.contains { $0.stage == "request.watchdog" })
        XCTAssertNil(saved[0].activeStage)
        XCTAssertEqual(saved[0].detectedStage, "playerPosition")
    }

    func testSuccessfulRetryUpdatesOriginalIncidentWithRecoveryRequestIdentity() async throws {
        let dir = try directory(), id = UUID(), retry = UUID()
        let store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        recorder.queued(id, processID: 1, probe: false, deadline: .now.advanced(by: .seconds(8)))
        recorder.property(id, event: event(status: "failed", elapsed: 1))
        recorder.outcome(id, .retryScheduled)
        recorder.queued(retry, processID: 1, probe: false, deadline: .now.advanced(by: .seconds(8)))
        recorder.workerStarted(retry); recorder.workerFinished(retry, succeeded: true)
        recorder.uiReceived(retry); recorder.outcome(retry, .accepted)
        await store.flush()
        let saved = try XCTUnwrap(incidents(dir).first)
        XCTAssertEqual(saved.requestID, id); XCTAssertEqual(saved.outcome, "retryScheduled")
        XCTAssertEqual(saved.recovery?.result, "recovered"); XCTAssertEqual(saved.recovery?.requestID, retry)
    }

    func testManualReconnectCannotBeMistakenForAutomaticRecovery() async throws {
        let dir = try directory(), id = UUID()
        let store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        recorder.queued(id, processID: 1, probe: false, deadline: .now.advanced(by: .seconds(8)))
        recorder.property(id, event: event(status: "failed", elapsed: 1)); recorder.outcome(id, .retryScheduled)
        recorder.endRecovery(.manualReconnect)
        await store.flush()
        XCTAssertEqual(try incidents(dir).first?.recovery?.result, "manualReconnect")
        XCTAssertNil(try incidents(dir).first?.recovery?.requestID)
    }

    func testLateUICallbackRecordsDeadlineEvenIfWatchdogWasDelayed() async throws {
        let dir = try directory(), id = UUID(), start = ContinuousClock.now
        let store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        recorder.queued(id, processID: 1, probe: false, deadline: start.advanced(by: .seconds(8)), at: start)
        recorder.workerStarted(id, at: start)
        recorder.workerFinished(id, succeeded: true, at: start.advanced(by: .milliseconds(8100)))
        recorder.uiReceived(id, at: start.advanced(by: .milliseconds(8101)))
        await store.flush()
        XCTAssertTrue(try incidents(dir).first?.reasons.contains("deadline_worker_pending") == true)
    }

    func testHealthyRoundDoesNotCreateIncidentEvenWhenOldWatchdogFires() async throws {
        let dir = try directory(), id = UUID(), start = ContinuousClock.now
        let store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        recorder.queued(id, processID: 1, probe: true, deadline: start.advanced(by: .seconds(45)), at: start)
        recorder.workerStarted(id, at: start); recorder.workerFinished(id, succeeded: true, at: start)
        recorder.uiReceived(id, at: start); recorder.outcome(id, .accepted, at: start)
        recorder.deadlineReached(id, at: start.advanced(by: .seconds(46)))
        await store.flush(); XCTAssertTrue(try incidents(dir).isEmpty)
    }

    func testSlowQueueIsRecordedWithoutChangingWorkerResult() async throws {
        let dir = try directory(), id = UUID(), start = ContinuousClock.now
        let store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        recorder.queued(id, processID: 1, probe: false, deadline: start.advanced(by: .seconds(8)), at: start)
        recorder.workerStarted(id, at: start.advanced(by: .seconds(2)))
        recorder.workerFinished(id, succeeded: true, at: start.advanced(by: .seconds(2)))
        recorder.uiReceived(id, at: start.advanced(by: .seconds(2)))
        recorder.outcome(id, .accepted)
        await store.flush()
        XCTAssertEqual(try incidents(dir).first?.reasons, ["slow_queue"])
        XCTAssertEqual(try incidents(dir).first?.outcome, "accepted")
    }

    func testRecreatedRecorderPreservesEarlierSessionAndRequest() async throws {
        let dir = try directory()
        let first = PlaybackIncidentStore(directory: dir, maintenance: false)
        first.submit(snapshot()); await first.flush()
        let second = PlaybackIncidentStore(directory: dir, maintenance: false)
        second.submit(snapshot()); await second.flush()
        let saved = try incidents(dir)
        XCTAssertEqual(saved.count, 2); XCTAssertEqual(Set(saved.map(\.sessionID)).count, 2)
    }

    func testUnknownStringsAreRedactedAndFailureCodeIsRetained() async throws {
        let dir = try directory(), id = UUID()
        let store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        recorder.queued(id, processID: 1, probe: false, deadline: .now.advanced(by: .seconds(8)))
        recorder.property(id, event: .init(observedAt: Date(), stage: "secret-token-and-lyric", status: "failed", elapsedMS: 2, errorCode: -1743))
        await store.flush()
        let data = try JSONEncoder().encode(incidents(dir))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-token-and-lyric"))
        XCTAssertEqual(try incidents(dir).first?.events.last?.stage, "unknown.stage")
        XCTAssertEqual(try incidents(dir).first?.events.last?.errorCode, -1743)
    }

    func testPrecedingRequestsAndCurrentEventsAreBounded() async throws {
        let dir = try directory(), first = UUID(), id = UUID()
        let store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        recorder.queued(first, processID: 1, probe: false, deadline: .now.advanced(by: .seconds(8)))
        for _ in 0..<300 { recorder.property(first, event: event(elapsed: 1)) }
        recorder.queued(id, processID: 1, probe: false, deadline: .now.advanced(by: .seconds(8)))
        for _ in 0..<300 { recorder.property(id, event: event(elapsed: 1)) }
        recorder.property(id, event: event(status: "failed", elapsed: 1))
        await store.flush()
        let saved = try XCTUnwrap(incidents(dir).first)
        XCTAssertLessThanOrEqual(saved.events.count, 400)
        XCTAssertTrue(saved.events.contains { $0.requestID == first })
        XCTAssertTrue(saved.events.contains { $0.requestID == id })
    }

    func testRetentionKeepsAtMostTwentyNewestFiles() async throws {
        let dir = try directory(), store = PlaybackIncidentStore(directory: dir, maintenance: false)
        let oldest = UUID()
        store.submit(snapshot(oldest, date: Date().addingTimeInterval(-100))); await store.flush()
        for i in 1...21 { store.submit(snapshot(date: Date().addingTimeInterval(Double(i - 22)))); await store.flush() }
        let saved = try incidents(dir)
        XCTAssertEqual(saved.count, 20); XCTAssertFalse(saved.contains { $0.requestID == oldest })
    }

    func testRetentionEnforcesTotalByteBudget() async throws {
        let dir = try directory(), store = PlaybackIncidentStore(directory: dir, limits: .init(count: 20, bytes: 1800, age: 604800), maintenance: false)
        for i in 0..<10 { store.submit(snapshot(date: Date().addingTimeInterval(Double(i - 10)))); await store.flush() }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(total, 1800); XCTAssertGreaterThan(files.count, 0); XCTAssertLessThan(files.count, 10)
    }

    func testStartupPrunesExpiredManagedFileButLeavesUnrelatedFile() async throws {
        let dir = try directory(), old = snapshot(date: Date().addingTimeInterval(-8 * 86400))
        let name = "incident-\(Int(old.detectedAt.timeIntervalSince1970))-\(old.sessionID)-\(old.requestID).json"
        try Data("expired".utf8).write(to: dir.appendingPathComponent(name))
        try Data("unrelated".utf8).write(to: dir.appendingPathComponent("keep.txt"))
        let store = PlaybackIncidentStore(directory: dir, maintenance: false); await store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("keep.txt").path))
    }

    func testFailedDiskWriteDoesNotThrowFromRecorder() async throws {
        let dir = try directory(), id = UUID()
        let store = PlaybackIncidentStore(directory: dir, maintenance: false, writer: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let recorder = PlaybackIncidentRecorder(store: store, schedulesDeadlines: false)
        recorder.queued(id, processID: 1, probe: false, deadline: .now.advanced(by: .seconds(8)))
        recorder.property(id, event: event()); recorder.workerFinished(id, succeeded: true)
        recorder.uiReceived(id); recorder.outcome(id, .accepted)
        await store.flush()
        XCTAssertGreaterThan(store.status.failures, 0); XCTAssertTrue(try incidents(dir).isEmpty)
    }

    func testBlockedDiskDoesNotBlockRecorderAndPendingQueueIsBounded() async throws {
        let dir = try directory(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let store = PlaybackIncidentStore(directory: dir, maintenance: false, writer: { data, url in
            entered.signal(); _ = release.wait(timeout: .now() + 5); try data.write(to: url, options: .atomic)
        })
        store.submit(snapshot())
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let start = ContinuousClock.now
        for _ in 0..<30 { store.submit(snapshot()) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        XCTAssertGreaterThanOrEqual(store.status.droppedPending, 10)
        // Release every potential write; no background task may outlive this fixture.
        for _ in 0..<40 { release.signal() }
        await store.flush(); XCTAssertLessThanOrEqual(try incidents(dir).count, 20)
    }

    func testSymlinkDirectoryIsRefusedWithoutWritingThroughIt() async throws {
        let root = try directory(), destination = root.appendingPathComponent("target"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let store = PlaybackIncidentStore(directory: link, maintenance: false)
        store.submit(snapshot()); await store.flush()
        XCTAssertGreaterThan(store.status.failures, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testPersistedFilePermissionsArePrivate() async throws {
        let root = try directory(), dir = root.appendingPathComponent("private")
        let store = PlaybackIncidentStore(directory: dir, maintenance: false)
        store.submit(snapshot()); await store.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
