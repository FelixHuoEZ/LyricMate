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
                    note("\(provider.providerName) 已做一次仅歌名补充查询；候选按评分临时载入，其他歌手或翻唱的时间轴可能不适合当前录音。")
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
    private(set) var status = "等待播放信息，也可手动输入歌名和歌手。"
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
        if isSearching { return "正在查找歌词" }
        if !results.isEmpty { return "找到歌词，待确认版本" }
        return sourceErrors.isEmpty ? "暂无时间轴歌词" : "暂未获得可用歌词"
    }
    var unselectedLyricsDetail: String {
        if !results.isEmpty { return "已找到 \(results.count) 个候选，请在左侧核对歌手、专辑和时长后选择；不会自动套用无法确认的翻唱版本。" }
        if isSearching { return "正在按歌名和歌手查找；没有匹配时会补充仅歌名查询。" }
        if !sourceErrors.isEmpty { return "部分来源请求失败，请查看左侧错误后重试；请求失败不等于曲库没有歌词。" }
        return "可在左侧只输入歌名搜索，也可导入此录音的本地 LRC。"
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
            status = "歌曲已切换，旧歌词已清除。"
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
            status = "请输入歌名；歌手可以留空。"
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
            catch { sourceErrors.append("本地 LRC：\(error.localizedDescription)") }
        }
        isSearching = true
        status = "正在搜索…"
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
                    ? (sourceErrors.isEmpty ? "未找到带时间轴的歌词。" : "未获得可用歌词；来源请求有失败，请查看错误。")
                    : "请选择录音版本；尚未验证听感同步。"
                if selectionOrigin == .manual {
                    status = "保留本轮人工选择；未被后到候选替换。"
                } else {
                    updateAutomaticSelection(playback: snapshot, track: track, artist: artist, finished: true)
                }
                if let snapshot, memoryMessage.isEmpty, preferences?.entries.contains(where: { $0.recording.id == snapshot.trackID }) == true {
                    memoryMessage = "此录音有记忆，但候选或录音信息未通过重核验；未恢复旧偏移。"
                }
            } catch {
                guard generation == capturedGeneration else { return }
                status = selectedID != nil ? "歌词已载入；剩余搜索已停止。" : (error is CancellationError ? "搜索已取消。" : "搜索已停止。")
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
        status = "已选择候选；仍需核对录音与听感同步。"
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
            memoryMessage = "已重新核验来源、歌词摘要和录音信息，恢复此歌曲的选择与偏移。"
            status = finished ? "已恢复用户选择；不代表听感同步已验证。" : "已恢复用户选择；其他来源继续搜索中。"
            return
        }
        if selectionOrigin == .remembered {
            selectedID = nil; selectionOrigin = nil
            suppressMemoryWrites = true; offsetMS = 0; suppressMemoryWrites = false
            memoryMessage = "记忆候选无法唯一重核验，未保留旧选择与偏移。"
        }
        guard let id = Self.preferredCandidate(in: results, playback: playback, track: track, artist: artist),
              let candidate = results.first(where: { $0.id == id }) else { return }
        let assessment = PreviewRecordingMatcher.assessment(candidate, track: track, artist: artist, playback: playback)
        if selectedID != id { applySelection(id, origin: .automatic) }
        let confidence = assessment.isReliableMatch ? "录音资料匹配；不代表听感同步已验证。" : "临时匹配，版本可能不同；未自动记忆。"
        status = "已载入当前最高分 \(assessment.score)/100 的歌词；"
            + (finished ? "搜索已结束，同分按来源顺序。" : "其他来源继续搜索，更高分会自动替换。") + confidence
    }

    @discardableResult
    func loadRememberedLocal() -> Bool {
        guard playbackAvailable, let playback else { return false }
        do {
            guard let candidate = try localLyrics?.candidate(for: playback),
                  let restored = preferences?.restoration(in: [candidate], playback: playback) else { return false }
            presentLocal(candidate)
            suppressMemoryWrites = true; offsetMS = restored.offsetMS; suppressMemoryWrites = false
            memoryMessage = "已从本机库重核验并恢复本地歌词与偏移，没有网络请求。"
            return true
        } catch { sourceErrors.append("本地 LRC：\(error.localizedDescription)"); return false }
    }
    func presentLocal(_ candidate: SongResult) {
        invalidateSearch()
        results = [candidate]; selectedID = nil; matchingMessage = ""; sourceErrors = []
        trackQuery = candidate.songName; artistQuery = candidate.artistName
        select(candidate.id, remember: false)
        status = "本地歌词已绑定当前录音；无需网络，录音与听感由用户确认。"
    }

    func sourcesChanged() {
        invalidateSearch()
        results = []; selectedID = nil; sourceErrors = []; matchingMessage = ""
        selectionOrigin = nil
        memoryMessage = preferences?.loadError ?? ""
        offsetMS = 0
        status = "来源设置已改变，旧候选已清除；请重新搜索。"
    }

    func localLibraryChanged(recordingID: String) {
        guard playback?.trackID == recordingID else { return }
        sourcesChanged()
        status = "本地歌词绑定已改变；旧候选与偏移已清除，请重新选择。"
    }

    func forgetCurrentChoice() {
        guard let id = playback?.trackID else { return }
        preferences?.forget(id)
        suppressMemoryWrites = true; offsetMS = 0; suppressMemoryWrites = false
        memoryMessage = "已忘记此歌曲的选择和偏移。"
    }

    private func rememberSelection() {
        guard let preferences, playbackAvailable, let playback, let selected,
              PreviewRecordingMatcher.normalized(trackQuery) == PreviewRecordingMatcher.normalized(playback.trackName),
              PreviewRecordingMatcher.artistRelation(artistQuery, playback.artistName) == .normalized else { return }
        memoryMessage = preferences.remember(selected, playback: playback, offsetMS: offsetMS)
            ? "已记住此 Spotify 录音的选择与偏移；不保存歌词正文。"
            : "候选缺少稳定身份、时长或与当前录音不符，仅临时预览，未写入记忆。"
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
