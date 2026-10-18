import XCTest
@testable import LyricFeverCore

@MainActor
final class LyricSourceStoreTests: XCTestCase {
    private func withStore(_ action: (UserDefaults, LyricSourceStore) throws -> Void) throws {
        let suite = "LyricFeverTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try action(defaults, LyricSourceStore(defaults: defaults))
    }

    func testImportCreatesLocalIdentity() async throws {
        try withStore { _, store in
            let data = try JSONEncoder().encode(manifest())
            let source = try store.importManifest(data)
            XCTAssertTrue(source.isEnabled)
            XCTAssertEqual(store.sources.count, 1)
            XCTAssertEqual(source.manifest.name, "Test Source")
        }
    }

    func testEnableDeleteAndPersistence() async throws {
        try withStore { defaults, store in
            let source = try store.importManifest(JSONEncoder().encode(manifest()))
            try store.setEnabled(source.id, false)
            let loaded = LyricSourceStore(defaults: defaults)
            XCTAssertEqual(loaded.sources.first?.id, source.id)
            XCTAssertEqual(loaded.sources.first?.isEnabled, false)
            try loaded.remove(source.id)
            XCTAssertTrue(LyricSourceStore(defaults: defaults).sources.isEmpty)
        }
    }

    func testDuplicateURLIsRejected() async throws {
        try withStore { _, store in
            _ = try store.importManifest(JSONEncoder().encode(manifest()))
            XCTAssertThrowsError(try store.importManifest(JSONEncoder().encode(manifest(baseURL: "https://lyrics.example.com/prefix")))) {
                XCTAssertEqual($0 as? LyricSourceError, .duplicateSource)
            }
            XCTAssertEqual(store.sources.count, 1)
        }
    }

    func testInvalidImportDoesNotChangeExistingConfiguration() async throws {
        try withStore { _, store in
            let source = try store.importManifest(JSONEncoder().encode(manifest()))
            for data in [Data("javascript:alert(1)".utf8), Data("{}".utf8), Data(repeating: 32, count: 65537)] {
                XCTAssertThrowsError(try store.importManifest(data))
                XCTAssertEqual(store.sources, [source])
            }
        }
    }

    func testUnknownVersionAndAuthenticationAreRejected() async throws {
        for change in ["schemaVersion": 2, "apiVersion": 2] {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest())) as! [String: Any]
            json[change.key] = change.value
            XCTAssertThrowsError(try LyricSourceManifest.decode(JSONSerialization.data(withJSONObject: json))) {
                XCTAssertEqual($0 as? LyricSourceError, .unsupportedVersion)
            }
        }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest())) as! [String: Any]
        json["auth"] = ["type": "bearer", "token": "test-not-a-real-secret"]
        XCTAssertThrowsError(try LyricSourceManifest.decode(JSONSerialization.data(withJSONObject: json))) {
            XCTAssertEqual($0 as? LyricSourceError, .unsupportedAuthentication)
        }
    }

    func testUnsafeURLsAreRejected() async {
        for url in ["http://example.com", "file:///tmp/source", "https://user:password@example.com", "https://example.com?token=x", "https://example.com/#fragment", "javascript:alert(1)"] {
            XCTAssertThrowsError(try manifest(baseURL: url).validatedURL(), url)
        }
    }

    func testRemoteIdentityCannotOverrideBuiltin() async throws {
        try withStore { _, store in
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest())) as! [String: Any]
            json["id"] = "builtin.spotify"
            json["isEnabled"] = false
            let source = try store.importManifest(JSONSerialization.data(withJSONObject: json))
            XCTAssertTrue(source.isEnabled)
            XCTAssertNotEqual(source.id.uuidString, "builtin.spotify")
        }
    }

    func testCorruptSavedDataDoesNotOverwriteItself() async throws {
        try withStore { defaults, _ in
            let bad = Data("broken".utf8)
            defaults.set(bad, forKey: LyricSourceStore.storageKey)
            let store = LyricSourceStore(defaults: defaults)
            XCTAssertTrue(store.sources.isEmpty)
            XCTAssertNotNil(store.loadError)
            XCTAssertEqual(defaults.data(forKey: LyricSourceStore.storageKey), bad)
        }
    }

    func testSourceCountLimit() async throws {
        try withStore { _, store in
            for index in 0..<16 { _ = try store.importManifest(JSONEncoder().encode(manifest(baseURL: "https://lyrics.example.com/\(index)/"))) }
            XCTAssertThrowsError(try store.importManifest(JSONEncoder().encode(manifest(baseURL: "https://lyrics.example.com/extra/")))) {
                XCTAssertEqual($0 as? LyricSourceError, .sourceLimit)
            }
        }
    }
}
