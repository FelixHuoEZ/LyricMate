import Foundation
import XCTest
@testable import LyricFeverCore

@MainActor
final class LyricServiceRequestGateTests: XCTestCase {
    func testManagedHostBoundaries() {
        for host in ["lrclib.net", "www.lrclib.net", "fixture.lrclib.net"] {
            XCTAssertTrue(LyricServiceRequestGate.manages(URL(string: "https://\(host)/api/search")!))
        }
        for host in ["lrclib.net.example.com", "notlrclib.net", "example.com"] {
            XCTAssertFalse(LyricServiceRequestGate.manages(URL(string: "https://\(host)/")!))
        }
    }

    func testRequestIdentityHasVersionAndPublicProjectWithoutCredentials() async throws {
        let (session, host) = StubURLProtocol.session { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"),
                           "LyricMate/0.9.2-alpha (https://github.com/FelixHuoEZ/LyricMate)")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return .init(data: Data("[]".utf8))
        }
        defer { session.invalidateAndCancel() }
        _ = try await LyricHTTPClient(session: session).get(URL(string: "https://\(host)/")!)
    }

    func testNextRequestWaitsAfterPreviousRelease() async throws {
        let gate = LyricServiceRequestGate(interval: .milliseconds(60))
        try await gate.acquire()
        gate.release()
        let released = ContinuousClock.now
        try await gate.acquire()
        XCTAssertGreaterThanOrEqual(released.duration(to: .now), .milliseconds(55))
        gate.release()
    }

    func testProductionIntervalDoesNotBurst() async throws {
        let gate = LyricServiceRequestGate()
        try await gate.acquire()
        gate.release()
        let released = ContinuousClock.now
        try await gate.acquire()
        XCTAssertGreaterThanOrEqual(released.duration(to: .now), .milliseconds(240))
        gate.release()
    }

    func testCancelledWaiterDoesNotBlockNextRequest() async throws {
        let gate = LyricServiceRequestGate(interval: .zero)
        try await gate.acquire()
        let cancelled = Task { @MainActor in try await gate.acquire() }
        await Task.yield()
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        gate.release()
        try await gate.acquire()
        gate.release()
    }

    func testCancellationDuringSpacingReleasesLease() async throws {
        let gate = LyricServiceRequestGate(interval: .milliseconds(60))
        try await gate.acquire()
        gate.release()
        let cancelled = Task { @MainActor in try await gate.acquire() }
        await Task.yield()
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await gate.acquire()
        gate.release()
    }

    func testDistinctClientsShareAnInFlightLeaseAndCancellationRecovers() async throws {
        let gate = LyricServiceRequestGate(interval: .milliseconds(30))
        let firstStarted = expectation(description: "First intercepted request")
        let firstHost = UUID().uuidString.lowercased() + ".lrclib.net"
        let secondHost = UUID().uuidString.lowercased() + ".lrclib.net"
        let (firstSession, _) = StubURLProtocol.session(host: firstHost) { _ in
            firstStarted.fulfill()
            return .init(sendHeaders: false, finish: false)
        }
        let (secondSession, _) = StubURLProtocol.session(host: secondHost) { _ in .init(data: Data("[]".utf8)) }
        defer { firstSession.invalidateAndCancel(); secondSession.invalidateAndCancel() }
        let firstClient = LyricHTTPClient(session: firstSession, serviceGate: gate)
        let secondClient = LyricHTTPClient(session: secondSession, serviceGate: gate)
        let first = Task { try await firstClient.get(URL(string: "https://\(firstHost)/")!) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = Task { try await secondClient.get(URL(string: "https://\(secondHost)/")!) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(secondClient.requestCount, 0)
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch {}
        let secondData = try await second.value
        XCTAssertEqual(secondData, Data("[]".utf8))
        XCTAssertEqual(secondClient.requestCount, 1)
    }

    func testRateLimitIsSharedAcrossClientsWithoutAnotherRequest() async throws {
        let gate = LyricServiceRequestGate(interval: .zero)
        let host = UUID().uuidString.lowercased() + ".lrclib.net"
        let (session, _) = StubURLProtocol.session(host: host) { _ in .init(status: 429, headers: ["Retry-After": "60"]) }
        defer { session.invalidateAndCancel() }
        let first = LyricHTTPClient(session: session, serviceGate: gate)
        let second = LyricHTTPClient(session: session, serviceGate: gate)
        let url = URL(string: "https://\(host)/")!
        for client in [first, second] {
            do { _ = try await client.get(url); XCTFail("Expected local or server rate limit") }
            catch { XCTAssertEqual(error as? LyricSourceError, .rateLimited) }
        }
        XCTAssertEqual(first.requestCount, 1)
        XCTAssertEqual(second.requestCount, 0)
        XCTAssertEqual(second.lastReceipt?.outcome, "rate-limited")
    }
}
