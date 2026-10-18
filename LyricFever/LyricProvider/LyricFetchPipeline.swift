#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
import Foundation

struct LyricFetchRequest: Sendable {
    let generation: UUID
    let trackID: String
    let trackName: String
    let artistName: String?
    let albumName: String?
    let durationMS: Int
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
}

@MainActor
final class LyricRequestGate {
    private var generation = UUID()
    private(set) var isLoading = false

    func begin(trackID: String, trackName: String, artistName: String?, albumName: String?, durationMS: Int) -> LyricFetchRequest {
        generation = UUID()
        isLoading = false
        return LyricFetchRequest(generation: generation, trackID: trackID, trackName: trackName,
                                 artistName: artistName, albumName: albumName, durationMS: durationMS)
    }

    func invalidate() {
        generation = UUID()
        isLoading = false
    }

    func isCurrent(_ request: LyricFetchRequest) -> Bool { request.generation == generation }

    func check(_ request: LyricFetchRequest, currentTrackID: String?) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < request.deadline else { throw LyricSourceError.timeout }
        guard isCurrent(request), request.trackID == currentTrackID else { throw FetchError.staleTrack }
    }

    func startLoading(_ request: LyricFetchRequest) {
        if isCurrent(request) { isLoading = true }
    }

    @discardableResult
    func finish(_ request: LyricFetchRequest) -> Bool {
        guard isCurrent(request) else { return false }
        isLoading = false
        return true
    }
}

enum LyricSourceError: Error, LocalizedError, Equatable {
    case invalidManifest, unsupportedVersion, unsupportedAuthentication, unsafeURL, duplicateSource, sourceLimit
    case invalidResponse, responseTooLarge, httpStatus(Int), rateLimited, timeout

    var errorDescription: String? {
        switch self {
        case .invalidManifest: return L10n.text("Invalid lyric source configuration.")
        case .unsupportedVersion: return L10n.text("Unsupported lyric source version.")
        case .unsupportedAuthentication: return L10n.text("This version only supports sources without authentication.")
        case .unsafeURL: return L10n.text("The source must use HTTPS without credentials, query parameters or fragments.")
        case .duplicateSource: return L10n.text("This source has already been imported.")
        case .sourceLimit: return L10n.text("At most 16 custom sources are supported.")
        case .invalidResponse: return L10n.text("The source returned an invalid response.")
        case .responseTooLarge: return L10n.text("The source response exceeds the size limit.")
        case .httpStatus(let status): return L10n.text("The source returned HTTP %1$@.", String(status))
        case .rateLimited: return L10n.text("The source is rate limited. Please wait before testing again.")
        case .timeout: return L10n.text("The lyric request exceeded its time budget.")
        }
    }
}

@MainActor
func withLyricDeadline<T: Sendable>(seconds: Double, timeout: (@Sendable () async throws -> Void)? = nil,
                                  operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    guard seconds.isFinite, seconds > 0, seconds <= 300 else { throw LyricSourceError.timeout }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            if let timeout { try await timeout() }
            else { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            throw LyricSourceError.timeout
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return value
    }
}

@MainActor
enum LyricFetchPipeline {
    static func isValid(_ lyrics: [LyricLine], durationMS: Int = 0) -> Bool {
        guard !lyrics.isEmpty, lyrics.contains(where: { $0.startTimeMS > 0 && !$0.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return false }
        return lyrics.allSatisfy {
            $0.startTimeMS.isFinite && $0.startTimeMS >= 0 && (durationMS <= 0 || $0.startTimeMS <= Double(durationMS) + 5000)
        }
    }

    static func fetch(request: LyricFetchRequest, providers: [LyricProvider],
                      validate: () throws -> Void,
                      empty: (LyricProvider) -> Void = { _ in },
                      commit: (LyricProvider, NetworkFetchReturn) -> Void) async throws -> NetworkFetchReturn {
        for provider in providers {
            try validate()
            let result: NetworkFetchReturn
            do { result = try await provider.fetchNetworkLyrics(request: request) }
            catch {
                try validate()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if error is FetchError { throw error }
                continue
            }
            try validate()
            if isValid(result.lyrics, durationMS: request.durationMS) {
                // Validation and cache commit are synchronous on the same actor.
                commit(provider, result)
                return result
            }
            empty(provider)
        }
        try validate()
        return NetworkFetchReturn(lyrics: [], colorData: nil)
    }
}

@MainActor
enum LyricSearchPipeline {
    static func search(trackName: String, artistName: String, providers: [LyricProvider],
                       validate: () throws -> Void,
                       starting: (LyricProvider) -> Void = { _ in },
                       failure: (LyricProvider, Error) -> Void,
                       append: ([SongResult]) -> Void) async throws {
        for provider in providers {
            try validate()
            starting(provider)
            do {
                let results = try await withLyricDeadline(seconds: 8) {
                    try await provider.search(trackName: trackName, artistName: artistName)
                }
                try validate()
                append(results.filter { LyricFetchPipeline.isValid($0.lyrics) })
            } catch {
                try validate()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if error is FetchError { throw error }
                failure(provider, error)
            }
        }
        try validate()
    }
}
