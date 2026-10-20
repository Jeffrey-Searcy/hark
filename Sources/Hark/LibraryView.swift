//
// LibraryView.swift — the main Hark window: every saved transcript, newest first.
//
// Left: list of transcripts (date/time, length, first line). Right: the full text,
// selectable, with buttons to Copy it, Save a Copy (e.g. to Downloads), Show in
// Finder, or Move to Trash. Transcripts themselves live in ~/Documents/Transcripts
// (AppPaths.transcripts); this window only reads that folder.
//

import AppKit
import SwiftUI

/// One transcript file, read for display.
struct TranscriptItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    /// Header line without the "Transcript — " prefix, e.g. "Tue Oct 20, 2026, 2:32 PM to 3:10 PM (38 min)".
    let title: String
    /// First spoken line, without its timestamp, for the list preview.
    let preview: String
    /// Full file text.
    let text: String
}

/// Reads ~/Documents/Transcripts and tracks the selected transcript.
final class TranscriptLibrary: ObservableObject {
    @Published private(set) var items: [TranscriptItem] = []
    @Published var selection: URL?
    /// Set when the folder can't be listed; shown in the window instead of the list.
    @Published private(set) var loadError: String?

    var selectedItem: TranscriptItem? { items.first { $0.url == selection } }

    /// Re-reads the folder. A missing folder just means no transcripts yet.
    func reload() {
        let folder = AppPaths.transcripts
        guard FileManager.default.fileExists(atPath: folder.path) else {
            items = []
            loadError = nil
            return
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "txt" }
                // why: names are "yyyy-MM-dd_HH-mm[_n].txt", so reverse name order is newest first.
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            items = files.map(Self.read)
            loadError = nil
        } catch {
            items = []
            loadError = "Can't read \(folder.path): \(error.localizedDescription)"
        }
        if let selection, !items.contains(where: { $0.url == selection }) { self.selection = nil }
        if selection == nil { selection = items.first?.url }
    }

    /// Reads one file. An unreadable file still appears, with the error as its preview.
    private static func read(_ url: URL) -> TranscriptItem {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return TranscriptItem(url: url, title: url.lastPathComponent,
                                  preview: "Can't read this file: \(error.localizedDescription)", text: "")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let prefix = "Transcript — "
        let title = lines.first.map(String.init).flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
            ?? url.deletingPathExtension().lastPathComponent
        let firstSpoken = lines.first { $0.hasPrefix("[") }.map { line -> String in
            // "[00:01:02] Them: words" → "Them: words"
            guard let close = line.firstIndex(of: "]") else { return String(line) }
            return line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
        return TranscriptItem(url: url, title: title, preview: firstSpoken ?? "", text: text)
    }
}

/// The main window's content.
struct LibraryView: View {
    @ObservedObject var library: TranscriptLibrary
    @ObservedObject var model: AppModel
    @State private var copied = false

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            detail
        }
        // why: set here, not on the detail view, so it resets when the selected transcript goes away.
        .navigationTitle(library.selectedItem?.title ?? "Hark")
        .frame(minWidth: 700, minHeight: 420)
    }

    @ViewBuilder private var sidebar: some View {
        if let error = library.loadError {
            Text(error).foregroundStyle(.red).padding()
        } else if library.items.isEmpty {
            ContentUnavailableView("No transcripts yet", systemImage: "waveform",
                                   description: Text("Click Record on the floating bar. When you stop, the transcript shows up here."))
        } else {
            List(selection: $library.selection) {
                ForEach(library.items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        Text(item.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 3)
                    .tag(item.url)
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let item = library.selectedItem {
            ScrollView {
                Text(item.text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button { copy(item) } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy the whole transcript, ready to paste into an AI chat")
                    Button { saveCopy(item) } label: { Label("Save a Copy…", systemImage: "square.and.arrow.down") }
                        .help("Save a copy anywhere, like your Downloads folder")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    Button { trash(item) } label: { Label("Move to Trash", systemImage: "trash") }
                }
            }
        } else {
            ContentUnavailableView("Pick a transcript", systemImage: "text.alignleft")
        }
    }

    /// Puts the full text on the clipboard and briefly shows "Copied".
    private func copy(_ item: TranscriptItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    /// Lets the user pick where to save a copy; starts in Downloads.
    private func saveCopy(_ item: TranscriptItem) {
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            // why: the save panel already asked the user before replacing an existing file.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: item.url, to: destination)
        } catch {
            model.showError("Couldn't save the copy", error)
        }
    }

    /// Moves the file to the Trash (recoverable) and refreshes the list.
    private func trash(_ item: TranscriptItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            library.reload()
        } catch {
            model.showError("Couldn't move it to the Trash", error)
        }
    }
}
