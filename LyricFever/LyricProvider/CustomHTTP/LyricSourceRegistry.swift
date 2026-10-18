import Foundation

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
        return store.sources.filter(\.isEnabled).compactMap { try? provider(for: $0) }
    }

    func provider(for source: LyricSourceConfiguration) throws -> CustomHTTPSourceProvider {
        if let provider = providers[source.id], provider.manifest == source.manifest { return provider }
        // Keep the same client across tests and fetches, including its rate-limit cooldown.
        let provider = try makeProvider(source.manifest)
        providers[source.id] = provider
        return provider
    }
}
