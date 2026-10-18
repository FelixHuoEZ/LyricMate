#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
import Foundation

enum PlaybackControlCommand: String, Codable, CaseIterable, Sendable {
    case previousTrack, backward10, togglePlayback, forward10, nextTrack

    var title: String {
        switch self {
        case .previousTrack: return L10n.text("Previous track")
        case .backward10: return L10n.text("Back 10 seconds")
        case .togglePlayback: return L10n.text("Play/Pause")
        case .forward10: return L10n.text("Forward 10 seconds")
        case .nextTrack: return L10n.text("Next track")
        }
    }

    func seekTarget(position: Double, duration: Double) throws -> Double {
        guard position.isFinite, duration.isFinite, position >= 0, duration > 0,
              self == .backward10 || self == .forward10 else { throw PlaybackControlFailure.invalidPosition }
        // Do not seek past the end and accidentally advance to the next song.
        return min(max(0, position + (self == .forward10 ? 10 : -10)), max(0, duration - 0.25))
    }
}

enum PlaybackControlFailure: Error, Sendable, Equatable {
    case unavailable, trackChanged, invalidPosition, unsupported, expired, event(Int), unexpected

    var diagnosticKind: String {
        switch self {
        case .unavailable: return "unavailable"
        case .trackChanged: return "track_changed"
        case .invalidPosition: return "invalid_position"
        case .unsupported: return "unsupported"
        case .expired: return "expired"
        case .event(-1743): return "permission_denied"
        case .event(-1712): return "event_timeout"
        case .event: return "event_failed"
        case .unexpected: return "unexpected"
        }
    }

    var errorCode: Int? { if case .event(let code) = self { return code }; return nil }

    var message: String {
        switch self {
        case .unavailable: return L10n.text("Spotify process changed or is unavailable; the player was not launched.")
        case .trackChanged: return L10n.text("Track changed. This action was canceled; check the track before clicking again.")
        case .invalidPosition: return L10n.text("Playback position or duration is invalid; no seek was performed.")
        case .unsupported: return L10n.text("Spotify does not currently provide this control interface.")
        case .expired: return L10n.text("Action timed out. Result unconfirmed; no automatic retry.")
        case .event(-1743): return L10n.text("macOS has not allowed Spotify control. Check Automation permissions.")
        case .event(let code): return L10n.text("Control result unconfirmed (%1$@); no automatic retry.", String(describing: code))
        case .unexpected: return L10n.text("Control result unconfirmed; no automatic retry.")
        }
    }
}

struct PlaybackControlRequest: Sendable {
    let token: UUID
    let command: PlaybackControlCommand
    let process: PlaybackProcessIdentity
    let trackID: String
    let issuedAt: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant
}

struct PlaybackControlGate {
    private(set) var pending: PlaybackControlRequest?
    private(set) var expired = false
    var isBusy: Bool { pending != nil }

    mutating func begin(_ command: PlaybackControlCommand, process: PlaybackProcessIdentity, trackID: String,
                        at now: ContinuousClock.Instant = .now) -> PlaybackControlRequest? {
        guard pending == nil, process.processID > 0, process.bundleIdentifier == PlaybackProcessDiscovery.spotifyBundleID,
              !trackID.isEmpty else { return nil }
        let request = PlaybackControlRequest(token: UUID(), command: command, process: process, trackID: trackID,
                                             issuedAt: now, deadline: now.advanced(by: .seconds(4)))
        pending = request
        expired = false
        return request
    }

    mutating func expire(at now: ContinuousClock.Instant = .now) -> Bool {
        guard let pending, now >= pending.deadline, !expired else { return false }
        expired = true
        // Keep the slot until the worker returns. A timed-out toggle must never be repeated automatically.
        return true
    }

    mutating func finish(_ token: UUID) -> Bool {
        guard pending?.token == token else { return false }
        pending = nil
        expired = false
        return true
    }
}
