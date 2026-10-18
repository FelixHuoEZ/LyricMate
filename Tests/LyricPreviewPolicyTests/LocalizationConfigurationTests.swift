import XCTest
import LyricMateLocalization
@testable import LyricFeverCore
@testable import LyricPreviewPolicy

@MainActor
final class LocalizationConfigurationTests: XCTestCase {
    func testLegacyV1SettingsAndConfigurationsAreReadWithoutMigrationOrWrites() throws {
        let suite = "lyricmate.localization.fixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sourceID = "00000000-0000-4000-8000-000000000001"
        let sources = Data("""
        {"schemaVersion":1,"sources":[{"id":"\(sourceID)","manifest":{"schemaVersion":1,"apiVersion":1,"name":"Fixture 中文 source","baseURL":"https://example.com/","capabilities":["search","syncedLyrics"],"auth":{"type":"none"}},"isEnabled":true}]}
        """.utf8)
        let choices = Data("""
        {"schemaVersion":1,"entries":[{"recording":{"id":"spotify:track:Fixture1","title":"Synthetic 中文","artist":"Fixture","album":"Album","durationMS":30000},"candidateSHA256":"\(String(repeating: "a", count: 64))","offsetMS":-350}]}
        """.utf8)
        defaults.setPersistentDomain([
            "presentation.floatingVisible": true, "startup.resumeSpotify": true,
            "presentation.menuLyrics": false, "presentation.nextLine": false, "presentation.locked": true,
            "presentation.fontSize": 42.0, "presentation.shadowOpacity": 0.6,
            "presentation.frame": "{{120, 80}, {900, 140}}",
            "customLyricSources.v1": sources, "previewRecordingChoices.v1": choices,
            "platformLyricSources.installed.v1": true, "miguLyricSource.installed.v1": true
        ], forName: suite)
        let before = try XCTUnwrap(defaults.persistentDomain(forName: suite)) as NSDictionary
        for language in ["en", "zh-Hans", "fr"] {
            _ = L10n.localized("Show next line", preferences: [language])
            let settings = PreviewPresentationSettings(defaults: defaults)
            XCTAssertTrue(settings.showsFloatingLyrics && settings.resumesSpotify && settings.locked)
            XCTAssertFalse(settings.showsMenuLyrics || settings.showsNextLine)
            XCTAssertEqual(settings.fontSize, 42)
            XCTAssertEqual(settings.shadowOpacity, 0.6)
            XCTAssertEqual(settings.savedFrame, "{{120, 80}, {900, 140}}")
            let store = LyricSourceStore(defaults: defaults)
            XCTAssertNil(store.loadError)
            XCTAssertEqual(store.sources.first?.id.uuidString, sourceID)
            XCTAssertEqual(store.sources.first?.manifest.name, "Fixture 中文 source")
            XCTAssertEqual(store.sources.first?.isEnabled, true)
            let memory = PreviewRecordingPreferences(defaults: defaults)
            XCTAssertNil(memory.loadError)
            XCTAssertEqual(memory.entries.first?.offsetMS, -350)
            XCTAssertEqual(memory.entries.first?.recording.title, "Synthetic 中文")
            XCTAssertEqual(defaults.data(forKey: "customLyricSources.v1"), sources)
            XCTAssertEqual(defaults.data(forKey: "previewRecordingChoices.v1"), choices)
            XCTAssertEqual(try XCTUnwrap(defaults.persistentDomain(forName: suite)) as NSDictionary, before)
        }
    }
}
