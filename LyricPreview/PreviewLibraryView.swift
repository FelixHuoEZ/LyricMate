import SwiftUI

struct PreviewLibraryView: View {
    let controller: PreviewController
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: PreviewLocalLyrics.Catalog?
    @State private var pending: PreviewLocalLyrics.Entry?
    @State private var confirming = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("本地歌词库").font(.title2.bold())
                Spacer()
                Button("刷新歌词库") { refresh() }
                Button("关闭歌词库") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let catalog {
                Text("已绑定 \(catalog.activeCount)/200 · \(size(catalog.activeBytes))/32 MiB；回收区 \(catalog.archivedCount)/200 · \(size(catalog.archivedBytes))/32 MiB")
                    .font(.caption.monospaced()).accessibilityIdentifier("library-capacity")
                if catalog.invalidCount > 0 { Text("\(catalog.invalidCount) 个文件未通过核验，未读取为歌词，也未删除；仍计入容量。") .foregroundStyle(.red) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(catalog.entries) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.recording.title + " / " + entry.recording.artist).font(.headline)
                            Text(entry.recording.album).font(.caption)
                            Text(entry.recording.id).font(.caption.monospaced()).textSelection(.enabled)
                            Text("\(entry.archived ? "回收区，已解绑" : "已绑定此录音") · \(size(entry.bytes)) · \(hasPreference(entry) ? "有选择与偏移记忆" : "无选择与偏移记忆")") .font(.caption)
                        }.accessibilityElement(children: .combine)
                        Spacer()
                        Button(entry.archived ? "恢复歌词" : "解绑并回收") { pending = entry; confirming = true }
                            .accessibilityLabel("\(entry.archived ? "恢复歌词" : "解绑并回收")：\(entry.recording.title)，\(entry.recording.id)")
                    }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.accessibilityLabel("已绑定及回收的本地歌词")
                if catalog.entries.isEmpty { Text("本地歌词库为空。先从文件管理导入 LRC。") }
            }
            Text("回收不永久删除。恢复不覆盖现有绑定，不恢复旧选择与偏移；需重新选择。两个区域各最多二百份、三十二 MiB，满时拒绝新增，不自动清理。配置备份不包含这些歌词文件。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).accessibilityIdentifier("library-message") }
        }.padding(20).frame(minWidth: 650, minHeight: 500)
        .onAppear { refresh() }
        .alert(pending?.archived == true ? "恢复已回收歌词？" : "解绑并回收歌词？", isPresented: $confirming) {
            Button(pending?.archived == true ? "确认恢复歌词" : "确认解绑并回收") { perform() }
            Button("取消", role: .cancel) { pending = nil }
        } message: {
            Text("\(pending?.recording.title ?? "") / \(pending?.recording.artist ?? "")\n\(pending?.recording.id ?? "")\n\(pending?.archived == true ? "恢复原录音绑定；有新文件时拒绝覆盖。旧偏移不会恢复。" : "移入本机回收区，可恢复；清除此录音的选择与偏移，其他录音不变。")\n没有网络请求，不影响正式版。")
        }
    }
    private func hasPreference(_ entry: PreviewLocalLyrics.Entry) -> Bool {
        controller.preferences.entries.contains { $0.recording.id == entry.recording.id }
    }
    private func size(_ bytes: Int) -> String { String(format: "%.2f MiB", Double(bytes) / 1048576) }
    private func refresh() {
        do { catalog = try controller.localLyrics.catalog() }
        catch { catalog = nil; message = "歌词库未读取：\(error.localizedDescription)；未改动文件。" }
    }
    private func perform() {
        defer { pending = nil; refresh() }
        do {
            guard let entry = pending else { return }
            if entry.archived { try controller.localLyrics.restore(entry) }
            else { try controller.localLyrics.archive(entry) }
            controller.preferences.forget(entry.recording.id)
            controller.session.localLibraryChanged(recordingID: entry.recording.id)
            message = entry.archived ? "歌词已恢复原绑定；请重新选择，旧偏移未恢复。" : "已解绑并移入回收区，可恢复；选择与偏移已清除。"
        } catch { message = "操作未完成：\(error.localizedDescription)；未覆盖现有绑定。" }
    }
}
