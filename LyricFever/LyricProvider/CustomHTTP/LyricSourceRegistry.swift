import Foundation
#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif

enum LyricSourcePolicyError: Error, LocalizedError {
    case unavailableInSourceAlpha
    var errorDescription: String? {
        L10n.text("This platform adapter is unavailable in the source Alpha. Its saved configuration is retained without network access.")
    }
}

@MainActor
final class LyricSourceRegistry {
    let store: LyricSourceStore
    private let makeProvider: @MainActor (LyricSourceManifest) throws -> CustomHTTPSourceProvider
    private var providers: [UUID: CustomHTTPSourceProvider] = [:]

    init(store: LyricSourceStore, makeProvider: @escaping @MainActor (LyricSourceManifest) throws -> CustomHTTPSourceProvider = {
        try CustomHTTPSourceProvider(manifest: $0)
    }) {
        self.store = store
        self.makeProvider = makeProvider
    }

    var enabledProviders: [LyricProvider] {
        let ids = Set(store.sources.map(\.id))
        providers = providers.filter { ids.contains($0.key) }
        return store.sources.filter { $0.isEnabled && allows($0.manifest) }.compactMap { try? provider(for: $0) }
    }

    func allows(_ manifest: LyricSourceManifest) -> Bool {
        PlatformLyricSource(rawValue: manifest.apiFormat.rawValue) == nil
    }

    func validatePolicy(_ manifest: LyricSourceManifest) throws {
        guard allows(manifest) else { throw LyricSourcePolicyError.unavailableInSourceAlpha }
    }

    func provider(for source: LyricSourceConfiguration) throws -> CustomHTTPSourceProvider {
        try validatePolicy(source.manifest)
        if let provider = providers[source.id], provider.manifest == source.manifest { return provider }
        // Keep the same client across tests and fetches, including its rate-limit cooldown.
        let provider = try makeProvider(source.manifest)
        providers[source.id] = provider
        return provider
    }
}
