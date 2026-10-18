import Foundation
import OSLog

/// Bounded, metadata-free timings. Worker events do not depend on main-actor delivery.
final class PlaybackControlDiagnostics: @unchecked Sendable {
    enum Stage: String, Codable, Sendable {
        case feedback, queue, worker, processValidation, trackValidation, positionRead, durationRead, seekValidation
        case command, uiDelivery, readbackWait, readback, deadline
    }
    enum Status: String, Codable, Sendable { case started, succeeded, failed, expired, cancelled, unavailable }
    struct Event: Codable, Sendable {
        let observedAt: Date
        let stage: Stage
        let status: Status
        let elapsedMS: Int
        let failureKind: String?
        let errorCode: Int?
    }
    struct Entry: Codable, Sendable {
        let schemaVersion: Int
        let requestID: UUID
        let command: PlaybackControlCommand
        let observedAt: Date
        var readRequestID: UUID?
        var totalToReadbackMS: Int?
        var events: [Event]
    }
    private struct Round {
        let origin: ContinuousClock.Instant
        var starts: [Stage: ContinuousClock.Instant] = [:]
        var workerEnd: ContinuousClock.Instant?
        var entry: Entry
    }
    private let lock = NSLock()
    private let logger = Logger(subsystem: "local.lyricmate.alpha", category: "playback-control")
    private let logsToSystem: Bool
    private var rounds: [UUID: Round] = [:]
    private var order: [UUID] = []

    init(logsToSystem: Bool = true) { self.logsToSystem = logsToSystem }

    var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { rounds[$0]?.entry }
    }

    func begin(_ request: PlaybackControlRequest) {
        lock.lock(); defer { lock.unlock() }
        guard rounds[request.token] == nil else { return }
        rounds[request.token] = .init(origin: request.issuedAt, starts: [.queue: request.issuedAt],
                                      entry: .init(schemaVersion: 1, requestID: request.token, command: request.command,
                                                   observedAt: Date(), events: []))
        order.append(request.token)
        if order.count > 20 { rounds.removeValue(forKey: order.removeFirst()) }
        append(request.token, stage: .feedback, status: .succeeded, now: .now)
    }

    func workerStarted(_ id: UUID) {
        mark(id, stage: .queue, status: .succeeded)
        mark(id, stage: .worker, status: .started)
    }

    func workerFinished(_ id: UUID, failure: PlaybackControlFailure?) {
        lock.lock(); defer { lock.unlock() }
        let now = ContinuousClock.now
        rounds[id]?.workerEnd = now
        append(id, stage: .worker, status: failure == nil ? .succeeded : .failed, failure: failure, now: now)
    }

    func uiReceived(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        let now = ContinuousClock.now
        append(id, stage: .uiDelivery, status: .succeeded, now: now,
               elapsed: rounds[id]?.workerEnd.map { Self.ms($0, now) })
    }

    func readbackStarted(_ id: UUID, readID: UUID) {
        lock.lock(); defer { lock.unlock() }
        rounds[id]?.entry.readRequestID = readID
        let now = ContinuousClock.now
        append(id, stage: .readbackWait, status: .succeeded, now: now)
        append(id, stage: .readback, status: .started, now: now)
    }

    func mark(_ id: UUID, stage: Stage, status: Status, failure: PlaybackControlFailure? = nil) {
        lock.lock(); defer { lock.unlock() }
        append(id, stage: stage, status: status, failure: failure, now: .now)
    }

    private func append(_ id: UUID, stage: Stage, status: Status, failure: PlaybackControlFailure? = nil,
                        now: ContinuousClock.Instant, elapsed: Int? = nil) {
        guard var round = rounds[id] else { return }
        if status == .started { round.starts[stage] = now }
        let milliseconds = elapsed ?? Self.ms(round.starts[stage] ?? round.origin, now)
        if status != .started { round.starts.removeValue(forKey: stage) }
        if stage == .readback, status != .started { round.entry.totalToReadbackMS = Self.ms(round.origin, now) }
        round.entry.events.append(.init(observedAt: Date(), stage: stage, status: status, elapsedMS: milliseconds,
                                        failureKind: failure?.diagnosticKind, errorCode: failure?.errorCode))
        if round.entry.events.count > 64 { round.entry.events.removeFirst(round.entry.events.count - 64) }
        rounds[id] = round
        if logsToSystem {
            let command = round.entry.command.rawValue, name = stage.rawValue, state = status.rawValue
            let kind = failure?.diagnosticKind ?? "none", code = failure?.errorCode ?? 0
            logger.info("request=\(id.uuidString, privacy: .public) command=\(command, privacy: .public) stage=\(name, privacy: .public) status=\(state, privacy: .public) elapsedMS=\(milliseconds) failure=\(kind, privacy: .public) code=\(code)")
        }
    }

    private static func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Int {
        let value = start.duration(to: end).components
        return max(0, Int(value.seconds * 1000 + value.attoseconds / 1_000_000_000_000_000))
    }
}
