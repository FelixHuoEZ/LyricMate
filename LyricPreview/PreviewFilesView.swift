import SwiftUI
import UniformTypeIdentifiers

struct PreviewJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct PreviewFilesView: View {
    let controller: PreviewController
    @Environment(\.dismiss) private var dismiss
    private enum Kind { case lrc, backup }
    @State private var kind: Kind = .lrc
    @State private var importing = false
    @State private var exporting = false
    @State private var document: PreviewJSONDocument?
    @State private var captured: PlaybackSnapshot?
    @State private var pendingLocal: PreviewLocalLyrics.Import?
    @State private var pendingRestore: PreviewBackup.Plan?
    @State private var confirmLocal = false
    @State private var confirmRestore = false
    @State private var message = ""
    @State private var showLibrary = false

    var body: some View {
        VStack {
            HStack { Text("本地歌词与配置备份").font(.title2.bold()); Spacer(); Button("关闭文件管理") { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
            Form {
                Section("本地 LRC 歌词") {
                    Button("管理本地歌词库") { showLibrary = true }
                    Text(controller.session.playback.map { "当前录音：\($0.trackName) / \($0.artistName)\n\($0.trackID)" } ?? "先启用只读跟随，取得明确的 Spotify 录音。")
                    Button("导入本地 LRC") {
                        captured = controller.session.playback; kind = .lrc; importing = true
                    }.disabled(!controller.session.playbackAvailable)
                    Button("使用此录音本地歌词") { useLocal() }.disabled(!controller.session.playbackAvailable)
                    Text("UTF-8 LRC，最多一 MiB。时间轴和可用标题、歌手头信息需通过核验；无头信息时由你确认版本。确认后复制到独立本机库，不发送网络；每首录音保存一份，最多二百份、总共三十二 MiB。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("配置与录音偏好") {
                    Text("\(controller.registry.store.sources.count) 个来源 / \(controller.preferences.entries.count) 首录音偏好")
                    Button("导出配置备份") {
                        do { document = PreviewJSONDocument(data: try PreviewBackup.export(sources: controller.registry.store, preferences: controller.preferences)); exporting = true }
                        catch { message = error.localizedDescription }
                    }
                    Button("恢复配置备份") { kind = .backup; importing = true }
                    Button("撤销最近配置恢复") {
                        if let data = controller.isolatedDefaults.data(forKey: PreviewBackup.undoKey) { prepareRestore(data) }
                    }.disabled(controller.isolatedDefaults.data(forKey: PreviewBackup.undoKey) == nil)
                    Text("备份包含服务地址、录音名称、ID、候选摘要及偏移，不含凭据、歌词正文或本地歌词文件。文件只在你选定的位置保存。换机后需要另行导入原 LRC，缺文件或候选变化时不盲目恢复偏移。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("恢复会替换独立版配置，并保存恢复前配置供撤销；所有来源保持关闭，需要单独确认启用。恢复本身不发请求，不修改正式版。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).font(.caption).accessibilityIdentifier("files-message") }
            }.formStyle(.grouped)
        }.frame(minWidth: 650, minHeight: 560)
        .sheet(isPresented: $showLibrary) { PreviewLibraryView(controller: controller) }
        .fileImporter(isPresented: $importing, allowedContentTypes: kind == .lrc ? [UTType(filenameExtension: "lrc") ?? .plainText] : [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                let limit = kind == .lrc ? 1024 * 1024 : PreviewBackup.maximumBytes
                let data = try file.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit else { throw LyricSourceError.responseTooLarge }
                if kind == .lrc {
                    guard url.pathExtension.lowercased() == "lrc", let captured, controller.session.playbackAvailable else { throw LyricSourceError.invalidResponse }
                    pendingLocal = try controller.localLyrics.prepare(data, playback: captured)
                    confirmLocal = true
                } else { prepareRestore(data) }
            } catch { message = "文件未导入：\(error.localizedDescription)" }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Lyric-Preview-settings") { result in
            switch result {
            case .success: message = "配置备份已保存；没有歌词正文或凭据。"
            case .failure(let error): message = error.localizedDescription
            }
        }
        .alert("绑定本地歌词？", isPresented: $confirmLocal) {
            Button("确认绑定本地歌词") {
                defer { pendingLocal = nil }
                do {
                    guard let value = pendingLocal, controller.session.playbackAvailable, let current = controller.session.playback else { throw FetchError.staleTrack }
                    let candidate = try controller.localLyrics.install(value, current: current)
                    controller.session.presentLocal(candidate); controller.session.select(candidate.id)
                    message = "本地歌词已绑定并保存；没有网络请求。"
                } catch { message = "绑定未完成：\(error.localizedDescription)" }
            }
            Button("取消绑定", role: .cancel) { pendingLocal = nil }
        } message: {
            Text("\(pendingLocal?.recording.title ?? "") / \(pendingLocal?.recording.artist ?? "")\n\(pendingLocal?.recording.id ?? "")\n文件将复制到独立本机库，替换此录音的旧本地文件。歌词头信息与时间轴不证明听感准确；请确认这是相同录音版本。其他应用与网络不受影响。")
        }
        .alert("预览配置恢复", isPresented: $confirmRestore) {
            Button("确认恢复，来源关闭") {
                defer { pendingRestore = nil }
                do {
                    guard let plan = pendingRestore else { throw LyricSourceError.invalidResponse }
                    try PreviewBackup.restore(plan, sources: controller.registry.store, preferences: controller.preferences, defaults: controller.isolatedDefaults)
                    controller.session.sourcesChanged()
                    message = "配置已恢复；所有来源关闭，原配置可撤销，没有网络请求。"
                } catch { message = "恢复未完成：\(error.localizedDescription)" }
            }
            Button("取消恢复", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("替换当前 \(controller.registry.store.sources.count) 个源 / \(controller.preferences.entries.count) 首偏好，恢复 \(pendingRestore?.payload.sources.count ?? 0) 个源 / \(pendingRestore?.payload.preferences.count ?? 0) 首偏好。\n\(pendingRestore?.payload.sources.map { $0.manifest.baseURL }.joined(separator: "\n") ?? "")\n不导入歌词文件；来源全部关闭；恢复前配置将保留。")
        }
    }
    private func prepareRestore(_ data: Data) {
        do { pendingRestore = try PreviewBackup.prepare(data, sources: controller.registry.store, preferences: controller.preferences); confirmRestore = true }
        catch { message = "备份未接受：\(error.localizedDescription)" }
    }
    private func useLocal() {
        do {
            if controller.session.loadRememberedLocal() {
                message = "已重核验并恢复本地歌词与原偏移，没有网络请求。"
                return
            }
            guard controller.session.playbackAvailable, let snapshot = controller.session.playback,
                  let candidate = try controller.localLyrics.candidate(for: snapshot) else { message = "此录音没有已绑定的本地歌词。"; return }
            controller.session.presentLocal(candidate); controller.session.select(candidate.id)
            message = "已加载此录音本地歌词，没有网络请求。"
        } catch { message = error.localizedDescription }
    }
}
