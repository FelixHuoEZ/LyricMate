import Foundation

struct PlaybackIncidentEvent: Codable, Sendable {
    let sequence: Int
    let requestID: UUID
    let observedAt: Date
    let roundElapsedMS: Int
    let stage: String
    let status: String
    let elapsedMS: Int
    let errorCode: Int?
}

struct PlaybackIncident: Codable, Sendable {
    struct WorkerFailure: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable {
            case missingApplication = "missing_application"
            case bridgeUnavailable = "bridge_unavailable"
            case missingProperty = "missing_property"
            case permissionDenied = "permission_denied"
            case eventTimeout = "event_timeout"
            case eventFailed = "event_failed"
            case trackChanged = "track_changed"
            case invalidSnapshot = "invalid_snapshot"
            case deadlineExceeded = "deadline_exceeded"
            case unexpectedError = "unexpected_error"
            case unclassified
        }
        let kind: Kind
        let errorCode: Int?

        init(kind: Kind, errorCode: Int? = nil) {
            self.kind = kind
            self.errorCode = errorCode
        }

        // Never serialize associated property strings or arbitrary error descriptions.
        init(_ failure: PlaybackReadFailure) {
            switch failure {
            case .missingApplication: self.init(kind: .missingApplication)
            case .bridgeUnavailable: self.init(kind: .bridgeUnavailable)
            case .missingProperty: self.init(kind: .missingProperty)
            case .eventFailed(let code):
                self.init(kind: code == -1743 ? .permissionDenied : code == -1712 ? .eventTimeout : .eventFailed, errorCode: code)
            case .trackChanged: self.init(kind: .trackChanged)
            case .invalidSnapshot: self.init(kind: .invalidSnapshot)
            case .deadlineExceeded: self.init(kind: .deadlineExceeded)
            }
        }
    }
    struct Recovery: Codable, Sendable {
        let result: String
        let requestID: UUID?
        let observedAt: Date
    }
    struct Timing: Codable, Sendable {
        var queueMS: Int?
        var workerMS: Int?
        var deliveryMS: Int?
        var totalToUIMS: Int?
    }
    let schemaVersion: Int
    let sessionID: UUID
    let requestID: UUID
    let detectedAt: Date
    let updatedAt: Date
    let processID: Int32
    let initialProbe: Bool
    let budgetMS: Int
    let reasons: [String]
    let detectedStage: String?
    let activeStage: String?
    let outcome: String?
    let recovery: Recovery?
    let workerFailure: WorkerFailure?
    let timing: Timing
    let events: [PlaybackIncidentEvent]
}

// Called directly by the reader and a separate watchdog, never dependent on UI delivery.
final class PlaybackIncidentRecorder: @unchecked Sendable {
    enum Outcome: String { case accepted, retryScheduled, stopped, ignored, cancelled }
    enum RecoveryResult: String { case recovered, stopped, windowExpired, cancelled, manualReconnect }
    private struct Round {
        let start: ContinuousClock.Instant
        let processID: Int32
        let probe: Bool
        let budgetMS: Int
        let before: [PlaybackIncidentEvent]
        var events: [PlaybackIncidentEvent] = []
        var workerStart: ContinuousClock.Instant?
        var workerEnd: ContinuousClock.Instant?
        var uiArrival: ContinuousClock.Instant?
        var timing = PlaybackIncident.Timing()
        var detectedAt: Date?
        var detectedStage: String?
        var reasons: [String] = []
        var activeStage: String?
        var outcome: String?
        var recovery: PlaybackIncident.Recovery?
        var workerFailure: PlaybackIncident.WorkerFailure?
    }
    private let lock = NSLock()
    private let watchdog = DispatchQueue(label: "local.lyricmate.alpha.incident-watchdog", qos: .utility)
    private let sessionID = UUID()
    private let slowMS: Int
    private let slowRoundMS: Int
    private let schedulesDeadlines: Bool
    private var rounds: [UUID: Round] = [:]
    private var order: [UUID] = []
    private var recent: [PlaybackIncidentEvent] = []
    private var sequence = 0
    private var pendingRecovery: Set<UUID> = []
    let store: PlaybackIncidentStore

    init(store: PlaybackIncidentStore = PlaybackIncidentStore(), slowMS: Int = 1000, slowRoundMS: Int = 4000,
         schedulesDeadlines: Bool = true) {
        self.store = store
        self.slowMS = max(1, slowMS)
        self.slowRoundMS = max(1, slowRoundMS)
        self.schedulesDeadlines = schedulesDeadlines
    }

    func queued(_ id: UUID, processID: Int32, probe: Bool, deadline: ContinuousClock.Instant,
                at now: ContinuousClock.Instant = .now, date: Date = Date()) {
        lock.lock()
        guard rounds[id] == nil else { lock.unlock(); return }
        rounds[id] = Round(start: now, processID: processID, probe: probe, budgetMS: Self.ms(now, deadline), before: recent)
        order.append(id)
        if order.count > 32 {
            let removed = order.removeFirst()
            rounds.removeValue(forKey: removed); pendingRecovery.remove(removed)
        }
        append(id, stage: "request.queued", status: "started", elapsedMS: 0, code: nil, now: now, date: date)
        lock.unlock()
        if schedulesDeadlines {
            watchdog.asyncAfter(deadline: .now() + .milliseconds(Self.ms(now, deadline))) { [weak self] in
                self?.deadlineReached(id)
            }
        }
    }

    func workerStarted(_ id: UUID, at now: ContinuousClock.Instant = .now, date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let round = rounds[id] else { return }
        let elapsed = Self.ms(round.start, now)
        rounds[id]?.workerStart = now
        rounds[id]?.timing.queueMS = elapsed
        append(id, stage: "request.worker.started", status: "started", elapsedMS: elapsed, code: nil, now: now, date: date)
        if elapsed >= slowMS { trigger(id, reason: "slow_queue", now: now, date: date) }
    }

    func property(_ id: UUID, event: PlaybackReadDiagnostic, at now: ContinuousClock.Instant = .now) {
        lock.lock(); defer { lock.unlock() }
        guard rounds[id] != nil else { return }
        let stage = Self.safeStage(event.stage)
        let status = ["started", "succeeded", "failed", "missing", "expired", "hit"].contains(event.status) ? event.status : "unknown"
        if status == "started" { rounds[id]?.activeStage = stage }
        else if rounds[id]?.activeStage == stage { rounds[id]?.activeStage = nil }
        append(id, stage: stage, status: status, elapsedMS: event.elapsedMS, code: event.errorCode, now: now, date: event.observedAt)
        if ["failed", "missing", "expired"].contains(status) {
            trigger(id, reason: "reader_" + status, now: now, date: event.observedAt)
        } else if status == "succeeded", event.elapsedMS >= slowMS {
            trigger(id, reason: "slow_property", now: now, date: event.observedAt)
        }
    }

    func workerFinished(_ id: UUID, succeeded: Bool, failure: PlaybackIncident.WorkerFailure? = nil,
                        at now: ContinuousClock.Instant = .now, date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let round = rounds[id] else { return }
        rounds[id]?.workerEnd = now
        rounds[id]?.activeStage = nil
        rounds[id]?.timing.workerMS = round.workerStart.map { Self.ms($0, now) }
        let workerFailure = succeeded ? nil : failure ?? .init(kind: .unclassified)
        rounds[id]?.workerFailure = workerFailure
        append(id, stage: "request.worker.finished", status: succeeded ? "succeeded" : "failed",
               elapsedMS: round.workerStart.map { Self.ms($0, now) } ?? 0, code: workerFailure?.errorCode, now: now, date: date)
        if !succeeded { trigger(id, reason: "worker_failure", now: now, date: date) }
        else if Self.ms(round.start, now) >= slowRoundMS { trigger(id, reason: "slow_round", now: now, date: date) }
        else { saveIfTriggered(id, date: date) }
    }

    func uiReceived(_ id: UUID, at now: ContinuousClock.Instant = .now, date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let round = rounds[id] else { return }
        let delay = round.workerEnd.map { Self.ms($0, now) }
        rounds[id]?.uiArrival = now
        rounds[id]?.timing.deliveryMS = delay
        rounds[id]?.timing.totalToUIMS = Self.ms(round.start, now)
        append(id, stage: "request.ui.received", status: "received", elapsedMS: delay ?? 0, code: nil, now: now, date: date)
        // A delayed watchdog must not lose a deadline already observed by the UI callback.
        if Self.ms(round.start, now) >= round.budgetMS {
            let reason = round.workerEnd.map { Self.ms(round.start, $0) >= round.budgetMS } == true
                ? "deadline_worker_pending" : "deadline_ui_pending"
            trigger(id, reason: reason, now: now, date: date)
        }
        if let delay, delay >= slowMS { trigger(id, reason: "slow_ui_delivery", now: now, date: date) }
        else { saveIfTriggered(id, date: date) }
    }

    func outcome(_ id: UUID, _ outcome: Outcome, at now: ContinuousClock.Instant = .now, date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard rounds[id] != nil else { return }
        rounds[id]?.outcome = outcome.rawValue
        append(id, stage: "request.outcome", status: outcome.rawValue, elapsedMS: 0, code: nil, now: now, date: date)
        if outcome == .retryScheduled { pendingRecovery.insert(id) }
        else if outcome == .accepted { finishRecovery(.recovered, requestID: id, date: date) }
        else if outcome == .stopped { finishRecovery(.stopped, requestID: id, date: date) }
        saveIfTriggered(id, date: date)
    }

    func endRecovery(_ result: RecoveryResult, date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        finishRecovery(result, requestID: nil, date: date)
    }

    private func finishRecovery(_ result: RecoveryResult, requestID: UUID?, date: Date) {
        for id in pendingRecovery {
            rounds[id]?.recovery = .init(result: result.rawValue, requestID: requestID, observedAt: date)
            saveIfTriggered(id, date: date)
        }
        pendingRecovery.removeAll()
    }

    func deadlineReached(_ id: UUID, at now: ContinuousClock.Instant = .now, date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let round = rounds[id], round.uiArrival == nil, Self.ms(round.start, now) >= round.budgetMS else { return }
        let reason = round.workerEnd == nil ? "deadline_worker_pending" : "deadline_ui_pending"
        guard !round.reasons.contains(reason) else { return }
        append(id, stage: "request.watchdog", status: "expired", elapsedMS: Self.ms(round.start, now), code: nil, now: now, date: date)
        trigger(id, reason: reason, now: now, date: date)
    }

    private func append(_ id: UUID, stage: String, status: String, elapsedMS: Int, code: Int?, now: ContinuousClock.Instant, date: Date) {
        guard let round = rounds[id] else { return }
        sequence += 1
        let event = PlaybackIncidentEvent(sequence: sequence, requestID: id, observedAt: date, roundElapsedMS: Self.ms(round.start, now),
                                          stage: stage, status: status, elapsedMS: max(0, elapsedMS), errorCode: code)
        rounds[id]?.events.append(event)
        if let count = rounds[id]?.events.count, count > 200 { rounds[id]?.events.removeFirst(count - 200) }
        recent.append(event)
        if recent.count > 200 { recent.removeFirst(recent.count - 200) }
    }

    private func trigger(_ id: UUID, reason: String, now: ContinuousClock.Instant, date: Date) {
        if rounds[id]?.detectedAt == nil {
            let stage = rounds[id]?.activeStage ?? rounds[id]?.events.last?.stage
            rounds[id]?.detectedAt = date
            rounds[id]?.detectedStage = stage
        }
        if rounds[id]?.reasons.contains(reason) == false { rounds[id]?.reasons.append(reason) }
        saveIfTriggered(id, date: date)
    }

    private func saveIfTriggered(_ id: UUID, date: Date) {
        guard let round = rounds[id], let detected = round.detectedAt else { return }
        store.submit(.init(schemaVersion: 1, sessionID: sessionID, requestID: id, detectedAt: detected, updatedAt: date,
                           processID: round.processID, initialProbe: round.probe, budgetMS: round.budgetMS, reasons: round.reasons,
                           detectedStage: round.detectedStage, activeStage: round.activeStage, outcome: round.outcome,
                           recovery: round.recovery, workerFailure: round.workerFailure,
                           timing: round.timing, events: round.before + round.events))
    }

    private static func safeStage(_ stage: String) -> String {
        let allowed = ["bridge.isRunning", "probe.playerState", "currentTrack", "track.spotifyUrl", "track.name", "track.artist",
                       "track.album", "track.duration", "track.metadata.cache", "playerPosition", "playerState",
                       "currentTrack.spotifyUrl.confirm", "request.worker.deadline"]
        return allowed.contains(stage) ? stage : "unknown.stage"
    }

    private static func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Int {
        let value = start.duration(to: end).components
        return max(0, Int(value.seconds * 1000 + value.attoseconds / 1_000_000_000_000_000))
    }
}
