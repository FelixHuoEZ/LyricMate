import Foundation

// Shared across clients so a fallback, source test, or duplicate LRCLIB source cannot overlap.
@MainActor
final class LyricServiceRequestGate {
    static let shared = LyricServiceRequestGate()
    private let interval: Duration
    private var occupied = false
    private var nextStart: ContinuousClock.Instant?
    private var retryAfter: Date?
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(interval: Duration = .milliseconds(250)) { self.interval = interval }

    nonisolated static func manages(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "lrclib.net" || host.hasSuffix(".lrclib.net")
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if let retryAfter, retryAfter > Date() { throw LyricSourceError.rateLimited }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if occupied { waiters.append((id, continuation)) }
                else { occupied = true; continuation.resume() }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        do {
            try Task.checkCancellation()
            if let retryAfter, retryAfter > Date() { throw LyricSourceError.rateLimited }
            if let nextStart, nextStart > .now { try await Task.sleep(until: nextStart, clock: .continuous) }
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
    }

    func release() {
        nextStart = .now.advanced(by: interval)
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().1.resume() }
    }

    func limit(until date: Date) { retryAfter = max(retryAfter ?? date, date) }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}
