import XCTest
@testable import LyricFeverCore

@MainActor
final class LyricFetchPipelineTests: XCTestCase {
    let valid = NetworkFetchReturn(lyrics: [LyricLine(startTime: 1000, words: "A"), LyricLine(startTime: 2000, words: "B")], colorData: nil)

    func testFallbackRejectsEmptyAndMetadataOnly() async throws {
        let empty = FakeProvider("empty") { _ in NetworkFetchReturn(lyrics: [], colorData: nil) }
        let zero = FakeProvider("zero") { _ in NetworkFetchReturn(lyrics: [LyricLine(startTime: 0, words: "Composer")], colorData: nil) }
        let good = FakeProvider("good") { [valid] _ in valid }
        var writes: [String] = []
        _ = try await LyricFetchPipeline.fetch(request: request(), providers: [empty, zero, good], validate: {}, commit: { source, _ in writes.append(source.providerName) })
        XCTAssertEqual(writes, ["good"])
        XCTAssertEqual([empty.calls, zero.calls, good.calls], [1, 1, 1])
    }

    func testSourceErrorDoesNotEndFallback() async throws {
        let bad = FakeProvider("bad") { _ in throw LyricSourceError.httpStatus(503) }
        let good = FakeProvider("good") { [valid] _ in valid }
        let result = try await LyricFetchPipeline.fetch(request: request(), providers: [bad, good], validate: {}, commit: { _, _ in })
        XCTAssertEqual(result.lyrics.count, 2)
    }

    func testAllEmptySourcesTerminate() async throws {
        let empty = FakeProvider("empty") { _ in NetworkFetchReturn(lyrics: [], colorData: nil) }
        let result = try await LyricFetchPipeline.fetch(request: request(), providers: [empty], validate: {}, commit: { _, _ in XCTFail("Must not commit") })
        XCTAssertTrue(result.lyrics.isEmpty)
        XCTAssertEqual(empty.calls, 1)
    }

    func testCancellationStopsFallback() async {
        for error in [CancellationError() as Error, URLError(.cancelled) as Error] {
            let cancelled = FakeProvider("cancelled") { _ in throw error }
            let next = FakeProvider("next") { [valid] _ in valid }
            do {
                _ = try await LyricFetchPipeline.fetch(request: request(), providers: [cancelled, next], validate: {}, commit: { _, _ in XCTFail("Must not commit") })
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(next.calls, 0)
        }
    }

    func testLateAResponseCannotWriteBCache() async throws {
        let gate = LyricRequestGate()
        let old = gate.begin(trackID: "A", trackName: "A", artistName: "Artist", albumName: nil, durationMS: 30000)
        var current = "A"
        var cache: [String: [LyricLine]] = [:]
        let started = expectation(description: "Started A")
        var continuation: CheckedContinuation<NetworkFetchReturn, Error>?
        let slow = FakeProvider("slow") { _ in try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() } }
        let task = Task { try await LyricFetchPipeline.fetch(request: old, providers: [slow], validate: {
            try gate.check(old, currentTrackID: current)
        }, commit: { _, result in cache[old.trackID] = result.lyrics }) }
        await fulfillment(of: [started], timeout: 2)
        current = "B"
        gate.invalidate()
        continuation?.resume(returning: valid)
        do { _ = try await task.value; XCTFail("Expected stale request") } catch { XCTAssertTrue(error is FetchError) }
        XCTAssertTrue(cache.isEmpty)
    }

    func testAtoBtoAInvalidatesOldGeneration() async {
        let gate = LyricRequestGate()
        let old = gate.begin(trackID: "A", trackName: "A", artistName: nil, albumName: nil, durationMS: 0)
        gate.invalidate()
        _ = gate.begin(trackID: "B", trackName: "B", artistName: nil, albumName: nil, durationMS: 0)
        let fresh = gate.begin(trackID: "A", trackName: "A", artistName: nil, albumName: nil, durationMS: 0)
        XCTAssertThrowsError(try gate.check(old, currentTrackID: "A"))
        XCTAssertNoThrow(try gate.check(fresh, currentTrackID: "A"))
    }

    func testOldRequestDoesNotClearNewLoading() async {
        let gate = LyricRequestGate()
        let old = gate.begin(trackID: "A", trackName: "A", artistName: nil, albumName: nil, durationMS: 0)
        let fresh = gate.begin(trackID: "A", trackName: "A", artistName: nil, albumName: nil, durationMS: 0)
        gate.startLoading(fresh)
        XCTAssertFalse(gate.finish(old))
        XCTAssertTrue(gate.isLoading)
        XCTAssertTrue(gate.finish(fresh))
        XCTAssertFalse(gate.isLoading)
    }

    func testThreeActualAtoBtoAResponsesOnlyCommitNewestGeneration() async throws {
        for oldFails in [false, true] {
            for order in [[0, 1, 2], [2, 1, 0]] {
                try await verifyOverlappingRequests(ids: ["A", "B", "A"], oldFails: oldFails,
                                                     freshFails: false, completionOrder: order)
            }
        }
    }

    func testSameSongRefreshSuccessFailureAndCompletionOrderMatrix() async throws {
        for oldFails in [false, true] {
            for freshFails in [false, true] {
                for order in [[0, 1], [1, 0]] {
                    try await verifyOverlappingRequests(ids: ["A", "A"], oldFails: oldFails,
                                                         freshFails: freshFails, completionOrder: order)
                }
            }
        }
    }

    private func verifyOverlappingRequests(ids: [String], oldFails: Bool, freshFails: Bool,
                                           completionOrder: [Int]) async throws {
        let gate = LyricRequestGate()
        var currentTrack = "A"
        var cache: [String: [String]] = ["A": ["Previously cached"]]
        var commits: [UUID] = []
        var snapshots: [LyricFetchRequest] = []
        var pending: [SuspendedFetch] = []
        var tasks: [Task<NetworkFetchReturn, Error>] = []
        for (index, id) in ids.enumerated() {
            currentTrack = id
            let snapshot = gate.begin(trackID: id, trackName: id, artistName: "Artist", albumName: nil, durationMS: 30000)
            gate.startLoading(snapshot)
            snapshots.append(snapshot)
            let started = expectation(description: "Request \(index) started")
            let response = SuspendedFetch(started: started)
            pending.append(response)
            let provider = FakeProvider("suspended-\(index)") { _ in try await response.wait() }
            tasks.append(Task {
                defer { gate.finish(snapshot) }
                return try await LyricFetchPipeline.fetch(request: snapshot, providers: [provider], validate: {
                    try gate.check(snapshot, currentTrackID: currentTrack)
                }, commit: { _, result in
                    commits.append(snapshot.generation)
                    cache[snapshot.trackID] = result.lyrics.map(\.words)
                })
            })
            await fulfillment(of: [started], timeout: 2)
        }
        var freshFinished = false
        for index in completionOrder {
            let isFresh = index == ids.count - 1
            if isFresh ? freshFails : oldFails {
                pending[index].complete(.failure(LyricSourceError.httpStatus(503)))
            } else {
                pending[index].complete(.success(valid))
            }
            let result = await tasks[index].result
            if isFresh {
                freshFinished = true
                switch result {
                case .success(let value): XCTAssertEqual(value.lyrics.count, freshFails ? 0 : 2)
                case .failure(let error): XCTFail("Fresh request unexpectedly failed: \(error)")
                }
            } else {
                switch result {
                case .failure(let error): XCTAssertTrue(error is FetchError)
                case .success: XCTFail("A stale generation must not succeed")
                }
            }
            XCTAssertEqual(gate.isLoading, !freshFinished)
        }
        XCTAssertEqual(commits, freshFails ? [] : [snapshots.last!.generation])
        XCTAssertEqual(cache.keys.sorted(), ["A"])
        XCTAssertEqual(cache["A"], freshFails ? ["Previously cached"] : ["A", "B"])
    }

    func testCommitUsesPlayerSnapshotAndRawLyrics() async throws {
        let snapshot = request("player-id")
        let source = FakeProvider("platform-hash") { [valid] incoming in
            XCTAssertEqual(incoming.trackID, "player-id")
            return valid
        }
        var cache: [String: [LyricLine]] = [:]
        _ = try await LyricFetchPipeline.fetch(request: snapshot, providers: [source], validate: {}, commit: { _, result in cache[snapshot.trackID] = result.lyrics })
        XCTAssertEqual(cache.keys.sorted(), ["player-id"])
        XCTAssertEqual(cache["player-id"]?.map(\.words), ["A", "B"])
    }

    func testRejectsInvalidOrWrongDurationTimeline() async {
        XCTAssertFalse(LyricFetchPipeline.isValid([LyricLine(startTime: .nan, words: "A")]))
        XCTAssertFalse(LyricFetchPipeline.isValid([LyricLine(startTime: -1, words: "A")]))
        XCTAssertFalse(LyricFetchPipeline.isValid([LyricLine(startTime: 900000, words: "A")], durationMS: 180000))
        XCTAssertTrue(LyricFetchPipeline.isValid(valid.lyrics, durationMS: 30000))
    }

    func testDeadlineCancelsOperationWithManualClockSignal() async {
        let clock = ManualDeadline()
        let started = expectation(description: "Operation started")
        let cancelled = expectation(description: "Operation cancelled")
        let task = Task {
            try await withLyricDeadline(seconds: 8, timeout: { await clock.wait() }) {
                started.fulfill()
                do { try await Task.sleep(nanoseconds: 600_000_000_000) }
                catch { cancelled.fulfill(); throw error }
                return 1
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await clock.fire()
        do { _ = try await task.value; XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? LyricSourceError, .timeout) }
        await fulfillment(of: [cancelled], timeout: 2)
    }
}

@MainActor
private final class SuspendedFetch {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<NetworkFetchReturn, Error>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async throws -> NetworkFetchReturn {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func complete(_ result: Result<NetworkFetchReturn, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
