#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
import Foundation
import Observation

@MainActor
enum PreviewSearchPipeline {
    @MainActor private final class PartialResults {
        var values: [SongResult] = []
        var notices: [String] = []
        var delivered = Set<UUID>()
        private var deliveredSourceSongs = Set<String>()

        func shouldDeliver(_ result: SongResult) -> Bool {
            guard delivered.insert(result.id).inserted else { return false }
            guard let source = result.sourceIdentity, let song = result.sourceSongID else { return true }
            return deliveredSourceSongs.insert(source + "|" + song).inserted
        }

        func reportNotices(provider: CustomHTTPSourceProvider?, name: String, note: (String) -> Void) {
            var seen = Set<String>()
            for message in notices + (provider?.searchNotices ?? []) where seen.insert(message).inserted {
                note("\(name)：\(message)")
            }
        }
    }
    static func search(track: String, artist: String, providers: [LyricProvider], playback: PlaybackSnapshot? = nil,
                       validate: @escaping @MainActor () throws -> Void,
                       note: (String) -> Void, failure: (LyricProvider, Error) -> Void, append: @escaping @MainActor ([SongResult]) -> Void) async throws {
        for provider in providers {
            try validate()
            let custom = provider as? CustomHTTPSourceProvider
            let platform = custom.flatMap { PlatformLyricSource(rawValue: $0.manifest.apiFormat.rawValue) }
            let maySupplement = !artist.isEmpty && (custom?.manifest.apiFormat == .lrclib || platform != nil)
            let partial = PartialResults()
            do {
                let values = try await withLyricDeadline(seconds: 8) {
                    let current = playback.flatMap { snapshot in
                        PreviewRecordingMatcher.normalized(track) == PreviewRecordingMatcher.normalized(snapshot.trackName)
                            && PreviewRecordingMatcher.artistRelation(artist, snapshot.artistName) == .normalized ? snapshot.trackID : nil
                    }
                    let primary: [SongResult]
                    let deliver: @MainActor (SongResult) throws -> Void = { result in
                        try Task.checkCancellation(); try validate()
                        let assessment = PreviewRecordingMatcher.assessment(result, track: track, artist: artist, playback: playback)
                        guard assessment.canPreview else { return }
                        if partial.shouldDeliver(result) { append([result]) }
                    }
                    if let custom {
                        primary = try await custom.search(trackName: track, artistName: artist, spotifyTrackID: current, onResult: deliver)
                    } else { primary = try await provider.search(trackName: track, artistName: artist) }
                    partial.values = primary
                    partial.notices += custom?.searchNotices ?? []
                    for result in primary { try deliver(result) }
                    guard maySupplement, !primary.contains(where: { PreviewRecordingMatcher.matches($0, track: track, artist: artist) }) else {
                        return (primary, false)
                    }
                    // At most one title-only pass per source, sharing the original eight-second budget.
                    let extra: [SongResult]
                    if let custom {
                        extra = try await custom.search(trackName: track, artistName: "", spotifyTrackID: nil, onResult: { result in
                            guard PreviewRecordingMatcher.normalized(result.songName) == PreviewRecordingMatcher.normalized(track) else { return }
                            try deliver(result)
                        })
                    }
                    else { extra = try await provider.search(trackName: track, artistName: "") }
                    let matching = extra.filter { PreviewRecordingMatcher.normalized($0.songName) == PreviewRecordingMatcher.normalized(track) }
                    var keys = Set<String>()
                    let combined = (matching + primary).filter {
                        keys.insert(($0.sourceIdentity ?? "") + "|" + ($0.sourceSongID ?? $0.id.uuidString)).inserted
                    }
                    return (Array(combined.prefix(5)), true)
                }
                try validate()
                partial.reportNotices(provider: custom, name: provider.providerName, note: note)
                if values.1 {
                    note(L10n.text("%1$@ made one title-only fallback search. Candidates are previewed by score; other artists or covers may have different timing.", String(describing: provider.providerName)))
                }
                append(values.0.filter { LyricFetchPipeline.isValid($0.lyrics) && partial.shouldDeliver($0) })
            } catch {
                try validate()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if error is FetchError { throw error }
                // A failed or limited source is not an invitation to broaden its query.
                append(partial.values.filter { LyricFetchPipeline.isValid($0.lyrics) && partial.shouldDeliver($0) })
                partial.reportNotices(provider: custom, name: provider.providerName, note: note)
                failure(provider, error)
                if error as? LyricSourceError == .rateLimited && platform == nil { return }
            }
        }
        try validate()
    }
}

@MainActor
@Observable
final class LyricPreviewSession {
    private(set) var playback: PlaybackSnapshot?
    private(set) var playbackAvailable = false
    private(set) var results: [SongResult] = []
    private(set) var sourceErrors: [String] = []
    private(set) var selectedID: UUID?
    private(set) var isSearching = false
    private(set) var status = L10n.text("Waiting for playback information. You can also enter a song title and optional artist.")
    private(set) var matchingMessage = ""
    private(set) var memoryMessage = ""
    var trackQuery = ""
    var artistQuery = ""
    var followsPlayback = true
    var previewPositionMS = 0.0
    private var storedOffsetMS = 0.0
    var offsetMS: Double {
        get { storedOffsetMS }
        set {
            storedOffsetMS = newValue.isFinite ? max(-10000, min(10000, newValue)) : 0
            if !suppressMemoryWrites {
                if selectedID != nil { selectionOrigin = .manual }
                rememberSelection()
            }
        }
    }
    @ObservationIgnored private let providers: [LyricProvider]
    @ObservationIgnored private let providerSnapshot: (() -> [LyricProvider])?
    @ObservationIgnored private let preferences: PreviewRecordingPreferences?
    @ObservationIgnored private let localLyrics: PreviewLocalLyrics?
    @ObservationIgnored private var suppressMemoryWrites = false
    private enum SelectionOrigin { case manual, automatic, remembered }
    @ObservationIgnored private var selectionOrigin: SelectionOrigin?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(providers: [LyricProvider], providerSnapshot: (() -> [LyricProvider])? = nil, preferences: PreviewRecordingPreferences? = nil, localLyrics: PreviewLocalLyrics? = nil) {
        self.providers = providers
        self.providerSnapshot = providerSnapshot
        self.preferences = preferences
        self.localLyrics = localLyrics
        memoryMessage = preferences?.loadError ?? ""
    }

    var selected: SongResult? { results.first { $0.id == selectedID } }
    var unselectedLyricsTitle: String {
        if isSearching { return L10n.text("Finding lyrics") }
        if !results.isEmpty { return L10n.text("Lyrics found; check the recording version") }
        return sourceErrors.isEmpty ? L10n.text("No timed lyrics") : L10n.text("No usable lyrics retrieved")
    }
    var unselectedLyricsDetail: String {
        if !results.isEmpty { return L10n.text("Found %1$@ candidates. Check the artist, album and duration before selecting; an unverified cover is not treated as the same recording.", String(describing: results.count)) }
        if isSearching { return L10n.text("Searching by title and artist, with a title-only fallback if needed.") }
        if !sourceErrors.isEmpty { return L10n.text("Some sources failed. Check the errors and retry; a failed request does not mean the catalog has no lyrics.") }
        return L10n.text("Search using just the title, or import a local LRC for this recording.")
    }
    var displayedPositionMS: Double {
        followsPlayback ? (playbackAvailable ? playback?.positionMS ?? 0 : 0) : previewPositionMS
    }
    var displayedDurationMS: Int? {
        followsPlayback ? playback?.durationMS : selected?.durationMS ?? playback?.durationMS
    }
    var activeIndex: Int? {
        guard let selected, !followsPlayback || playbackAvailable else { return nil }
        return LyricTimeline.activeIndex(in: selected.lyrics, positionMS: displayedPositionMS, offsetMS: offsetMS)
    }

    func matchAssessment(for candidate: SongResult) -> PreviewRecordingMatcher.Assessment {
        PreviewRecordingMatcher.assessment(candidate, track: trackQuery, artist: artistQuery, playback: playbackAvailable ? playback : nil)
    }

    var rankedResults: [SongResult] {
        results.enumerated().sorted {
            let left = matchAssessment(for: $0.element).score, right = matchAssessment(for: $1.element).score
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }

    var recommendedID: UUID? {
        rankedResults.first { matchAssessment(for: $0).canPreview }?.id
    }

    func updatePlayback(_ incoming: PlaybackSnapshot?, autoSearch: Bool = true) {
        guard let incoming, incoming.isValid else {
            if playbackAvailable { invalidateSearch() }
            playbackAvailable = false
            return
        }
        let changed = playback.map { PreviewRecordingPreferences.Recording($0) != PreviewRecordingPreferences.Recording(incoming) } ?? true
        let resumed = !playbackAvailable
        playback = incoming
        playbackAvailable = true
        if changed {
            invalidateSearch()
            results = []
            selectedID = nil
            selectionOrigin = nil
            sourceErrors = []
            matchingMessage = ""
            memoryMessage = preferences?.loadError ?? ""
            offsetMS = 0
            previewPositionMS = incoming.positionMS
            trackQuery = incoming.trackName
            artistQuery = incoming.artistName
            status = L10n.text("Track changed; previous lyrics cleared.")
        }
        if autoSearch && (changed || resumed && results.isEmpty) {
            if !loadRememberedLocal() { search() }
        }
    }

    @discardableResult
    func search() -> Task<Void, Never>? {
        invalidateSearch()
        let track = trackQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artistQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !track.isEmpty else {
            status = L10n.text("Enter a song title. The artist is optional.")
            return nil
        }
        let capturedGeneration = generation
        let snapshot = playbackAvailable ? playback : nil
        results = []
        selectedID = nil
        selectionOrigin = nil
        sourceErrors = []
        matchingMessage = ""
        memoryMessage = preferences?.loadError ?? ""
        offsetMS = 0
        if let snapshot, PreviewRecordingMatcher.normalized(track) == PreviewRecordingMatcher.normalized(snapshot.trackName),
           PreviewRecordingMatcher.artistRelation(artist, snapshot.artistName) == .normalized {
            do { if let local = try localLyrics?.candidate(for: snapshot) { results.append(local) } }
            catch { sourceErrors.append(L10n.text("Local LRC: %1$@", String(describing: error.localizedDescription))) }
        }
        isSearching = true
        status = L10n.text("Searching...")
        updateAutomaticSelection(playback: snapshot, track: track, artist: artist, finished: false)
        let task = Task { @MainActor [self] in
            defer { if generation == capturedGeneration { isSearching = false } }
            do {
                try await PreviewSearchPipeline.search(track: track, artist: artist, providers: providerSnapshot?() ?? providers, playback: snapshot, validate: {
                    guard self.generation == capturedGeneration else { throw FetchError.staleTrack }
                }, note: { message in
                    matchingMessage += (matchingMessage.isEmpty ? "" : "\n") + message
                }, failure: { provider, error in
                    sourceErrors.append("\(provider.providerName): \(error.localizedDescription)")
                }, append: { values in
                    self.results.append(contentsOf: values)
                    self.updateAutomaticSelection(playback: snapshot, track: track, artist: artist, finished: false)
                })
                guard generation == capturedGeneration else { return }
                status = results.isEmpty
                    ? (sourceErrors.isEmpty ? L10n.text("No timed lyrics found.") : L10n.text("No usable lyrics retrieved; some source requests failed. Check the errors."))
                    : L10n.text("Select the recording version. Audible synchronization has not been verified.")
                if selectionOrigin == .manual {
                    status = L10n.text("Keeping your manual selection; later candidates did not replace it.")
                } else {
                    updateAutomaticSelection(playback: snapshot, track: track, artist: artist, finished: true)
                }
                if let snapshot, memoryMessage.isEmpty, preferences?.entries.contains(where: { $0.recording.id == snapshot.trackID }) == true {
                    memoryMessage = L10n.text("Saved choice exists, but the candidate or recording could not be revalidated; the previous offset was not restored.")
                }
            } catch {
                guard generation == capturedGeneration else { return }
                status = selectedID != nil ? L10n.text("Lyrics loaded; remaining searches stopped.") : (error is CancellationError ? L10n.text("Search canceled.") : L10n.text("Search stopped."))
            }
        }
        searchTask = task
        return task
    }

    func select(_ id: UUID, remember: Bool = true) {
        guard results.contains(where: { $0.id == id }) else { return }
        applySelection(id, origin: .manual)
        if remember { rememberSelection() }
    }

    private func applySelection(_ id: UUID, origin: SelectionOrigin) {
        guard results.contains(where: { $0.id == id }) else { return }
        selectedID = id
        selectionOrigin = origin
        suppressMemoryWrites = true
        offsetMS = 0
        suppressMemoryWrites = false
        status = L10n.text("Candidate selected; verify the recording and audible synchronization.")
    }

    private func updateAutomaticSelection(playback: PlaybackSnapshot?, track: String, artist: String, finished: Bool) {
        guard selectionOrigin != .manual, let playback,
              PreviewRecordingMatcher.normalized(trackQuery) == PreviewRecordingMatcher.normalized(track),
              artistQuery.trimmingCharacters(in: .whitespacesAndNewlines) == artist,
              PreviewRecordingMatcher.normalized(track) == PreviewRecordingMatcher.normalized(playback.trackName),
              artist.isEmpty || PreviewRecordingMatcher.artistRelation(artist, playback.artistName) == .normalized else { return }
        // A revalidated user choice outranks automatic scoring, even if it arrives later.
        if let restored = preferences?.restoration(in: results, playback: playback) {
            if selectedID != restored.id || selectionOrigin != .remembered {
                applySelection(restored.id, origin: .remembered)
                suppressMemoryWrites = true; offsetMS = restored.offsetMS; suppressMemoryWrites = false
            }
            memoryMessage = L10n.text("Revalidated the source, lyric fingerprint and recording; restored the selection and offset.")
            status = finished ? L10n.text("Saved selection restored; audible synchronization is not verified.") : L10n.text("Saved selection restored; other sources are still searching.")
            return
        }
        if selectionOrigin == .remembered {
            selectedID = nil; selectionOrigin = nil
            suppressMemoryWrites = true; offsetMS = 0; suppressMemoryWrites = false
            memoryMessage = L10n.text("The saved candidate could not be uniquely revalidated; the previous selection and offset were not retained.")
        }
        guard let id = Self.preferredCandidate(in: results, playback: playback, track: track, artist: artist),
              let candidate = results.first(where: { $0.id == id }) else { return }
        let assessment = PreviewRecordingMatcher.assessment(candidate, track: track, artist: artist, playback: playback)
        if selectedID != id { applySelection(id, origin: .automatic) }
        let confidence = assessment.isReliableMatch ? L10n.text("Recording metadata matches; audible synchronization is not verified.") : L10n.text("Provisional match; the version may differ. Not saved automatically.")
        status = L10n.text("Loaded the highest-scoring lyrics so far (%1$@/100). ", String(describing: assessment.score))
            + (finished ? L10n.text("Search finished; source order breaks ties. ") : L10n.text("Other sources are still searching; a higher score will replace this candidate. ")) + confidence
    }

    @discardableResult
    func loadRememberedLocal() -> Bool {
        guard playbackAvailable, let playback else { return false }
        do {
            guard let candidate = try localLyrics?.candidate(for: playback),
                  let restored = preferences?.restoration(in: [candidate], playback: playback) else { return false }
            presentLocal(candidate)
            suppressMemoryWrites = true; offsetMS = restored.offsetMS; suppressMemoryWrites = false
            memoryMessage = L10n.text("Revalidated and restored local lyrics and offset without a network request.")
            return true
        } catch { sourceErrors.append(L10n.text("Local LRC: %1$@", String(describing: error.localizedDescription))); return false }
    }
    func presentLocal(_ candidate: SongResult) {
        invalidateSearch()
        results = [candidate]; selectedID = nil; matchingMessage = ""; sourceErrors = []
        trackQuery = candidate.songName; artistQuery = candidate.artistName
        select(candidate.id, remember: false)
        status = L10n.text("Local lyrics are bound to this recording. No network is needed; verify the recording and audible synchronization.")
    }

    func sourcesChanged() {
        invalidateSearch()
        results = []; selectedID = nil; sourceErrors = []; matchingMessage = ""
        selectionOrigin = nil
        memoryMessage = preferences?.loadError ?? ""
        offsetMS = 0
        status = L10n.text("Source settings changed; previous candidates cleared. Search again.")
    }

    func localLibraryChanged(recordingID: String) {
        guard playback?.trackID == recordingID else { return }
        sourcesChanged()
        status = L10n.text("Local lyric binding changed; previous candidates and offset cleared. Select again.")
    }

    func forgetCurrentChoice() {
        guard let id = playback?.trackID else { return }
        preferences?.forget(id)
        suppressMemoryWrites = true; offsetMS = 0; suppressMemoryWrites = false
        memoryMessage = L10n.text("Forgot this track's selection and offset.")
    }

    private func rememberSelection() {
        guard let preferences, playbackAvailable, let playback, let selected,
              PreviewRecordingMatcher.normalized(trackQuery) == PreviewRecordingMatcher.normalized(playback.trackName),
              PreviewRecordingMatcher.artistRelation(artistQuery, playback.artistName) == .normalized else { return }
        memoryMessage = preferences.remember(selected, playback: playback, offsetMS: offsetMS)
            ? L10n.text("Saved the selection and offset for this Spotify recording, without lyric text.")
            : L10n.text("Candidate identity or duration is missing, or the recording differs. Preview only; no choice saved.")
    }

    func stop() {
        invalidateSearch()
        playbackAvailable = false
    }

    private func invalidateSearch() {
        generation = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    static func preferredCandidate(in results: [SongResult], playback: PlaybackSnapshot,
                                   track: String, artist: String) -> UUID? {
        PreviewRecordingMatcher.preferred(in: results, playback: playback, track: track, artist: artist)
    }
}
