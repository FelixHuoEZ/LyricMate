import Foundation
import XCTest
@testable import LyricFeverCore

@MainActor
final class LyricSourceRegistryTests: XCTestCase {
    func testEnabledProvidersPreserveImportOrderAndIgnoreDisabledSources() throws {
        let domain = "LyricFever.RegistryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = LyricSourceStore(defaults: defaults)
        let first = try store.importManifest(JSONEncoder().encode(manifest(baseURL: "https://first.example.com/")))
        let second = try store.importManifest(JSONEncoder().encode(manifest(baseURL: "https://second.example.com/")))
        let registry = LyricSourceRegistry(store: store)
        let beforeDisable = registry.enabledProviders
        XCTAssertEqual(beforeDisable.count, 2)
        XCTAssertTrue((beforeDisable[0] as? CustomHTTPSourceProvider) === (try registry.provider(for: first)))
        XCTAssertTrue((beforeDisable[1] as? CustomHTTPSourceProvider) === (try registry.provider(for: second)))
        try store.setEnabled(first.id, false)
        XCTAssertEqual(registry.enabledProviders.count, 1)
        XCTAssertTrue((registry.enabledProviders[0] as? CustomHTTPSourceProvider) === (beforeDisable[1] as? CustomHTTPSourceProvider))
        // An already captured request keeps its provider snapshot; future requests do not.
        XCTAssertEqual(beforeDisable.count, 2)
        try store.setEnabled(first.id, true)
        XCTAssertTrue((registry.enabledProviders[0] as? CustomHTTPSourceProvider) === (beforeDisable[0] as? CustomHTTPSourceProvider))
    }

    func testTestsAndFetchesReuseProviderAndRemovedProvidersArePruned() throws {
        let domain = "LyricFever.RegistryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = LyricSourceStore(defaults: defaults)
        let source = try store.importManifest(JSONEncoder().encode(manifest()))
        var creations = 0
        let registry = LyricSourceRegistry(store: store) {
            creations += 1
            return try CustomHTTPSourceProvider(manifest: $0)
        }
        weak var released: CustomHTTPSourceProvider?
        do {
            let testProvider = try registry.provider(for: source)
            released = testProvider
            XCTAssertTrue((registry.enabledProviders.first as? CustomHTTPSourceProvider) === testProvider)
            XCTAssertEqual(creations, 1)
        }
        try store.remove(source.id)
        XCTAssertTrue(registry.enabledProviders.isEmpty)
        XCTAssertNil(released)
        let reimported = try store.importManifest(JSONEncoder().encode(manifest()))
        XCTAssertNotEqual(source.id, reimported.id)
        _ = try registry.provider(for: reimported)
        XCTAssertEqual(creations, 2)
    }

    func testReloadUsesPersistedEnabledStateAndDoesNotConstructDisabledProvider() throws {
        let domain = "LyricFever.RegistryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = LyricSourceStore(defaults: defaults)
        let source = try store.importManifest(JSONEncoder().encode(manifest()))
        try store.setEnabled(source.id, false)
        var creations = 0
        let reloaded = LyricSourceRegistry(store: LyricSourceStore(defaults: defaults)) {
            creations += 1
            return try CustomHTTPSourceProvider(manifest: $0)
        }
        XCTAssertEqual(reloaded.store.sources.first?.id, source.id)
        XCTAssertTrue(reloaded.enabledProviders.isEmpty)
        XCTAssertEqual(creations, 0)
    }
}
