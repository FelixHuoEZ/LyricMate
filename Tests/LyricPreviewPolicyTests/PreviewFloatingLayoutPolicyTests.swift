import XCTest
@testable import LyricPreviewPolicy

final class PreviewFloatingLayoutPolicyTests: XCTestCase {
    func testShortLyricsKeepDefaultWidth() {
        XCTAssertEqual(PreviewFloatingLayoutPolicy.width(textWidth: 200, screenWidth: 1920), 720)
    }

    func testLongLyricsWidenBeforeScaling() {
        XCTAssertEqual(PreviewFloatingLayoutPolicy.width(textWidth: 900, screenWidth: 1920), 988)
        XCTAssertEqual(PreviewFloatingLayoutPolicy.width(textWidth: 5000, screenWidth: 1920), 1200)
    }

    func testWidthStaysInsideNarrowScreen() {
        XCTAssertEqual(PreviewFloatingLayoutPolicy.width(textWidth: 900, screenWidth: 800), 768)
        XCTAssertEqual(PreviewFloatingLayoutPolicy.width(textWidth: 100, screenWidth: 600), 568)
        XCTAssertEqual(PreviewFloatingLayoutPolicy.width(textWidth: 900, screenWidth: 20), 1)
    }

    func testNonfiniteDimensionsAreSafe() {
        XCTAssertEqual(PreviewFloatingLayoutPolicy.width(textWidth: .nan, screenWidth: .infinity), 720)
        XCTAssertEqual(PreviewFloatingLayoutPolicy.width(textWidth: -.infinity, screenWidth: -1), 720)
        XCTAssertEqual(PreviewFloatingLayoutPolicy.height(fontSize: .nan, showsNextLine: true, locked: false), 134)
    }

    func testControlsReserveStableHeightWithoutHoverDependency() {
        let unlocked = PreviewFloatingLayoutPolicy.height(fontSize: 30, showsNextLine: true, locked: false)
        let locked = PreviewFloatingLayoutPolicy.height(fontSize: 30, showsNextLine: true, locked: true)
        XCTAssertEqual(unlocked - locked, 40)
        XCTAssertLessThan(PreviewFloatingLayoutPolicy.height(fontSize: 30, showsNextLine: false, locked: false), unlocked)
        XCTAssertLessThanOrEqual(PreviewFloatingLayoutPolicy.height(fontSize: 48, showsNextLine: true, locked: false), 220)
    }

    func testVisibilityRequiresHoverUnlockedVisibleLyrics() {
        XCTAssertTrue(PreviewFloatingLayoutPolicy.showsControls(hovered: true, locked: false, visible: true))
        XCTAssertFalse(PreviewFloatingLayoutPolicy.showsControls(hovered: false, locked: false, visible: true))
        XCTAssertFalse(PreviewFloatingLayoutPolicy.showsControls(hovered: true, locked: true, visible: true))
        XCTAssertFalse(PreviewFloatingLayoutPolicy.showsControls(hovered: true, locked: false, visible: false))
    }

    func testControlStripCannotStartWindowDrag() {
        XCTAssertFalse(PreviewFloatingLayoutPolicy.startsDrag(y: 20, locked: false))
        XCTAssertFalse(PreviewFloatingLayoutPolicy.startsDrag(y: 46, locked: false))
        XCTAssertTrue(PreviewFloatingLayoutPolicy.startsDrag(y: 47, locked: false))
        XCTAssertFalse(PreviewFloatingLayoutPolicy.startsDrag(y: 90, locked: true))
        XCTAssertFalse(PreviewFloatingLayoutPolicy.startsDrag(y: .nan, locked: false))
    }
}
