import Foundation

enum PlaybackReadFailure: Error, LocalizedError, Sendable {
    case missingApplication, bridgeUnavailable, missingProperty(String), eventFailed(Int), trackChanged, invalidSnapshot, deadlineExceeded

    var errorDescription: String? {
        switch self {
        case .missingApplication: return "无法建立现有 Spotify 进程的只读桥；未发出属性查询。"
        case .bridgeUnavailable: return "读取桥暂时未确认 Spotify 运行；不能据此认定进程已退出。"
        case .missingProperty(let property): return "Spotify 未返回有效的 \(property) 属性；尚不能判断是否授权失败。"
        case .eventFailed(-1743): return "系统拒绝此预览读取 Spotify（-1743）；没有更改权限。"
        case .eventFailed(-1744): return "恢复连接需要系统授权；请点击启用只读跟随 Spotify，本次未弹出权限请求。"
        case .eventFailed(let code): return "只读 Apple event 失败（\(code)）。"
        case .trackChanged: return "读取期间歌曲发生变化；已丢弃这次信息。"
        case .invalidSnapshot: return "Spotify 返回的播放信息无效或处于停止状态。"
        case .deadlineExceeded: return "只读查询已超过整轮截止时间；未继续读取后续属性。"
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
