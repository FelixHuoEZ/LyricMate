#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
import Foundation
import Observation

enum LyricSourceFormat: String, Codable, Sendable {
    case lyricfeverV1, lrclib, amllTTML, kugou, netease, kuwo, qqMusic, migu
}

struct LyricSourceManifest: Codable, Equatable, Sendable {
    struct Authentication: Codable, Equatable, Sendable {
        let type: String
        var token: String? = nil
    }

    let schemaVersion: Int
    let apiVersion: Int
    let name: String
    let baseURL: String
    let capabilities: [String]
    let auth: Authentication
    var format: LyricSourceFormat? = nil

    var apiFormat: LyricSourceFormat { format ?? .lyricfeverV1 }

    func validatedURL() throws -> URL {
        guard schemaVersion == 1, apiVersion == 1 else { throw LyricSourceError.unsupportedVersion }
        guard auth.type == "none", auth.token == nil else { throw LyricSourceError.unsupportedAuthentication }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              Set(capabilities) == Set(["search", "syncedLyrics"]) else { throw LyricSourceError.invalidManifest }
        guard var components = URLComponents(string: baseURL), components.scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw LyricSourceError.unsafeURL }
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let url = components.url else { throw LyricSourceError.unsafeURL }
        if apiFormat == .amllTTML && url.absoluteString != AMLLSource.baseURL { throw LyricSourceError.unsafeURL }
        if let platform = PlatformLyricSource(rawValue: apiFormat.rawValue), url.absoluteString != platform.baseURL {
            throw LyricSourceError.unsafeURL
        }
        return url
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 else { throw LyricSourceError.responseTooLarge }
        let manifest: Self
        do { manifest = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw LyricSourceError.invalidManifest }
        _ = try manifest.validatedURL()
        return manifest
    }
}

struct LyricSourceConfiguration: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let manifest: LyricSourceManifest
    var isEnabled: Bool
}

@MainActor
@Observable
final class LyricSourceStore {
    private struct StoredSources: Codable {
        let schemaVersion: Int
        let sources: [LyricSourceConfiguration]
    }

    static let storageKey = "customLyricSources.v1"
    private(set) var sources: [LyricSourceConfiguration] = []
    private(set) var loadError: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            let stored = try JSONDecoder().decode(StoredSources.self, from: data)
            guard stored.schemaVersion == 1, stored.sources.count <= 16,
                  Set(stored.sources.map(\.id)).count == stored.sources.count else { throw LyricSourceError.invalidManifest }
            var services = Set<String>()
            for source in stored.sources {
                let url = try source.manifest.validatedURL()
                guard services.insert(url.absoluteString + source.manifest.apiFormat.rawValue).inserted else { throw LyricSourceError.duplicateSource }
            }
            sources = stored.sources
        } catch {
            loadError = L10n.text("Saved lyric sources could not be loaded. Import a valid configuration to replace them.")
        }
    }

    @discardableResult
    func importManifest(_ data: Data, enabled: Bool = true) throws -> LyricSourceConfiguration {
        let manifest = try LyricSourceManifest.decode(data)
        let url = try manifest.validatedURL()
        guard sources.count < 16 else { throw LyricSourceError.sourceLimit }
        guard !sources.contains(where: { (try? $0.manifest.validatedURL()) == url && $0.manifest.apiFormat == manifest.apiFormat }) else {
            throw LyricSourceError.duplicateSource
        }
        // Remote manifests never control local identities or enabled state.
        let source = LyricSourceConfiguration(id: UUID(), manifest: manifest, isEnabled: enabled)
        try save(sources + [source])
        return source
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) throws {
        var updated = sources
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].isEnabled = enabled
        try save(updated)
    }

    func remove(_ id: UUID) throws {
        try save(sources.filter { $0.id != id })
    }

    func installPlatformDefaults() throws {
        let key = "platformLyricSources.installed.v1"
        let miguKey = "miguLyricSource.installed.v1"
        guard loadError == nil, !defaults.bool(forKey: key) || !defaults.bool(forKey: miguKey) else { return }
        var updated = sources
        let additions = PlatformLyricSource.allCases.filter { $0 == .migu ? !defaults.bool(forKey: miguKey) : !defaults.bool(forKey: key) }
        for platform in additions where !updated.contains(where: { $0.manifest.apiFormat == platform.format }) {
            updated.append(.init(id: UUID(), manifest: platform.manifest, isEnabled: true))
        }
        try replaceValidated(updated)
        defaults.set(true, forKey: key)
        defaults.set(true, forKey: miguKey)
    }

    func replaceValidated(_ updated: [LyricSourceConfiguration]) throws {
        guard updated.count <= 16, Set(updated.map(\.id)).count == updated.count else { throw LyricSourceError.invalidManifest }
        var services = Set<String>()
        for source in updated {
            let url = try source.manifest.validatedURL()
            guard services.insert(source.manifest.apiFormat.rawValue + url.absoluteString).inserted else { throw LyricSourceError.duplicateSource }
        }
        try save(updated)
    }

    private func save(_ updated: [LyricSourceConfiguration]) throws {
        let data = try JSONEncoder().encode(StoredSources(schemaVersion: 1, sources: updated))
        defaults.set(data, forKey: Self.storageKey)
        sources = updated
        loadError = nil
    }
}
