import XCTest
@testable import LyricPreviewPolicy

final class PlaybackProcessDiscoveryTests: XCTestCase {
    private let spotify = PlaybackProcessIdentity(processID: 7935, bundleIdentifier: "com.spotify.client", launchDate: Date(timeIntervalSince1970: 1))

    func testListedProcessIsSelectedAndCached() {
        var discovery = PlaybackProcessDiscovery()
        XCTAssertEqual(discovery.resolve(listed: [spotify], revalidated: nil), .read(spotify))
        XCTAssertEqual(discovery.lastIdentity, spotify)
    }

    func testOneEmptyEnumerationDoesNotStopLiveRevalidatedPID() {
        var discovery = PlaybackProcessDiscovery()
        XCTAssertEqual(discovery.resolve(listed: [spotify], revalidated: nil), .read(spotify))
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: spotify), .read(spotify))
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: spotify, at: .now.advanced(by: .seconds(10))), .read(spotify))
    }

    func testMissingProcessWaitsOnlyTwoSecondsWithoutReadingCachedPID() {
        var discovery = PlaybackProcessDiscovery()
        let now = ContinuousClock.now
        _ = discovery.resolve(listed: [spotify], revalidated: nil, at: now)
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: nil, at: now), .waiting)
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: nil, at: now.advanced(by: .milliseconds(1999))), .waiting)
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: nil, at: now.advanced(by: .seconds(2))), .unavailable)
    }

    func testPIDReusedByAnotherAppCannotBeRead() {
        var discovery = PlaybackProcessDiscovery()
        _ = discovery.resolve(listed: [spotify], revalidated: nil)
        let other = PlaybackProcessIdentity(processID: spotify.processID, bundleIdentifier: "another.app", launchDate: spotify.launchDate)
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: other), .waiting)
    }

    func testChangedLaunchIdentityRequiresFreshListing() {
        var discovery = PlaybackProcessDiscovery()
        _ = discovery.resolve(listed: [spotify], revalidated: nil)
        let new = PlaybackProcessIdentity(processID: spotify.processID, bundleIdentifier: spotify.bundleIdentifier, launchDate: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: new), .waiting)
        XCTAssertEqual(discovery.resolve(listed: [new], revalidated: nil), .read(new))
    }

    func testReappearanceClearsGraceDeadline() {
        var discovery = PlaybackProcessDiscovery()
        let now = ContinuousClock.now
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: nil, at: now), .waiting)
        XCTAssertEqual(discovery.resolve(listed: [spotify], revalidated: nil, at: now.advanced(by: .seconds(1))), .read(spotify))
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: nil, at: now.advanced(by: .seconds(2))), .waiting)
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: nil, at: now.advanced(by: .seconds(3))), .waiting)
    }

    func testResetAndInvalidIdentitiesCannotUseStaleCache() {
        var discovery = PlaybackProcessDiscovery()
        _ = discovery.resolve(listed: [spotify], revalidated: nil)
        discovery.reset()
        XCTAssertNil(discovery.lastIdentity)
        XCTAssertEqual(discovery.resolve(listed: [], revalidated: spotify), .waiting)
        let zero = PlaybackProcessIdentity(processID: 0, bundleIdentifier: spotify.bundleIdentifier, launchDate: nil)
        let other = PlaybackProcessIdentity(processID: 1, bundleIdentifier: "another.app", launchDate: nil)
        XCTAssertEqual(discovery.resolve(listed: [zero, other], revalidated: nil), .waiting)
    }
}
