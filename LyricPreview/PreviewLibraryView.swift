#if canImport(LyricMateLocalization)
import LyricMateLocalization
#endif
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
                Text(L10n.text("Local lyric library")).font(.title2.bold())
                Spacer()
                Button(L10n.text("Refresh library")) { refresh() }
                Button(L10n.text("Close library")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let catalog {
                Text(L10n.text("Bound %1$@/200 · %2$@/32 MiB; archived %3$@/200 · %4$@/32 MiB", String(describing: catalog.activeCount), String(describing: size(catalog.activeBytes)), String(describing: catalog.archivedCount), String(describing: size(catalog.archivedBytes))))
                    .font(.caption.monospaced()).accessibilityIdentifier("library-capacity")
                if catalog.invalidCount > 0 { Text(L10n.text("%1$@ files failed validation. They were not loaded or deleted and still count toward storage limits.", String(describing: catalog.invalidCount))) .foregroundStyle(.red) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(catalog.entries) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.recording.title + " / " + entry.recording.artist).font(.headline)
                            Text(entry.recording.album).font(.caption)
                            Text(entry.recording.id).font(.caption.monospaced()).textSelection(.enabled)
                            Text("\(entry.archived ? L10n.text("Archived, unbound") : L10n.text("Bound to this recording")) · \(size(entry.bytes)) · \(hasPreference(entry) ? L10n.text("Saved selection and offset") : L10n.text("No saved selection or offset"))") .font(.caption)
                        }.accessibilityElement(children: .combine)
                        Spacer()
                        Button(entry.archived ? L10n.text("Restore lyrics") : L10n.text("Unbind and archive")) { pending = entry; confirming = true }
                            .accessibilityLabel("\(entry.archived ? L10n.text("Restore lyrics") : L10n.text("Unbind and archive"))：\(entry.recording.title)，\(entry.recording.id)")
                    }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.accessibilityLabel(L10n.text("Bound and archived local lyrics"))
                if catalog.entries.isEmpty { Text(L10n.text("The local lyric library is empty. Import an LRC from the file manager first.")) }
            }
            Text(L10n.text("Archiving is not permanent deletion. Restoring never overwrites a current binding or restores old selections and offsets; select again. Each area allows 200 files and 32 MiB. New files are rejected when full, with no automatic deletion. Configuration backups do not include lyric files."))
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).accessibilityIdentifier("library-message") }
        }.padding(20).frame(minWidth: 650, minHeight: 500)
        .onAppear { refresh() }
        .alert(pending?.archived == true ? L10n.text("Restore archived lyrics?") : L10n.text("Unbind and archive lyrics?"), isPresented: $confirming) {
            Button(pending?.archived == true ? L10n.text("Confirm lyric restore") : L10n.text("Confirm unbind and archive")) { perform() }
            Button(L10n.text("Cancel"), role: .cancel) { pending = nil }
        } message: {
            Text(L10n.text("%1$@ / %2$@\n%3$@\n%4$@\nNo network request is made; other editions are unaffected.", String(describing: pending?.recording.title ?? ""), String(describing: pending?.recording.artist ?? ""), String(describing: pending?.recording.id ?? ""), String(describing: pending?.archived == true ? L10n.text("Restore the original recording binding, without overwriting a newer file. The old offset is not restored.") : L10n.text("Move to the recoverable local archive and clear this recording's selection and offset. Other recordings are unchanged."))))
        }
    }
    private func hasPreference(_ entry: PreviewLocalLyrics.Entry) -> Bool {
        controller.preferences.entries.contains { $0.recording.id == entry.recording.id }
    }
    private func size(_ bytes: Int) -> String { String(format: "%.2f MiB", Double(bytes) / 1048576) }
    private func refresh() {
        do { catalog = try controller.localLyrics.catalog() }
        catch { catalog = nil; message = L10n.text("Library could not be read: %1$@. Files were not changed.", String(describing: error.localizedDescription)) }
    }
    private func perform() {
        defer { pending = nil; refresh() }
        do {
            guard let entry = pending else { return }
            if entry.archived { try controller.localLyrics.restore(entry) }
            else { try controller.localLyrics.archive(entry) }
            controller.preferences.forget(entry.recording.id)
            controller.session.localLibraryChanged(recordingID: entry.recording.id)
            message = entry.archived ? L10n.text("Lyrics restored to the original binding. Select again; the old offset was not restored.") : L10n.text("Lyrics unbound and moved to the recoverable archive; selection and offset cleared.")
        } catch { message = L10n.text("Action incomplete: %1$@. Existing bindings were not overwritten.", String(describing: error.localizedDescription)) }
    }
}
