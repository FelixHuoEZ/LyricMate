import Foundation

struct PlaybackProcessIdentity: Codable, Sendable, Equatable {
    let processID: Int32
    let bundleIdentifier: String
    let launchDate: Date?
}

struct PlaybackProcessDiscovery {
    enum Decision: Equatable {
        case read(PlaybackProcessIdentity)
        case waiting
        case unavailable
    }

    static let spotifyBundleID = "com.spotify.client"
    private(set) var lastIdentity: PlaybackProcessIdentity?
    private var missingSince: ContinuousClock.Instant?

    mutating func reset() {
        lastIdentity = nil
        missingSince = nil
    }

    mutating func resolve(listed: [PlaybackProcessIdentity], revalidated: PlaybackProcessIdentity?,
                          at now: ContinuousClock.Instant = .now) -> Decision {
        let matching = listed.filter { $0.bundleIdentifier == Self.spotifyBundleID && $0.processID > 0 }
        if let current = matching.first(where: { $0 == lastIdentity }) ?? matching.first {
            lastIdentity = current
            missingSince = nil
            return .read(current)
        }
        // A cached PID alone is insufficient; recheck its bundle and launch identity.
        if let revalidated, revalidated == lastIdentity,
           revalidated.bundleIdentifier == Self.spotifyBundleID, revalidated.processID > 0 {
            missingSince = nil
            return .read(revalidated)
        }
        if missingSince == nil { missingSince = now }
        return missingSince!.duration(to: now) >= .seconds(2) ? .unavailable : .waiting
    }
}
