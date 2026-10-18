#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
import Foundation

/// A read-only projection shared by the menu bar and floating lyrics.
struct PreviewLyricPresentation: Equatable {
    static let appName = "LyricMate"
    enum Mode: Equatable { case playing, paused, manual, unavailable }
    let mode: Mode
    let title: String
    let artist: String
    let currentLine: String
    let nextLine: String?
    let hasActiveLine: Bool
    let positionMS: Double?
    let hasVisibleLyrics: Bool
    let isWaitingToSing: Bool
    let countdownDots: [Double]
    let lyricIdentity: UUID?
    let currentLineID: UUID?
    let nextLineID: UUID?
    let offsetMS: Double

    static let transitionDuration = 0.32

    @MainActor
    init(session: LyricPreviewSession) {
        let manual = !session.followsPlayback
        mode = manual ? .manual : !session.playbackAvailable ? .unavailable
            : session.playback?.isPlaying == true ? .playing : .paused
        title = Self.displayText(manual ? session.selected?.songName ?? session.trackQuery
                                 : session.playbackAvailable ? session.playback?.trackName ?? "" : "")
        artist = Self.displayText(manual ? session.selected?.artistName ?? session.artistQuery
                                  : session.playbackAvailable ? session.playback?.artistName ?? "" : "")
        positionMS = mode == .unavailable ? nil : session.displayedPositionMS
        offsetMS = session.offsetMS
        lyricIdentity = mode == .unavailable ? nil : session.selectedID
        hasVisibleLyrics = mode != .unavailable && session.selected != nil
        var waiting = false
        var dots: [Double] = []
        var currentID: UUID?
        var nextID: UUID?
        if mode == .unavailable {
            currentLine = session.playback == nil ? L10n.text("Waiting for Spotify") : L10n.text("Playback following interrupted")
            nextLine = nil
            hasActiveLine = false
        } else if let selected = session.selected {
            let index = session.activeIndex
            let singing = selected.lyrics.indices.filter {
                let text = Self.displayText(selected.lyrics[$0].words)
                return !text.isEmpty && !Self.isCredit(text, song: selected)
            }
            if let first = singing.first, index.map({ $0 < first }) ?? true {
                currentID = selected.lyrics[first].id
                currentLine = Self.displayText(selected.lyrics[first].words)
                let next = singing.dropFirst().first
                nextID = next.map { selected.lyrics[$0].id }
                nextLine = next.map { Self.displayText(selected.lyrics[$0].words) }
                hasActiveLine = false
                waiting = true
                let remaining = selected.lyrics[first].startTimeMS + session.offsetMS - session.displayedPositionMS
                // Follow the media clock (and user offset), never a separate wall-clock timer.
                if remaining > 0 && remaining <= 3000 {
                    dots = (0..<3).map { max(0, min(1, (remaining - Double(2 - $0) * 1000) / 1000)) }
                }
            } else if let index, selected.lyrics.indices.contains(index) {
                currentID = selected.lyrics[index].id
                let text = Self.displayText(selected.lyrics[index].words)
                currentLine = text.isEmpty ? L10n.text("Instrumental break") : text
                hasActiveLine = true
                let next = selected.lyrics.dropFirst(index + 1).first { !Self.displayText($0.words).isEmpty }
                nextID = next?.id
                nextLine = next.map { Self.displayText($0.words) }
            } else {
                currentLine = L10n.text("Waiting to sing")
                hasActiveLine = false
                let next = selected.lyrics.first { !Self.displayText($0.words).isEmpty }
                nextID = next?.id
                nextLine = next.map { Self.displayText($0.words) }
            }
        } else {
            currentLine = session.unselectedLyricsTitle
            nextLine = nil
            hasActiveLine = false
        }
        isWaitingToSing = waiting
        countdownDots = dots
        currentLineID = currentID
        nextLineID = nextID
    }

    /// Promote the queued lyric during continuous playback, including the opening cue.
    func pushesUp(from previous: Self) -> Bool {
        guard mode == .playing, previous.mode == .playing,
              hasVisibleLyrics, previous.hasVisibleLyrics,
              !isWaitingToSing,
              let lyricIdentity, lyricIdentity == previous.lyricIdentity,
              let currentLineID, offsetMS == previous.offsetMS,
              let positionMS, let previousPosition = previous.positionMS,
              positionMS.isFinite, previousPosition.isFinite else { return false }
        let advance = positionMS - previousPosition
        guard advance > 0 && advance <= 1500 else { return false }
        if previous.isWaitingToSing { return currentLineID == previous.currentLineID }
        return currentLineID != previous.currentLineID && currentLineID == previous.nextLineID
    }

    struct Row: Identifiable {
        enum ID: Hashable { case lyric(UUID), placeholder, countdown }
        let id: ID
        let text: String
        let isCurrent: Bool
        var isCountdown: Bool { id == .countdown }
    }

    func usesTwoRows(showsNextLine: Bool) -> Bool {
        showsNextLine || isWaitingToSing
    }

    func rows(showsNextLine: Bool) -> [Row] {
        if isWaitingToSing, let currentLineID {
            // Reserve the cue row throughout the intro, so the dots never displace the lyric.
            return [Row(id: .countdown, text: "", isCurrent: true),
                    Row(id: .lyric(currentLineID), text: currentLine, isCurrent: false)]
        }
        var rows = [Row(id: currentLineID.map(Row.ID.lyric) ?? .placeholder, text: currentLine, isCurrent: true)]
        if showsNextLine, let nextLine, let nextLineID {
            rows.append(Row(id: .lyric(nextLineID), text: nextLine, isCurrent: false))
        }
        return rows
    }

    var status: String {
        switch mode {
        case .playing: return L10n.text("Playing")
        case .paused: return L10n.text("Paused")
        case .manual: return L10n.text("Manual preview")
        case .unavailable: return L10n.text("Not connected")
        }
    }

    func menuTitle(showsLyrics: Bool, limit: Int = 28) -> String {
        let text: String
        switch mode {
        case .unavailable: text = Self.appName
        case .manual: text = L10n.text("Preview · ") + (title.isEmpty ? Self.appName : title)
        case .paused: text = L10n.text("Paused · ") + title
        case .playing: text = showsLyrics && hasVisibleLyrics ? currentLine : title
        }
        let count = max(1, limit)
        return text.count > count ? String(text.prefix(count)) + "…" : text
    }

    static func displayText(_ value: String) -> String {
        // Normalize only the display, never the candidate identity or lyric fingerprint.
        let scalars = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let text = scalars.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return text.count > 400 ? String(text.prefix(400)) + "…" : text
    }

    private static func isCredit(_ text: String, song: SongResult) -> Bool {
        // Only explicit credit labels and a combined title/artist header; a title alone may be sung.
        if text.range(of: #"^(?:作词|作曲|编曲|词|曲|演唱|制作人|制作|混音|录音|监制|发行|出品|词曲|lyrics?\s+by|music\s+by|written\s+by|composer|arranger)\s*[:：]"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return PreviewRecordingMatcher.normalized(text) == PreviewRecordingMatcher.normalized(song.songName + " - " + song.artistName)
    }
}
