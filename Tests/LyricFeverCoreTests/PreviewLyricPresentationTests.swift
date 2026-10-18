import LyricMateLocalization
import XCTest
@testable import LyricFeverCore

@MainActor
final class PreviewLyricPresentationTests: XCTestCase {
    private func snapshot(_ id: String = "A", position: Double = 1500, playing: Bool = true) -> PlaybackSnapshot {
        .init(trackID: id, trackName: "Song", artistName: "Artist", albumName: "Album", durationMS: 30000,
              positionMS: position, isPlaying: playing)
    }
    private func session(lines: [LyricLine]? = nil) async -> LyricPreviewSession {
        let candidate = SongResult(lyricType: "Fixture", songName: "Song", albumName: "Album", artistName: "Artist",
                                   lyrics: lines ?? [.init(startTime: 1000, words: "First line"), .init(startTime: 2500, words: "Next line")], durationMS: 30000)
        let source = FakeProvider("Fixture") { _ in .init(lyrics: [], colorData: nil) }
        source.searchAction = { _, _ in [candidate] }
        let session = LyricPreviewSession(providers: [source])
        session.updatePlayback(snapshot(), autoSearch: false)
        await session.search()?.value
        return session
    }

    func testLiveLineAndNextLineShareSessionIndex() async {
        let session = await session()
        let view = PreviewLyricPresentation(session: session)
        XCTAssertEqual(view.mode, .playing)
        XCTAssertEqual(view.currentLine, "First line")
        XCTAssertEqual(view.nextLine, "Next line")
        XCTAssertEqual(view.menuTitle(showsLyrics: true), "First line")
        XCTAssertEqual(view.menuTitle(showsLyrics: false), "Song")
        XCTAssertEqual(view.positionMS, 1500)
    }
    func testPauseIsExplicitAndDoesNotAdvance() async {
        let session = await session()
        session.updatePlayback(snapshot(position: 1500, playing: false), autoSearch: false)
        let view = PreviewLyricPresentation(session: session)
        XCTAssertEqual(view.mode, .paused)
        XCTAssertEqual(view.currentLine, "First line")
        XCTAssertEqual(view.menuTitle(showsLyrics: true), (L10n.text("Paused · ") + "Song"))
        XCTAssertEqual(view.status, L10n.text("Paused"))
    }
    func testReadFailureNeverShowsStaleLiveLyricsOrMetadata() async {
        let session = await session()
        session.updatePlayback(nil)
        let view = PreviewLyricPresentation(session: session)
        XCTAssertEqual(view.mode, .unavailable)
        XCTAssertEqual(view.currentLine, L10n.text("Playback following interrupted"))
        XCTAssertNil(view.nextLine)
        XCTAssertNil(view.positionMS)
        XCTAssertFalse(view.hasActiveLine)
        XCTAssertEqual(view.title, "")
        XCTAssertEqual(view.menuTitle(showsLyrics: true), "LyricMate")
    }
    func testInitialDisconnectedState() {
        let view = PreviewLyricPresentation(session: LyricPreviewSession(providers: []))
        XCTAssertEqual(view.currentLine, L10n.text("Waiting for Spotify"))
        XCTAssertEqual(view.mode, .unavailable)
        XCTAssertEqual(view.menuTitle(showsLyrics: true), "LyricMate")
    }
    func testEmptyAndFailedSourcesHaveDifferentVisibleStates() async {
        let session = LyricPreviewSession(providers: [])
        session.updatePlayback(snapshot(), autoSearch: false)
        await session.search()?.value
        let empty = PreviewLyricPresentation(session: session)
        XCTAssertEqual(empty.currentLine, L10n.text("No timed lyrics"))
        XCTAssertEqual(empty.rows(showsNextLine: true).count, 1)
        XCTAssertFalse(empty.hasVisibleLyrics)
        let failed = FakeProvider("Unavailable") { _ in .init(lyrics: [], colorData: nil) }
        failed.searchAction = { _, _ in throw URLError(.badServerResponse) }
        let failure = LyricPreviewSession(providers: [failed])
        failure.updatePlayback(snapshot(), autoSearch: false)
        await failure.search()?.value
        XCTAssertEqual(PreviewLyricPresentation(session: failure).currentLine, L10n.text("No usable lyrics retrieved"))
        XCTAssertTrue(failure.unselectedLyricsDetail.contains(L10n.text("Some sources failed. Check the errors and retry; a failed request does not mean the catalog has no lyrics.")))
        XCTAssertFalse(PreviewLyricPresentation(session: failure).hasActiveLine)
    }
    func testManualCursorCannotMasqueradeAsLivePlayback() async {
        let session = await session()
        session.followsPlayback = false
        session.previewPositionMS = 2600
        let view = PreviewLyricPresentation(session: session)
        XCTAssertEqual(view.mode, .manual)
        XCTAssertEqual(view.currentLine, "Next line")
        XCTAssertEqual(view.menuTitle(showsLyrics: true), (L10n.text("Preview · ") + "Song"))
        XCTAssertEqual(view.status, L10n.text("Manual preview"))
        XCTAssertEqual(session.playback?.positionMS, 1500)
    }
    func testBeforeFirstLineAndEndAreBounded() async {
        let session = await session()
        session.updatePlayback(snapshot(position: 0), autoSearch: false)
        var view = PreviewLyricPresentation(session: session)
        XCTAssertEqual(view.currentLine, "First line")
        XCTAssertEqual(view.nextLine, "Next line")
        XCTAssertFalse(view.hasActiveLine)
        XCTAssertTrue(view.hasVisibleLyrics)
        XCTAssertTrue(view.isWaitingToSing)
        session.updatePlayback(snapshot(position: 29999), autoSearch: false)
        view = PreviewLyricPresentation(session: session)
        XCTAssertEqual(view.currentLine, "Next line")
        XCTAssertNil(view.nextLine)
    }
    func testInstrumentalAndBlankNextLinesHaveExplicitPresentation() async {
        let session = await session(lines: [.init(startTime: 1000, words: "Opening"), .init(startTime: 2000, words: " "),
                                           .init(startTime: 3000, words: "Return")])
        session.updatePlayback(snapshot(position: 2500), autoSearch: false)
        let view = PreviewLyricPresentation(session: session)
        XCTAssertEqual(view.currentLine, L10n.text("Instrumental break"))
        XCTAssertEqual(view.nextLine, "Return")
    }
    func testTrackChangeImmediatelyRemovesOldLyrics() async {
        let session = await session()
        session.updatePlayback(snapshot("B"), autoSearch: false)
        let view = PreviewLyricPresentation(session: session)
        XCTAssertEqual(view.currentLine, L10n.text("No timed lyrics"))
        XCTAssertNil(view.nextLine)
        XCTAssertFalse(view.hasActiveLine)
    }
    func testForwardBackwardSeekAndOffsetUseExistingTimeline() async {
        let session = await session()
        session.updatePlayback(snapshot(position: 2600), autoSearch: false)
        XCTAssertEqual(PreviewLyricPresentation(session: session).currentLine, "Next line")
        session.offsetMS = 200
        XCTAssertEqual(PreviewLyricPresentation(session: session).currentLine, "First line")
        session.updatePlayback(snapshot(position: 1200), autoSearch: false)
        XCTAssertEqual(PreviewLyricPresentation(session: session).currentLine, "First line")
    }
    func testDisplaySanitizationDoesNotChangeStoredLyricsOrIdentity() async {
        let raw = " First\u{001f}line\n  text "
        let session = await session(lines: [.init(startTime: 1000, words: raw)])
        let fingerprint = session.selected.map(PreviewRecordingPreferences.fingerprint)
        XCTAssertEqual(PreviewLyricPresentation(session: session).currentLine, "First line text")
        XCTAssertEqual(session.selected?.lyrics.first?.words, raw)
        XCTAssertEqual(session.selected.map(PreviewRecordingPreferences.fingerprint), fingerprint)
    }
    func testLongDisplayAndMenuTitlesAreBoundedAtCharacterBoundaries() async {
        let session = await session(lines: [.init(startTime: 1000, words: String(repeating: "中文", count: 1000))])
        let view = PreviewLyricPresentation(session: session)
        XCTAssertEqual(view.currentLine.count, 401)
        XCTAssertEqual(view.menuTitle(showsLyrics: true).count, 29)
        XCTAssertEqual(view.menuTitle(showsLyrics: true, limit: 0), "中…")
    }

    func testIntroDotsUseOffsetAndMediaPositionAndFreezeWhenPaused() async {
        let session = await session(lines: [.init(startTime: 0, words: "作词：Synthetic"),
                                           .init(startTime: 5000, words: "First"), .init(startTime: 8000, words: "Second")])
        for (time, expected) in [(0.0, []), (1999, []), (2000, [1.0, 1, 1]), (2500, [0.5, 1, 1]),
                                 (3000, [0, 1, 1]), (4000, [0, 0, 1]), (4500, [0, 0, 0.5])] {
            session.updatePlayback(snapshot(position: time), autoSearch: false)
            let view = PreviewLyricPresentation(session: session)
            XCTAssertEqual(view.currentLine, "First")
            XCTAssertEqual(view.nextLine, "Second")
            XCTAssertEqual(view.countdownDots, expected)
            XCTAssertTrue(view.isWaitingToSing)
            XCTAssertFalse(view.hasActiveLine)
            XCTAssertEqual(view.menuTitle(showsLyrics: true), "First")
        }
        session.updatePlayback(snapshot(position: 4500, playing: false), autoSearch: false)
        let paused = PreviewLyricPresentation(session: session)
        await Task.yield()
        XCTAssertEqual(PreviewLyricPresentation(session: session).countdownDots, paused.countdownDots)
        session.offsetMS = 1000
        XCTAssertEqual(PreviewLyricPresentation(session: session).countdownDots, [0, 0.5, 1])
        session.offsetMS = -1000
        XCTAssertTrue(PreviewLyricPresentation(session: session).hasActiveLine)
        XCTAssertTrue(PreviewLyricPresentation(session: session).countdownDots.isEmpty)
        session.updatePlayback(nil)
        XCTAssertFalse(PreviewLyricPresentation(session: session).hasVisibleLyrics)
        XCTAssertTrue(PreviewLyricPresentation(session: session).countdownDots.isEmpty)
    }

    func testAtFirstStartDotsDisappearAndSeekBackRestoresIntro() async {
        let session = await session(lines: [.init(startTime: 5000, words: "First"), .init(startTime: 8000, words: "Second")])
        session.updatePlayback(snapshot(position: 5000), autoSearch: false)
        let active = PreviewLyricPresentation(session: session)
        XCTAssertTrue(active.hasActiveLine)
        XCTAssertFalse(active.isWaitingToSing)
        XCTAssertTrue(active.countdownDots.isEmpty)
        session.updatePlayback(snapshot(position: 1000), autoSearch: false)
        XCTAssertTrue(PreviewLyricPresentation(session: session).isWaitingToSing)
        session.followsPlayback = false
        session.previewPositionMS = 3000
        XCTAssertEqual(PreviewLyricPresentation(session: session).countdownDots, [0, 1, 1])
    }

    func testZeroStartDoesNotInventAnIntroOrDropASungTitle() async {
        let session = await session(lines: [.init(startTime: 0, words: "Song"), .init(startTime: 1000, words: "Next")])
        session.updatePlayback(snapshot(position: 0), autoSearch: false)
        let view = PreviewLyricPresentation(session: session)
        XCTAssertEqual(view.currentLine, "Song")
        XCTAssertEqual(view.nextLine, "Next")
        XCTAssertFalse(view.isWaitingToSing)
        XCTAssertTrue(view.countdownDots.isEmpty)
    }

    func testSingleTimedLineCanWaitWithoutInventingSecondLine() async {
        let session = await session(lines: [.init(startTime: 5000, words: "Only")])
        session.updatePlayback(snapshot(position: 0), autoSearch: false)
        let view = PreviewLyricPresentation(session: session)
        XCTAssertEqual(view.currentLine, "Only")
        XCTAssertNil(view.nextLine)
        XCTAssertTrue(view.isWaitingToSing)
    }

    func testContinuousPlaybackPromotesTheSameNextRowIdentity() async {
        let session = await session(lines: [.init(startTime: 1000, words: "First"),
                                           .init(startTime: 2500, words: "Second"), .init(startTime: 4000, words: "Third")])
        session.updatePlayback(snapshot(position: 2400), autoSearch: false)
        let before = PreviewLyricPresentation(session: session)
        session.updatePlayback(snapshot(position: 2600), autoSearch: false)
        let after = PreviewLyricPresentation(session: session)
        XCTAssertTrue(after.pushesUp(from: before))
        XCTAssertEqual(before.rows(showsNextLine: true)[1].id, after.rows(showsNextLine: true)[0].id)
        XCTAssertEqual(after.rows(showsNextLine: true).map(\.text), ["Second", "Third"])
        XCTAssertTrue(after.rows(showsNextLine: true)[0].isCurrent)
        XCTAssertFalse(after.rows(showsNextLine: true)[1].isCurrent)
        XCTAssertEqual(after.rows(showsNextLine: false).count, 1)
    }

    func testRepeatedTextStillHasDistinctRowsAndPushes() async {
        let session = await session(lines: [.init(startTime: 1000, words: "Repeat"),
                                           .init(startTime: 2500, words: "Repeat"), .init(startTime: 4000, words: "Repeat")])
        session.updatePlayback(snapshot(position: 2400), autoSearch: false)
        let before = PreviewLyricPresentation(session: session)
        XCTAssertNotEqual(before.currentLineID, before.nextLineID)
        session.updatePlayback(snapshot(position: 2500), autoSearch: false)
        let after = PreviewLyricPresentation(session: session)
        XCTAssertEqual(before.currentLine, after.currentLine)
        XCTAssertTrue(after.pushesUp(from: before))
        XCTAssertEqual(Set(after.rows(showsNextLine: true).map(\.id)).count, 2)
    }

    func testFirstStartPromotesQueuedLyricFromBelowCountdown() async {
        let session = await session(lines: [.init(startTime: 0, words: "作词：Fixture"),
                                           .init(startTime: 5000, words: "First"), .init(startTime: 8000, words: "Second")])
        session.updatePlayback(snapshot(position: 4500), autoSearch: false)
        let intro = PreviewLyricPresentation(session: session)
        session.updatePlayback(snapshot(position: 5000), autoSearch: false)
        let start = PreviewLyricPresentation(session: session)
        XCTAssertEqual(intro.currentLineID, start.currentLineID)
        XCTAssertEqual(intro.nextLineID, start.nextLineID)
        XCTAssertTrue(start.pushesUp(from: intro))
        XCTAssertTrue(intro.rows(showsNextLine: true)[0].isCountdown)
        XCTAssertEqual(intro.rows(showsNextLine: true)[1].id, start.rows(showsNextLine: true)[0].id)
        XCTAssertEqual(start.rows(showsNextLine: true).map(\.text), ["First", "Second"])
        XCTAssertFalse(start.pushesUp(from: start))
        session.updatePlayback(snapshot(position: 8100), autoSearch: false)
        XCTAssertFalse(PreviewLyricPresentation(session: session).pushesUp(from: intro))
    }

    func testIntroReservesTopCueAndOnlyFirstLyricBelowThroughoutCountdown() async {
        let session = await session(lines: [.init(startTime: 0, words: "作词：Fixture"),
                                           .init(startTime: 5000, words: "First"), .init(startTime: 8000, words: "Second")])
        var rowIDs: [PreviewLyricPresentation.Row.ID] = []
        for time in [0.0, 1999, 2000, 3000, 4000, 4999] {
            session.updatePlayback(snapshot(position: time), autoSearch: false)
            let view = PreviewLyricPresentation(session: session)
            for next in [true, false] {
                let rows = view.rows(showsNextLine: next)
                XCTAssertTrue(view.usesTwoRows(showsNextLine: next))
                XCTAssertEqual(rows.count, 2)
                XCTAssertTrue(rows[0].isCountdown)
                XCTAssertEqual(rows[0].text, "")
                XCTAssertEqual(rows[1].text, "First")
                XCTAssertFalse(rows[1].isCurrent)
                if rowIDs.isEmpty { rowIDs = rows.map(\.id) }
                XCTAssertEqual(rows.map(\.id), rowIDs)
            }
        }
        session.updatePlayback(snapshot(position: 5000), autoSearch: false)
        let active = PreviewLyricPresentation(session: session)
        XCTAssertFalse(active.usesTwoRows(showsNextLine: false))
        XCTAssertEqual(active.rows(showsNextLine: false).count, 1)
        XCTAssertFalse(active.rows(showsNextLine: true).contains(where: \.isCountdown))
    }

    func testIntroPromotionRespectsPauseSeekAndOffset() async {
        let session = await session(lines: [.init(startTime: 5000, words: "First"), .init(startTime: 8000, words: "Second")])
        session.updatePlayback(snapshot(position: 4500, playing: false), autoSearch: false)
        let paused = PreviewLyricPresentation(session: session)
        session.updatePlayback(snapshot(position: 5000, playing: false), autoSearch: false)
        XCTAssertFalse(PreviewLyricPresentation(session: session).pushesUp(from: paused))
        session.updatePlayback(snapshot(position: 1000), autoSearch: false)
        let distant = PreviewLyricPresentation(session: session)
        session.updatePlayback(snapshot(position: 5000), autoSearch: false)
        let started = PreviewLyricPresentation(session: session)
        XCTAssertFalse(started.pushesUp(from: distant))
        session.updatePlayback(snapshot(position: 4500), autoSearch: false)
        let waiting = PreviewLyricPresentation(session: session)
        XCTAssertFalse(waiting.pushesUp(from: started))
        session.offsetMS = -1000
        XCTAssertFalse(PreviewLyricPresentation(session: session).pushesUp(from: waiting))
    }

    func testSingleLyricHasCueAboveItWithoutInventingNextLyric() async {
        let session = await session(lines: [.init(startTime: 5000, words: "Only")])
        session.updatePlayback(snapshot(position: 4000), autoSearch: false)
        let intro = PreviewLyricPresentation(session: session)
        XCTAssertEqual(intro.rows(showsNextLine: false).map(\.text), ["", "Only"])
        session.updatePlayback(snapshot(position: 5000), autoSearch: false)
        let active = PreviewLyricPresentation(session: session)
        XCTAssertTrue(active.pushesUp(from: intro))
        XCTAssertEqual(active.rows(showsNextLine: true).map(\.text), ["Only"])
        XCTAssertNil(active.nextLine)
    }

    func testSeekDelayedPollAndSkippedRowsSnapInsteadOfPushing() async {
        let session = await session(lines: [.init(startTime: 1000, words: "First"),
                                           .init(startTime: 2500, words: "Second"), .init(startTime: 3000, words: "Third")])
        session.updatePlayback(snapshot(position: 1100), autoSearch: false)
        let first = PreviewLyricPresentation(session: session)
        session.updatePlayback(snapshot(position: 2900), autoSearch: false)
        let delayed = PreviewLyricPresentation(session: session)
        XCTAssertFalse(delayed.pushesUp(from: first))
        session.updatePlayback(snapshot(position: 2400), autoSearch: false)
        let before = PreviewLyricPresentation(session: session)
        session.updatePlayback(snapshot(position: 3100), autoSearch: false)
        let skipped = PreviewLyricPresentation(session: session)
        XCTAssertFalse(skipped.pushesUp(from: before))
        session.updatePlayback(snapshot(position: 2400), autoSearch: false)
        XCTAssertFalse(PreviewLyricPresentation(session: session).pushesUp(from: skipped))
    }

    func testPauseManualAndOffsetChangesDoNotPush() async {
        let session = await session()
        session.updatePlayback(snapshot(position: 2400), autoSearch: false)
        let before = PreviewLyricPresentation(session: session)
        session.updatePlayback(snapshot(position: 2500, playing: false), autoSearch: false)
        let paused = PreviewLyricPresentation(session: session)
        XCTAssertFalse(paused.pushesUp(from: before))
        session.updatePlayback(snapshot(position: 2600), autoSearch: false)
        XCTAssertFalse(PreviewLyricPresentation(session: session).pushesUp(from: paused))
        session.followsPlayback = false; session.previewPositionMS = 2400
        let manual = PreviewLyricPresentation(session: session)
        session.previewPositionMS = 2500
        XCTAssertFalse(PreviewLyricPresentation(session: session).pushesUp(from: manual))
        session.followsPlayback = true
        session.updatePlayback(snapshot(position: 2400), autoSearch: false)
        let offsetBefore = PreviewLyricPresentation(session: session)
        session.offsetMS = -200
        session.updatePlayback(snapshot(position: 2450), autoSearch: false)
        let offsetAfter = PreviewLyricPresentation(session: session)
        XCTAssertNotEqual(offsetBefore.currentLineID, offsetAfter.currentLineID)
        XCTAssertFalse(offsetAfter.pushesUp(from: offsetBefore))
    }

    func testDisconnectTrackAndCandidateChangesNeverReuseOldRows() async {
        let session = await session()
        let before = PreviewLyricPresentation(session: session)
        session.updatePlayback(nil)
        let disconnected = PreviewLyricPresentation(session: session)
        XCTAssertFalse(disconnected.pushesUp(from: before))
        XCTAssertNil(disconnected.currentLineID)
        XCTAssertNil(disconnected.nextLineID)
        XCTAssertEqual(disconnected.rows(showsNextLine: true).count, 1)
        session.updatePlayback(snapshot(position: 2500), autoSearch: false)
        XCTAssertFalse(PreviewLyricPresentation(session: session).pushesUp(from: disconnected))
        let restored = PreviewLyricPresentation(session: session)
        let alternate = SongResult(lyricType: "Local", songName: "Song", albumName: "Album", artistName: "Artist",
                                   lyrics: session.selected!.lyrics, durationMS: 30000)
        session.presentLocal(alternate)
        XCTAssertNotEqual(PreviewLyricPresentation(session: session).lyricIdentity, restored.lyricIdentity)
        XCTAssertFalse(PreviewLyricPresentation(session: session).pushesUp(from: restored))
        session.updatePlayback(snapshot("B"), autoSearch: false)
        let changed = PreviewLyricPresentation(session: session)
        XCTAssertFalse(changed.pushesUp(from: restored))
        XCTAssertNil(changed.currentLineID)
    }

    func testPushIntoLastLineDoesNotInventANextRow() async {
        let session = await session()
        session.updatePlayback(snapshot(position: 2400), autoSearch: false)
        let before = PreviewLyricPresentation(session: session)
        session.updatePlayback(snapshot(position: 2500), autoSearch: false)
        let last = PreviewLyricPresentation(session: session)
        XCTAssertTrue(last.pushesUp(from: before))
        XCTAssertEqual(last.rows(showsNextLine: true).count, 1)
        XCTAssertNil(last.nextLineID)
    }
}
