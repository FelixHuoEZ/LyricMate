import XCTest
@testable import LyricFeverCore
@testable import LyricPreviewPolicy

@MainActor
private final class SequenceLyricProvider: LyricProvider {
    let providerName = "Synthetic sequence"
    func fetchNetworkLyrics(trackName: String, trackID: String, currentlyPlayingArtist: String?, currentAlbumName: String?) async throws -> NetworkFetchReturn {
        NetworkFetchReturn(lyrics: [], colorData: nil)
    }
    func search(trackName: String, artistName: String) async throws -> [SongResult] {
        [SongResult(lyricType: providerName, songName: trackName, albumName: "Album", artistName: artistName,
                    lyrics: [LyricLine(startTime: 1000, words: "SyntheticAlpha"), LyricLine(startTime: 2500, words: "SyntheticBeta")], durationMS: 30000)]
    }
}

@MainActor
final class PlaybackFailureSequenceTests: XCTestCase {
    private let identity = PlaybackProcessIdentity(processID: 101, bundleIdentifier: "com.spotify.client", launchDate: Date(timeIntervalSince1970: 1))
    private func snapshot(position: Double = 1500) -> PlaybackSnapshot {
        PlaybackSnapshot(trackID: "SyntheticA", trackName: "Song", artistName: "Artist", albumName: "Album",
                         durationMS: 30000, positionMS: position, isPlaying: true)
    }

    private func authorizedGate(at now: ContinuousClock.Instant) throws -> PlaybackReadGate {
        var gate = PlaybackReadGate()
        XCTAssertTrue(gate.enable())
        let initial = try XCTUnwrap(gate.begin(at: now))
        XCTAssertTrue(initial.requiresProbe)
        XCTAssertTrue(gate.finish(initial.token, at: now))
        return gate
    }

    func testTimeoutInvalidatesHighlightThenRevalidatedSuccessRestoresIt() async throws {
        let now = ContinuousClock.now
        var gate = try authorizedGate(at: now)
        var recovery = PlaybackReadRecovery()
        var discovery = PlaybackProcessDiscovery()
        let model = LyricPreviewSession(providers: [SequenceLyricProvider()])
        model.updatePlayback(snapshot(), autoSearch: false)
        await model.search()?.value
        XCTAssertEqual(model.activeIndex, 0)
        let failed = try XCTUnwrap(gate.begin(at: now))
        XCTAssertTrue(gate.finish(failed.token, at: now))
        model.updatePlayback(nil)
        XCTAssertNil(model.activeIndex)
        XCTAssertEqual(model.displayedPositionMS, 0)
        XCTAssertEqual(recovery.failed(.eventFailed(-1712), initialRead: failed.requiresProbe, at: now), .retry(after: .seconds(1)))
        XCTAssertFalse(recovery.isReady(at: now.advanced(by: .milliseconds(999))))
        let retryAt = now.advanced(by: .seconds(1))
        XCTAssertTrue(recovery.isReady(at: retryAt))
        XCTAssertEqual(discovery.resolve(listed: [identity], revalidated: nil, at: retryAt), .read(identity))
        let retry = try XCTUnwrap(gate.begin(at: retryAt))
        XCTAssertFalse(retry.requiresProbe)
        XCTAssertNil(gate.begin(at: retryAt))
        XCTAssertTrue(gate.finish(retry.token, at: retryAt))
        XCTAssertFalse(recovery.isExpired(at: retryAt))
        recovery.reset()
        model.updatePlayback(snapshot(position: 2600), autoSearch: false)
        XCTAssertEqual(model.activeIndex, 1)
        XCTAssertEqual(recovery.retryCount, 0)
    }

    func testThirdTransientFailureStopsWithoutOpeningAnotherRead() throws {
        let now = ContinuousClock.now
        var gate = try authorizedGate(at: now)
        var recovery = PlaybackReadRecovery()
        for (index, offset) in [0, 1, 3].enumerated() {
            let time = now.advanced(by: .seconds(offset))
            let read = try XCTUnwrap(gate.begin(at: time))
            XCTAssertTrue(gate.finish(read.token, at: time))
            let decision = recovery.failed(.bridgeUnavailable, initialRead: read.requiresProbe, at: time)
            if index < 2 { XCTAssertEqual(decision, .retry(after: .seconds(index + 1))) }
            else { XCTAssertEqual(decision, .stop); gate.stop() }
        }
        XCTAssertEqual(recovery.retryCount, 2)
        XCTAssertNil(gate.pending)
        XCTAssertNil(gate.begin(at: now.advanced(by: .seconds(30))))
    }

    func testPermissionDenialDuringRecoveryStopsWithoutAnotherAttempt() throws {
        let now = ContinuousClock.now
        var gate = try authorizedGate(at: now)
        var recovery = PlaybackReadRecovery()
        let first = try XCTUnwrap(gate.begin(at: now))
        XCTAssertTrue(gate.finish(first.token, at: now))
        _ = recovery.failed(.trackChanged, initialRead: false, at: now)
        let nextTime = now.advanced(by: .seconds(1))
        let next = try XCTUnwrap(gate.begin(at: nextTime))
        XCTAssertTrue(gate.finish(next.token, at: nextTime))
        XCTAssertEqual(recovery.failed(.eventFailed(-1743), initialRead: false, at: nextTime), .stop)
        gate.stop()
        XCTAssertNil(gate.begin(at: nextTime.advanced(by: .seconds(1))))
        XCTAssertEqual(recovery.retryCount, 1)
    }

    func testRecoveryWindowRejectsReplyBeforeItsLongerRequestDeadline() throws {
        let now = ContinuousClock.now
        var gate = try authorizedGate(at: now)
        var recovery = PlaybackReadRecovery()
        _ = recovery.failed(.eventFailed(-1712), initialRead: false, at: now)
        _ = recovery.failed(.trackChanged, initialRead: false, at: now.advanced(by: .seconds(1)))
        let read = try XCTUnwrap(gate.begin(at: now.advanced(by: .seconds(3))))
        let boundary = now.advanced(by: .seconds(10))
        XCTAssertLessThan(boundary, read.deadline)
        XCTAssertFalse(gate.expire(at: boundary))
        let gateAccepted = gate.finish(read.token, at: boundary)
        XCTAssertTrue(gateAccepted)
        XCTAssertTrue(recovery.isExpired(at: boundary))
        XCTAssertFalse(gateAccepted && !recovery.isExpired(at: boundary))
        gate.stop()
        XCTAssertNil(gate.begin(at: boundary))
    }

    func testMissingProcessDuringCooldownCannotBlindlyReadOldOrReusedPID() throws {
        let now = ContinuousClock.now
        var gate = try authorizedGate(at: now)
        var recovery = PlaybackReadRecovery()
        var discovery = PlaybackProcessDiscovery()
        XCTAssertEqual(discovery.resolve(listed: [identity], revalidated: nil, at: now), .read(identity))
        _ = recovery.failed(.bridgeUnavailable, initialRead: false, at: now)
        let ready = now.advanced(by: .seconds(1))
        XCTAssertTrue(recovery.isReady(at: ready))
        let reused = PlaybackProcessIdentity(processID: identity.processID, bundleIdentifier: "another.app", launchDate: identity.launchDate)
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: reused, at: ready), .waiting)
        XCTAssertNil(gate.pending)
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: nil, at: now.advanced(by: .seconds(3))), .unavailable)
        gate.stop()
        XCTAssertNil(gate.begin(at: now.advanced(by: .seconds(4))))
    }

    func testLateOldTokenCannotFinishNewRecoveryRead() throws {
        let now = ContinuousClock.now
        var gate = try authorizedGate(at: now)
        var recovery = PlaybackReadRecovery()
        let old = try XCTUnwrap(gate.begin(at: now))
        XCTAssertTrue(gate.finish(old.token, at: now))
        _ = recovery.failed(.eventFailed(-1712), initialRead: false, at: now)
        let nextTime = now.advanced(by: .seconds(1))
        let current = try XCTUnwrap(gate.begin(at: nextTime))
        XCTAssertFalse(gate.finish(old.token, at: nextTime))
        XCTAssertEqual(gate.pending?.token, current.token)
        XCTAssertNil(gate.begin(at: nextTime))
        XCTAssertTrue(gate.finish(current.token, at: nextTime))
    }
}
