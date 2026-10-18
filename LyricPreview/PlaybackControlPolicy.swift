import Foundation

enum PlaybackControlCommand: String, Codable, CaseIterable, Sendable {
    case previousTrack, backward10, togglePlayback, forward10, nextTrack

    var title: String {
        switch self {
        case .previousTrack: return "上一首"
        case .backward10: return "后退 10 秒"
        case .togglePlayback: return "播放/暂停"
        case .forward10: return "前进 10 秒"
        case .nextTrack: return "下一首"
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
        case .unavailable: return "Spotify 进程已变化或不可用；未启动播放器。"
        case .trackChanged: return "歌曲已切换；本次操作已取消，请确认后再点击。"
        case .invalidPosition: return "播放位置或时长无效；没有调整进度。"
        case .unsupported: return "当前 Spotify 未提供此控制接口。"
        case .expired: return "操作已超时；结果未确认，不自动重试。"
        case .event(-1743): return "系统未允许控制 Spotify；请检查自动化权限。"
        case .event(let code): return "控制结果未确认（\(code)）；不自动重试。"
        case .unexpected: return "控制结果未确认；不自动重试。"
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
