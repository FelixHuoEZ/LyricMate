#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
import Foundation

enum PlaybackReadFailure: Error, LocalizedError, Sendable {
    case missingApplication, bridgeUnavailable, missingProperty(String), eventFailed(Int), trackChanged, invalidSnapshot, deadlineExceeded

    var errorDescription: String? {
        switch self {
        case .missingApplication: return L10n.text("Could not create a read-only bridge to the existing Spotify process; no property query was sent.")
        case .bridgeUnavailable: return L10n.text("The read bridge has not confirmed Spotify is running; this does not prove the process exited.")
        case .missingProperty(let property): return L10n.text("Spotify did not return a valid %1$@ property; permission failure is not yet established.", String(describing: property))
        case .eventFailed(-1743): return L10n.text("macOS denied this app access to read Spotify (-1743); permissions were not changed.")
        case .eventFailed(-1744): return L10n.text("Reconnecting needs system permission. Click Enable read-only Spotify following; no permission request was shown this time.")
        case .eventFailed(let code): return L10n.text("Read-only Apple event failed (%1$@).", String(describing: code))
        case .trackChanged: return L10n.text("Track changed during the read; this result was discarded.")
        case .invalidSnapshot: return L10n.text("Spotify returned invalid playback information or is stopped.")
        case .deadlineExceeded: return L10n.text("The read-only query exceeded its overall deadline; remaining properties were not read.")
        }
    }
}

struct PlaybackReadRecovery {
    enum Decision: Equatable {
        case retry(after: Duration)
        case stop
    }

    private(set) var retryCount = 0
    private var nextReadAt: ContinuousClock.Instant?
    private var windowDeadline: ContinuousClock.Instant?

    mutating func reset() {
        retryCount = 0
        nextReadAt = nil
        windowDeadline = nil
    }

    func isExpired(at now: ContinuousClock.Instant = .now) -> Bool {
        windowDeadline.map { now >= $0 } ?? false
    }

    func isReady(at now: ContinuousClock.Instant = .now) -> Bool {
        !isExpired(at: now) && (nextReadAt.map { now >= $0 } ?? true)
    }

    mutating func failed(_ failure: PlaybackReadFailure, initialRead: Bool,
                         at now: ContinuousClock.Instant = .now) -> Decision {
        // Never retry initial authorization, denials, or unknown failures.
        guard !initialRead else { return .stop }
        switch failure {
        case .bridgeUnavailable, .trackChanged, .eventFailed(-1712), .deadlineExceeded: break
        default: return .stop
        }
        guard retryCount < 2, !isExpired(at: now) else { return .stop }
        if windowDeadline == nil { windowDeadline = now.advanced(by: .seconds(10)) }
        let delay = Duration.seconds(retryCount + 1)
        let next = now.advanced(by: delay)
        guard next < windowDeadline! else { return .stop }
        retryCount += 1
        nextReadAt = next
        return .retry(after: delay)
    }
}
