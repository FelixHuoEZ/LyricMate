import Foundation
import XCTest
@testable import LyricPreviewPolicy

final class PreviewShareDiagnosticsTests: XCTestCase {
    func testOnlyWhitelistedFieldsAndNoIdentifiersOrAbsoluteTimeAreExported() throws {
        let date = Date(timeIntervalSince1970: 123456789)
        let id = UUID()
        let reads = [PlaybackReadDiagnostic(observedAt: date, stage: "track.name", status: "succeeded", elapsedMS: 12, errorCode: nil)]
        let control = PlaybackControlDiagnostics.Entry(schemaVersion: 1, requestID: id, command: .togglePlayback,
            observedAt: date, readRequestID: UUID(), totalToReadbackMS: 120,
            events: [.init(observedAt: date, stage: .command, status: .failed, elapsedMS: 14,
                           failureKind: "synthetic-private-detail", errorCode: -1743)])
        let text = try PreviewShareDiagnostics.preview(reads: reads, controls: [control])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "application", "reads", "controls"])
        for value in [id.uuidString, "observedAt", "requestID", "readRequestID", "failureKind",
                      "synthetic-private-detail", "trackID", "processID", "sourceURL"] {
            XCTAssertFalse(text.contains(value))
        }
        XCTAssertTrue(text.contains("track.name"))
        XCTAssertTrue(text.contains("-1743"))
        XCTAssertTrue(text.contains("togglePlayback"))
    }

    func testUnknownFreeFormStageAndStatusCannotLeak() throws {
        let reads = [PlaybackReadDiagnostic(observedAt: Date(), stage: "synthetic-private-song",
                                           status: "https://private.invalid/fixture", elapsedMS: -3, errorCode: nil)]
        let text = try PreviewShareDiagnostics.preview(reads: reads, controls: [])
        XCTAssertFalse(text.contains("synthetic-private"))
        XCTAssertFalse(text.contains("private.invalid"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let event = try XCTUnwrap((json["reads"] as? [[String: Any]])?.first)
        XCTAssertEqual(event["stage"] as? String, "other")
        XCTAssertEqual(event["status"] as? String, "other")
        XCTAssertEqual(event["elapsedMS"] as? Int, 0)
    }

    func testExportIsBounded() throws {
        let reads = Array(repeating: PlaybackReadDiagnostic(observedAt: Date(), stage: "playerState",
                                                            status: "started", elapsedMS: 2, errorCode: nil), count: 401)
        let event = PlaybackControlDiagnostics.Event(observedAt: Date(), stage: .command, status: .started,
                                                     elapsedMS: 3, failureKind: nil, errorCode: nil)
        let entry = PlaybackControlDiagnostics.Entry(schemaVersion: 1, requestID: UUID(), command: .nextTrack,
            observedAt: Date(), events: Array(repeating: event, count: 100))
        let text = try PreviewShareDiagnostics.preview(reads: reads, controls: Array(repeating: entry, count: 30))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((json["reads"] as? [Any])?.count, 200)
        let controls = try XCTUnwrap(json["controls"] as? [[String: Any]])
        XCTAssertEqual(controls.count, 20)
        XCTAssertTrue(controls.allSatisfy { ($0["events"] as? [Any])?.count == 64 })
    }

    func testReviewedBytesAreSavedOnlyLocallyWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try PreviewShareDiagnostics.preview(reads: [], controls: [])
        try PreviewShareDiagnostics.save(preview, to: directory)
        let file = directory.appendingPathComponent("share-diagnostics.json")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), preview)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["share-diagnostics.json"])
    }
}
