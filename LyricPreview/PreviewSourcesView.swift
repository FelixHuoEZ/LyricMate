import SwiftUI
import UniformTypeIdentifiers

struct PreviewSourcesView: View {
    let registry: LyricSourceRegistry
    let changed: () -> Void
    var setupMessage = ""
    var initialTrack = ""
    var initialArtist = ""
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var jsonText = ""
    @State private var pendingData: Data?
    @State private var pendingManifest: LyricSourceManifest?
    @State private var confirmImport = false
    @State private var confirmEnable = false
    @State private var confirmRemove = false
    @State private var enabling: LyricSourceConfiguration?
    @State private var removing: LyricSourceConfiguration?
    @State private var message = ""
    @State private var testTrack = ""
    @State private var testArtist = ""
    @State private var testing: UUID?
    @State private var testTask: Task<Void, Never>?
    @State private var statuses: [UUID: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("独立版歌词源").font(.title2.bold())
                Spacer()
                Button("关闭源管理") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Form {
                Section("导入兼容服务") {
                    Text("酷狗、网易云、酷我、QQ 音乐、咪咕使用固定公开歌词接口，可在下方开关。只接受无登录凭据的 HTTPS JSON 配置；不运行六音/LX JavaScript。内置 LRCLIB 始终保留。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("导入 JSON 文件") { importing = true }
                    ForEach(PlatformLyricSource.allCases, id: \.rawValue) { platform in
                        Button("添加\(platform.name)歌词源") {
                            if let data = try? JSONEncoder().encode(platform.manifest) { prepare(data) }
                        }.disabled(registry.store.sources.contains { $0.manifest.apiFormat == platform.format })
                    }
                    Text("只取歌词，不提供音频播放或下载。公开接口非官方开放 API，可能变动或限流；平台标记仅表示接入，不保证每首歌有词。有效时间轴歌词按评分先载入、再升级；咪咕时长未知，仅临时匹配，不自动记忆。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("添加 AMLL 社区备用源") {
                        let manifest = LyricSourceManifest(schemaVersion: 1, apiVersion: 1, name: "AMLL 社区库", baseURL: AMLLSource.baseURL,
                                                           capabilities: ["search", "syncedLyrics"], auth: .init(type: "none"), format: .amllTTML)
                        if let data = try? JSONEncoder().encode(manifest) { prepare(data) }
                    }
                    Text("AMLL 官方 GitHub 公开索引与 TTML 文件，无需登录。社区候选须手动确认，时长未知；仅展示逐行。仓库 CC0 不替代原歌词授权，本版不捆绑歌词发行。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("AMLL 来源与贡献者说明", destination: URL(string: "https://github.com/amll-dev/amll-ttml-db")!)
                    DisclosureGroup("粘贴 JSON 配置") {
                        TextEditor(text: $jsonText).font(.caption.monospaced()).frame(height: 90)
                            .accessibilityLabel("源 JSON 配置")
                        Button("检查粘贴配置") { prepare(Data(jsonText.utf8)) }.disabled(jsonText.isEmpty)
                    }
                    if !message.isEmpty { Text(message).font(.caption).accessibilityIdentifier("source-message") }
                    if let error = registry.store.loadError { Text(error).foregroundStyle(.red) }
                    if !setupMessage.isEmpty { Text(setupMessage).foregroundStyle(.red) }
                }
                Section("授权来源（尚未接入）") {
                    Text("Musixmatch 和 LyricFind 需要官方密钥、时间轴歌词权限与展示条款。当前未配置，不发送请求，也不使用非官方令牌。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Musixmatch 官方开发者入口", destination: URL(string: "https://developer.musixmatch.com/")!)
                    Link("LyricFind 官方歌词服务", destination: URL(string: "https://www.lyricfind.com/products/lyric-display")!)
                }
                Section("已添加来源") {
                    Text("已保存 \(registry.store.sources.count) 个源，启用 \(registry.store.sources.filter(\.isEnabled).count) 个。")
                        .font(.caption.monospaced())
                    if registry.store.sources.isEmpty { Text("尚无自定义源。导入配置不等于来源已验证。") }
                    ForEach(registry.store.sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle(source.manifest.name, isOn: Binding(get: {
                                    registry.store.sources.first(where: { $0.id == source.id })?.isEnabled ?? false
                                }, set: { enabled in
                                    if enabled { enabling = source; confirmEnable = true }
                                    else { mutate { try registry.store.setEnabled(source.id, false) } }
                                })).toggleStyle(.switch)
                                Spacer()
                                Button("测试 \(source.manifest.name)") { test(source) }
                                    .disabled(testing != nil || testTrack.isEmpty)
                                Button("删除 \(source.manifest.name)", role: .destructive) { removing = source; confirmRemove = true }
                                    .disabled(testing == source.id)
                            }
                            Text(PlatformLyricSource(rawValue: source.manifest.apiFormat.rawValue)?.domains ?? source.manifest.baseURL)
                                .font(.caption).textSelection(.enabled)
                            Text(statuses[source.id] ?? "尚未测试。测试只验证检索和取词，不确认录音同步。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("有界连接测试") {
                    TextField("测试歌名", text: $testTrack)
                    TextField("测试歌手（可选）", text: $testArtist)
                    Text("点击测试将把这些歌名、歌手发送给该服务，即使来源当前未启用。搜索与一个候选的取词共用八秒预算（酷狗取词含索引和下载两步）；不会替换当前歌词。")
                        .font(.caption).foregroundStyle(.secondary)
                    if testing != nil { Button("取消来源测试") { testTask?.cancel() } }
                }
                Text("来源按内置 LRCLIB、自定义源导入顺序尝试。设置变化会清除旧候选，需重新搜索；这里只保存独立版配置。")
                    .font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
        }
        .frame(minWidth: 650, minHeight: 650)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                prepare(try file.read(upToCount: 64 * 1024 + 1) ?? Data())
            } catch { message = error.localizedDescription }
        }
        .alert("确认导入歌词源", isPresented: $confirmImport) {
            Button("导入并启用") { importPending(enabled: true) }
            Button("仅导入，不启用") { importPending(enabled: false) }
            Button("取消导入", role: .cancel) { pendingManifest = nil; pendingData = nil }
        } message: {
            Text("\(pendingManifest?.name ?? "")\n\(pendingManifest?.baseURL ?? "")\n\(requestNotice(pendingManifest)) 仅导入不会发请求。")
        }
        .alert("启用来源？", isPresented: $confirmEnable) {
            Button("确认启用") {
                if let source = enabling { mutate { try registry.store.setEnabled(source.id, true) } }
                enabling = nil
            }
            Button("取消启用", role: .cancel) { enabling = nil }
        } message: { Text("\(enabling?.manifest.baseURL ?? "")\n\(requestNotice(enabling?.manifest))") }
        .alert("删除独立来源？", isPresented: $confirmRemove) {
            Button("确认删除来源", role: .destructive) {
                if let source = removing { mutate { try registry.store.remove(source.id) }; statuses[source.id] = nil }
                removing = nil
            }
            Button("取消删除", role: .cancel) { removing = nil }
        } message: { Text("只删除 \(removing?.manifest.name ?? "") 的独立配置，不修改正式版。") }
        .onAppear { testTrack = initialTrack; testArtist = initialArtist }
        .onDisappear { testTask?.cancel() }
    }

    private func prepare(_ data: Data) {
        do { pendingManifest = try LyricSourceManifest.decode(data); pendingData = data; confirmImport = true }
        catch { message = error.localizedDescription }
    }
    private func requestNotice(_ manifest: LyricSourceManifest?) -> String {
        if let format = manifest?.apiFormat, let platform = PlatformLyricSource(rawValue: format.rawValue) {
            return "向 \(platform.domains) 发送搜索歌名、歌手和平台歌曲 ID，仅取歌词；不发送账户、令牌或本地文件。"
        }
        return manifest?.apiFormat == .amllTTML
            ? "启用后读取官方公开索引，在本机匹配歌名、歌手，再按社区 ID 请求 TTML 文件；不发送账户、令牌或本地文件。"
            : "启用后向此服务发送搜索歌名和歌手；不发送账户、令牌或本地文件。"
    }
    private func importPending(enabled: Bool) {
        defer { pendingManifest = nil; pendingData = nil }
        guard let data = pendingData else { return }
        mutate { _ = try registry.store.importManifest(data, enabled: enabled) }
    }
    private func mutate(_ operation: () throws -> Void) {
        testTask?.cancel()
        do { try operation(); changed(); message = "配置已保存；请回到工作台重新搜索。" }
        catch { message = error.localizedDescription }
    }
    private func test(_ source: LyricSourceConfiguration) {
        let track = testTrack.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = testArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !track.isEmpty else { return }
        testing = source.id
        statuses[source.id] = "正在测试，仅发送测试歌名和歌手…"
        testTask = Task { @MainActor in
            defer { testing = nil }
            do {
                let provider = try registry.provider(for: source)
                let success = try await withLyricDeadline(seconds: 8) {
                    let songs = try await provider.searchCandidates(trackName: track, artistName: artist)
                    guard let song = songs.first(where: {
                        $0.hasSyncedLyrics && PreviewRecordingMatcher.normalized($0.trackName) == PreviewRecordingMatcher.normalized(track)
                            && (artist.isEmpty || PreviewRecordingMatcher.artistRelation($0.artistName, artist) == .normalized)
                    }) else { return false }
                    return LyricFetchPipeline.isValid(try await provider.lyrics(for: song))
                }
                try Task.checkCancellation()
                statuses[source.id] = success ? "连接、检索和时间轴取词通过；录音版本及听感未验证。" : "连接成功，但未获得匹配的有效时间轴。"
            } catch is CancellationError { statuses[source.id] = "测试已取消。" }
            catch PlatformLyricError.untimedLyrics { statuses[source.id] = "连接和检索成功，但该候选仅提供无时间轴歌词，无法用于同步。" }
            catch { statuses[source.id] = "来源测试失败：\(error.localizedDescription)；不能据此判断无歌词。" }
        }
    }
}
