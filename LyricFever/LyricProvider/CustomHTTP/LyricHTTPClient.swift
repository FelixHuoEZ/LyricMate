import Foundation

private final class NoLyricRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct LyricHTTPReceipt: Codable, Sendable {
    let requestNumber: Int?
    let stage: String
    let outcome: String
    let statusCode: Int?
    let headersElapsedMS: Int?
    let firstConsumedByteMS: Int?
    let bodyElapsedMS: Int?
    let totalElapsedMS: Int
    let bytesRead: Int
}

// Only numeric diagnostics cross executors; the lock never protects response text.
private final class LyricHTTPProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ContinuousClock.now
    private var requestNumber: Int?
    private var stage = "not-started"
    private var statusCode: Int?
    private var headersElapsedMS: Int?
    private var firstConsumedByteMS: Int?
    private var bodyStarted: ContinuousClock.Instant?
    private var bodyElapsedMS: Int?
    private var bytesRead = 0

    private func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
    }

    func startedRequest(_ number: Int) {
        lock.lock()
        defer { lock.unlock() }
        requestNumber = number
        stage = "waiting-headers"
    }

    func receivedHeaders(_ response: URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        statusCode = (response as? HTTPURLResponse)?.statusCode
        headersElapsedMS = milliseconds(since: started)
        stage = "validating-response"
    }

    func startedBody() {
        lock.lock()
        defer { lock.unlock() }
        stage = "reading-body"
        bodyStarted = .now
    }

    func consumedFirstByte() {
        lock.lock()
        defer { lock.unlock() }
        firstConsumedByteMS = milliseconds(since: started)
    }

    func endedBody(count: Int, complete: Bool) {
        lock.lock()
        defer { lock.unlock() }
        bytesRead = count
        bodyElapsedMS = bodyStarted.map { milliseconds(since: $0) }
        if complete { stage = "body-complete" }
    }

    func receipt(outcome: String) -> LyricHTTPReceipt {
        lock.lock()
        defer { lock.unlock() }
        return .init(requestNumber: requestNumber, stage: stage, outcome: outcome, statusCode: statusCode,
                     headersElapsedMS: headersElapsedMS, firstConsumedByteMS: firstConsumedByteMS,
                     bodyElapsedMS: bodyElapsedMS, totalElapsedMS: milliseconds(since: started), bytesRead: bytesRead)
    }
}

@MainActor
final class LyricHTTPClient {
    private(set) var requestCount = 0
    private(set) var lastReceipt: LyricHTTPReceipt?
    private let session: URLSession
    private let redirectDelegate = NoLyricRedirects()
    private var retryAfter: Date?
    private let requestBudget: Double
    private let timeout: (@Sendable () async throws -> Void)?

    init(session: URLSession? = nil, requestBudget: Double = 5, timeout: (@Sendable () async throws -> Void)? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            self.session = URLSession(configuration: configuration)
        }
        self.requestBudget = requestBudget
        self.timeout = timeout
    }

    deinit { session.invalidateAndCancel() }

    func get(_ url: URL, maximumBytes: Int = 1024 * 1024, mimeTypes: Set<String> = ["application/json"], referer: String? = nil,
             allowMissingContentType: Bool = false) async throws -> Data {
        let progress = LyricHTTPProgress()
        var outcome = "failed"
        defer { lastReceipt = progress.receipt(outcome: outcome) }
        do {
            let data = try await performGet(url, maximumBytes: maximumBytes, mimeTypes: mimeTypes, referer: referer,
                                            allowMissingContentType: allowMissingContentType, progress: progress)
            outcome = "success"
            return data
        } catch {
            outcome = Self.classify(error)
            throw error
        }
    }

    private func performGet(_ url: URL, maximumBytes: Int, mimeTypes: Set<String>, referer: String?,
                            allowMissingContentType: Bool, progress: LyricHTTPProgress) async throws -> Data {
        if let retryAfter, retryAfter > Date() { throw LyricSourceError.rateLimited }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestBudget
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LyricMate/0.9.2-alpha (local source build)", forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        return try await withLyricDeadline(seconds: requestBudget, timeout: timeout) { [self, request] in
            try Task.checkCancellation()
            requestCount += 1
            progress.startedRequest(requestCount)
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
            defer { bytes.task.cancel() }
            progress.receivedHeaders(response)
            guard let http = response as? HTTPURLResponse else { throw LyricSourceError.invalidResponse }
            if http.statusCode == 429 {
                let value = http.value(forHTTPHeaderField: "Retry-After") ?? ""
                if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
                    retryAfter = Date().addingTimeInterval(seconds)
                } else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    retryAfter = formatter.date(from: value) ?? Date().addingTimeInterval(30)
                }
                throw LyricSourceError.rateLimited
            }
            guard http.statusCode == 200 else { throw LyricSourceError.httpStatus(http.statusCode) }
            if let mime = http.mimeType?.lowercased() {
                guard mimeTypes.contains(mime) || (mimeTypes.contains("application/json") && mime.hasSuffix("+json")) else { throw LyricSourceError.invalidResponse }
            } else if !allowMissingContentType {
                throw LyricSourceError.invalidResponse
            }
            guard http.expectedContentLength <= maximumBytes else { throw LyricSourceError.responseTooLarge }
            return try await Self.readBody(bytes, maximumBytes: maximumBytes, progress: progress)
        }
    }

    // Avoid a MainActor hop for every AsyncBytes element; cancellation stays structured.
    private nonisolated static func readBody(_ bytes: URLSession.AsyncBytes, maximumBytes: Int,
                                            progress: LyricHTTPProgress) async throws -> Data {
        progress.startedBody()
        var data = Data()
        var complete = false
        defer { progress.endedBody(count: data.count, complete: complete) }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw LyricSourceError.responseTooLarge }
            if data.isEmpty { progress.consumedFirstByte() }
            data.append(byte)
        }
        try Task.checkCancellation()
        complete = true
        return data
    }

    private static func classify(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? URLError {
            if error.code == .cancelled { return "cancelled" }
            if error.code == .timedOut { return "timeout" }
            return "transport-error"
        }
        switch error as? LyricSourceError {
        case .timeout: return "timeout"
        case .rateLimited: return "rate-limited"
        case .responseTooLarge: return "too-large"
        case .invalidResponse: return "invalid-response"
        case .httpStatus: return "http-error"
        default: return "failed"
        }
    }
}
