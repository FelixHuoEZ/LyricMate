import XCTest
@testable import LyricFeverCore

@MainActor
final class LyricHTTPReadingTests: XCTestCase {
    func testLocalHalfMiBResponseFitsTheUnchangedRequestBudget() async throws {
        let payload = Data(repeating: 65, count: 512 * 1024)
        let (session, host) = StubURLProtocol.session { _ in .init(data: payload) }
        defer { session.invalidateAndCancel() }
        let client = LyricHTTPClient(session: session)
        let start = ContinuousClock.now
        let data = try await client.get(URL(string: "https://\(host)/")!)
        XCTAssertEqual(data, payload)
        XCTAssertEqual(client.requestCount, 1)
        XCTAssertEqual(client.lastReceipt?.bytesRead, payload.count)
        XCTAssertEqual(client.lastReceipt?.stage, "body-complete")
        XCTAssertEqual(client.lastReceipt?.outcome, "success")
        XCTAssertNotNil(client.lastReceipt?.headersElapsedMS)
        XCTAssertNotNil(client.lastReceipt?.firstConsumedByteMS)
        let duration = start.duration(to: .now).components
        let milliseconds = duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
        print("Synthetic HTTP receipt: bytes=\(data.count), elapsedMS=\(milliseconds), requestBudget=5s; no public network or lyric text.")
    }

    func testLocalResponseAtTheFullSizeLimitIsStillAccepted() async throws {
        let payload = Data(repeating: 65, count: 1024 * 1024)
        let (session, host) = StubURLProtocol.session { _ in .init(data: payload) }
        defer { session.invalidateAndCancel() }
        let client = LyricHTTPClient(session: session)
        let data = try await client.get(URL(string: "https://\(host)/")!)
        XCTAssertEqual(data.count, payload.count)
        XCTAssertEqual(client.lastReceipt?.bytesRead, payload.count)
        XCTAssertEqual(client.lastReceipt?.outcome, "success")
    }

    func testTimeoutBeforeHeadersHasASeparateReceiptAndCancelsTheURLTask() async throws {
        let deadline = ManualDeadline()
        let stopped = expectation(description: "Request cancelled before response headers")
        let (session, host) = StubURLProtocol.session { _ in
            Task { await deadline.fire() }
            return .init(sendHeaders: false, finish: false, onStop: { stopped.fulfill() })
        }
        defer { session.invalidateAndCancel() }
        let client = LyricHTTPClient(session: session, timeout: { await deadline.wait() })
        do { _ = try await client.get(URL(string: "https://\(host)/")!); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? LyricSourceError, .timeout) }
        XCTAssertEqual(client.lastReceipt?.stage, "waiting-headers")
        XCTAssertEqual(client.lastReceipt?.outcome, "timeout")
        XCTAssertNil(client.lastReceipt?.headersElapsedMS)
        XCTAssertNil(client.lastReceipt?.firstConsumedByteMS)
        XCTAssertEqual(client.lastReceipt?.bytesRead, 0)
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testStalledBodyReceiptKeepsPartialByteCountAndCancelsTheURLTask() async throws {
        let stopped = expectation(description: "Stalled response body cancelled")
        let (session, host) = StubURLProtocol.session { _ in
            .init(data: Data(repeating: 65, count: 8), finish: false, onStop: { stopped.fulfill() })
        }
        defer { session.invalidateAndCancel() }
        let client = LyricHTTPClient(session: session, timeout: { try await Task.sleep(nanoseconds: 100_000_000) })
        do { _ = try await client.get(URL(string: "https://\(host)/")!); XCTFail("Expected stalled body timeout") }
        catch { XCTAssertEqual(error as? LyricSourceError, .timeout) }
        XCTAssertEqual(client.lastReceipt?.stage, "reading-body")
        XCTAssertEqual(client.lastReceipt?.outcome, "timeout")
        XCTAssertNotNil(client.lastReceipt?.headersElapsedMS)
        XCTAssertEqual(client.lastReceipt?.bytesRead, 8)
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testOversizeReceiptDoesNotCountTheRejectedByteOrRetry() async throws {
        let (session, host) = StubURLProtocol.session { _ in .init(data: Data(repeating: 65, count: 17)) }
        defer { session.invalidateAndCancel() }
        let client = LyricHTTPClient(session: session)
        do { _ = try await client.get(URL(string: "https://\(host)/")!, maximumBytes: 16); XCTFail("Expected limit") }
        catch { XCTAssertEqual(error as? LyricSourceError, .responseTooLarge) }
        XCTAssertEqual(client.lastReceipt?.outcome, "too-large")
        XCTAssertEqual(client.lastReceipt?.bytesRead, 16)
        XCTAssertEqual(client.requestCount, 1)
    }

    func testRejectedResponseHasNoBodyRead() async throws {
        let (session, host) = StubURLProtocol.session { _ in .init(status: 503, data: Data("SyntheticServiceError".utf8)) }
        defer { session.invalidateAndCancel() }
        let client = LyricHTTPClient(session: session)
        do { _ = try await client.get(URL(string: "https://\(host)/")!); XCTFail("Expected HTTP error") }
        catch { XCTAssertEqual(error as? LyricSourceError, .httpStatus(503)) }
        XCTAssertEqual(client.lastReceipt?.stage, "validating-response")
        XCTAssertEqual(client.lastReceipt?.statusCode, 503)
        XCTAssertEqual(client.lastReceipt?.outcome, "http-error")
        XCTAssertEqual(client.lastReceipt?.bytesRead, 0)
    }

    func testPrecancelledRequestCannotStartNetworkOrExposePreviousReceipt() async throws {
        let (session, host) = StubURLProtocol.session { _ in .init(data: Data("[]".utf8)) }
        defer { session.invalidateAndCancel() }
        let client = LyricHTTPClient(session: session)
        let url = URL(string: "https://\(host)/")!
        _ = try await client.get(url)
        let task = Task { @MainActor in try await client.get(url) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(client.requestCount, 1)
        XCTAssertNil(client.lastReceipt?.requestNumber)
        XCTAssertEqual(client.lastReceipt?.stage, "not-started")
        XCTAssertEqual(client.lastReceipt?.outcome, "cancelled")
    }

    func testParentCancellationStopsAnOpenResponseWithoutRetrying() async throws {
        let started = expectation(description: "Open response started")
        let stopped = expectation(description: "Parent cancellation stops URL task")
        let (session, host) = StubURLProtocol.session { _ in
            started.fulfill()
            return .init(data: Data(repeating: 65, count: 8), finish: false, onStop: { stopped.fulfill() })
        }
        defer { session.invalidateAndCancel() }
        let client = LyricHTTPClient(session: session)
        let task = Task { @MainActor in try await client.get(URL(string: "https://\(host)/")!) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Parent cancellation must not return partial bytes") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(client.requestCount, 1)
        XCTAssertEqual(client.lastReceipt?.outcome, "cancelled")
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testRateLimitReceiptsSeparateHTTPFailureFromBlockedLocalAttempt() async throws {
        let (session, host) = StubURLProtocol.session { _ in .init(status: 429, headers: ["Retry-After": "60"]) }
        defer { session.invalidateAndCancel() }
        let client = LyricHTTPClient(session: session)
        let url = URL(string: "https://\(host)/")!
        for index in 0..<2 {
            do { _ = try await client.get(url); XCTFail("Expected rate limit") }
            catch { XCTAssertEqual(error as? LyricSourceError, .rateLimited) }
            XCTAssertEqual(client.lastReceipt?.outcome, "rate-limited")
            XCTAssertEqual(client.lastReceipt?.stage, index == 0 ? "validating-response" : "not-started")
            XCTAssertEqual(client.lastReceipt?.requestNumber, index == 0 ? 1 : nil)
        }
        XCTAssertEqual(client.requestCount, 1)
    }

    func testDiagnosticsCannotIncludeURLQueriesHeadersOrBody() async throws {
        let secret = "SyntheticPrivateSentinel"
        let (session, host) = StubURLProtocol.session { _ in
            .init(headers: ["Content-Type": "application/json", "X-Synthetic": secret], data: Data(secret.utf8))
        }
        defer { session.invalidateAndCancel() }
        let client = LyricHTTPClient(session: session)
        _ = try await client.get(URL(string: "https://\(host)/\(secret)?key=\(secret)")!)
        let receipt = try XCTUnwrap(client.lastReceipt)
        let encoded = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains(host))
        XCTAssertFalse(encoded.contains("https"))
        XCTAssertEqual(receipt.bytesRead, secret.utf8.count)
    }
}
