import Foundation

struct PlaybackReadBudget {
    let deadline: ContinuousClock.Instant

    func timeoutTicks(maximum: Int, at now: ContinuousClock.Instant = .now) throws -> Int {
        guard now < deadline else { throw PlaybackReadFailure.deadlineExceeded }
        let remaining = now.duration(to: deadline).components
        let ticks = Double(remaining.seconds) * 60 + Double(remaining.attoseconds) / 1_000_000_000_000_000_000 * 60
        return min(maximum, max(1, Int(ticks.rounded(.down))))
    }
}
