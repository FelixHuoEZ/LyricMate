import XCTest
@testable import LyricPreviewPolicy

@MainActor
final class PreviewPresentationSettingsTests: XCTestCase {
    func testFreshInstallDoesNotRestoreConnectionOrFloatingWindow() {
        let suite = "preview.settings.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PreviewPresentationSettings(defaults: defaults)
        XCTAssertFalse(settings.resumesSpotify)
        XCTAssertFalse(settings.showsFloatingLyrics)
    }

    func testAllPresentationSettingsSurviveNewInstanceAndOptOut() {
        let suite = "preview.settings.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PreviewPresentationSettings(defaults: defaults)
        first.resumesSpotify = true; first.showsFloatingLyrics = true
        first.locked = true; first.showsMenuLyrics = false; first.showsNextLine = false
        first.fontSize = 42; first.shadowOpacity = 0.6; first.savedFrame = "{{120, 80}, {900, 140}}"
        let next = PreviewPresentationSettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(next.resumesSpotify); XCTAssertTrue(next.showsFloatingLyrics); XCTAssertTrue(next.locked)
        XCTAssertFalse(next.showsMenuLyrics); XCTAssertFalse(next.showsNextLine)
        XCTAssertEqual(next.fontSize, 42); XCTAssertEqual(next.shadowOpacity, 0.6)
        XCTAssertEqual(next.savedFrame, first.savedFrame)
        next.resumesSpotify = false; next.showsFloatingLyrics = false
        let final = PreviewPresentationSettings(defaults: defaults)
        XCTAssertFalse(final.resumesSpotify); XCTAssertFalse(final.showsFloatingLyrics)
    }
}
