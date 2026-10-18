import Foundation

struct PlaybackReadDiagnostic: Codable, Sendable, Equatable {
    let observedAt: Date
    let stage: String
    let status: String
    let elapsedMS: Int
    let errorCode: Int?
}

struct PlaybackReadDiagnostics {
    private var pendingToken: UUID?
    private var completed: [PlaybackReadDiagnostic] = []
    private var inFlight: [PlaybackReadDiagnostic] = []
    private let capacity = 200
    private let failureCapacity = 20
    private var deadlineRecorded = false
    private(set) var failures: [PlaybackReadDiagnostic] = []

    var events: [PlaybackReadDiagnostic] { Array((completed + inFlight).suffix(capacity)) }

    mutating func reset() {
        pendingToken = nil
        completed.removeAll()
        inFlight.removeAll()
        deadlineRecorded = false
        // Keep bounded failure evidence across manual reconnects in this app session.
    }

    mutating func begin(_ token: UUID) {
        pendingToken = token
        inFlight.removeAll()
        deadlineRecorded = false
    }

    mutating func progress(_ event: PlaybackReadDiagnostic, for token: UUID) -> Bool {
        guard pendingToken == token else { return false }
        inFlight.append(event)
        if inFlight.count > capacity { inFlight.removeFirst(inFlight.count - capacity) }
        retainFailures([event])
        return true
    }

    @discardableResult
    mutating func recordDeadline(for token: UUID, elapsedMS: Int, at date: Date = Date()) -> Bool {
        guard pendingToken == token, !deadlineRecorded else { return false }
        deadlineRecorded = true
        retainFailures([PlaybackReadDiagnostic(observedAt: date, stage: "request.deadline", status: "expired",
                                               elapsedMS: max(0, elapsedMS), errorCode: nil)])
        return true
    }

    mutating func complete(_ batch: [PlaybackReadDiagnostic], for token: UUID) -> Bool {
        guard pendingToken == token else { return false }
        // The worker's ordered batch is authoritative even if UI progress arrives late.
        completed.append(contentsOf: batch.suffix(capacity))
        if completed.count > capacity { completed.removeFirst(completed.count - capacity) }
        retainFailures(batch)
        pendingToken = nil
        inFlight.removeAll()
        return true
    }

    private mutating func retainFailures(_ batch: [PlaybackReadDiagnostic]) {
        for event in batch where ["failed", "missing", "expired"].contains(event.status) && !failures.contains(event) {
            failures.append(event)
        }
        if failures.count > failureCapacity { failures.removeFirst(failures.count - failureCapacity) }
    }
}
