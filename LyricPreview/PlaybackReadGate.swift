import Foundation

struct PlaybackReadGate {
    struct Request: Sendable {
        let token: UUID
        let requiresProbe: Bool
        let deadline: ContinuousClock.Instant

        static let probeBudgetMS = 45000
        static let pollingBudgetMS = 8000
        var timeoutMS: Int { requiresProbe ? Self.probeBudgetMS : Self.pollingBudgetMS }

        static let probeTimeoutTicks = 30 * 60
        static let propertyTimeoutTicks = 2 * 60
    }

    private(set) var enabled = false
    private(set) var pending: Request?
    private var requiresProbe = true
    private var expiredToken: UUID?

    mutating func enable() -> Bool {
        guard pending == nil else { return false }
        enabled = true
        requiresProbe = true
        expiredToken = nil
        return true
    }

    mutating func begin(at now: ContinuousClock.Instant = .now) -> Request? {
        guard enabled, pending == nil else { return nil }
        let timeoutMS = requiresProbe ? Request.probeBudgetMS : Request.pollingBudgetMS
        let request = Request(token: UUID(), requiresProbe: requiresProbe,
                              deadline: now.advanced(by: .milliseconds(timeoutMS)))
        pending = request
        return request
    }

    mutating func expire(at now: ContinuousClock.Instant = .now) -> Bool {
        guard enabled, let pending, now >= pending.deadline else { return false }
        // A system event cannot be cancelled here; retain its slot until it returns.
        enabled = false
        expiredToken = pending.token
        return true
    }

    mutating func finish(_ token: UUID, at now: ContinuousClock.Instant = .now) -> Bool {
        guard let pending, pending.token == token else { return false }
        self.pending = nil
        guard enabled, now < pending.deadline else {
            if enabled && now >= pending.deadline { expiredToken = token }
            enabled = false
            return false
        }
        requiresProbe = false
        return true
    }

    func didExpire(_ token: UUID) -> Bool { expiredToken == token }

    mutating func resumeAfterTimeout(_ token: UUID) -> Bool {
        guard pending == nil, expiredToken == token, !requiresProbe else { return false }
        expiredToken = nil
        enabled = true
        return true
    }

    mutating func stop() { enabled = false; expiredToken = nil }
}
