import Foundation
import XCTest
@testable import LyricFeverCore

@MainActor
func manifest(baseURL: String = "https://lyrics.example.com/prefix/", format: LyricSourceFormat? = nil) -> LyricSourceManifest {
    LyricSourceManifest(schemaVersion: 1, apiVersion: 1, name: "Test Source", baseURL: baseURL,
                        capabilities: ["search", "syncedLyrics"], auth: .init(type: "none"), format: format)
}

@MainActor
func request(_ id: String = "player-id", name: String = "Song", artist: String? = "Artist", album: String? = "Album", duration: Int = 30000) -> LyricFetchRequest {
    LyricFetchRequest(generation: UUID(), trackID: id, trackName: name, artistName: artist, albumName: album, durationMS: duration)
}

@MainActor
final class FakeProvider: LyricProvider {
    let providerName: String
    var calls = 0
    var action: (LyricFetchRequest) async throws -> NetworkFetchReturn
    var searchAction: (String, String) async throws -> [SongResult] = { _, _ in [] }
    init(_ name: String, action: @escaping (LyricFetchRequest) async throws -> NetworkFetchReturn) {
        providerName = name
        self.action = action
    }
    func fetchNetworkLyrics(request: LyricFetchRequest) async throws -> NetworkFetchReturn {
        calls += 1
        return try await action(request)
    }
    func fetchNetworkLyrics(trackName: String, trackID: String, currentlyPlayingArtist: String?, currentAlbumName: String?) async throws -> NetworkFetchReturn {
        try await fetchNetworkLyrics(request: request(trackID, name: trackName, artist: currentlyPlayingArtist, album: currentAlbumName))
    }
    func search(trackName: String, artistName: String) async throws -> [SongResult] {
        try await searchAction(trackName, artistName)
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var data = Data()
        var sendHeaders = true
        var finish = true
        var onStop: (() -> Void)?
    }
    // URLSession callbacks cross threads; every registry access is protected by this store's lock.
    private final class HandlerStore: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: (URLRequest) throws -> Reply] = [:]

        func insert(_ handler: @escaping (URLRequest) throws -> Reply, for host: String) {
            lock.lock()
            defer { lock.unlock() }
            handlers[host] = handler
        }

        func lookup(_ host: String) -> ((URLRequest) throws -> Reply)? {
            lock.lock()
            defer { lock.unlock() }
            return handlers[host]
        }
    }
    private static let handlers = HandlerStore()
    var key: String { request.url!.host! }
    private var onStop: (() -> Void)?

    static func session(host: String = UUID().uuidString.lowercased() + ".example.com", handler: @escaping (URLRequest) throws -> Reply) -> (URLSession, String) {
        handlers.insert(handler, for: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return (URLSession(configuration: configuration), host)
    }

    static func session(hosts: [String], handler: @escaping (URLRequest) throws -> Reply) -> URLSession {
        for host in hosts { handlers.insert(handler, for: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.handlers.lookup(key)
        do {
            guard let handler else { throw URLError(.badURL) }
            let reply = try handler(request)
            onStop = reply.onStop
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            if reply.sendHeaders { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if !reply.data.isEmpty { client?.urlProtocol(self, didLoad: reply.data) }
            if reply.finish { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { onStop?() }
}

actor ManualDeadline {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false
    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }
}
