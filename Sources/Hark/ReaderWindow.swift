//
// ReaderWindow.swift — the Read Aloud window: shows the text being read and highlights
// the sentence you hear, like a marker pen following along.
//
// It opens on its own when a reading starts (without taking focus from the app you're
// in), scrolls to keep the paragraph being read in view, and plays any sentence you
// click. Closing it doesn't stop reading; the floating bar keeps its controls.
// When nothing is being read it offers buttons to start a reading.
// Keys while the window is in front: Space pauses/resumes, ← / → go back/skip.
//
// Each paragraph is one Text built from an AttributedString. Every sentence is a link
// to "hark://sentence/<index>", so clicking it calls ReaderModel.jump(to:) through the
// openURL action below instead of opening a browser.
//

import SwiftUI

/// One paragraph of the text being read, as laid out in the window.
private struct Paragraph: Identifiable {
    /// The paragraph number (Sentence.paragraph); also the scroll target.
    let id: Int
    /// Index into ReaderModel.sentences, and that sentence's text.
    let sentences: [(index: Int, text: String)]
}

/// Contents of the reading window.
struct ReaderWindowView: View {
    @ObservedObject var reader: ReaderModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .frame(height: 48)
            Divider()
            switch reader.state {
            case .idle:
                idle
            case let .preparing(message):
                VStack(spacing: 10) {
                    ProgressView()
                    Text(message).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .playing(index, _, _, _):
                text(current: index)
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if case let .playing(index, total, paused, waiting) = reader.state {
                Button { reader.previous() } label: { Image(systemName: "backward.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Back one sentence (←)")
                Button { reader.togglePause() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill").frame(width: 14)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(paused ? "Resume (Space)" : "Pause (Space)")
                Button { reader.next() } label: { Image(systemName: "forward.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Skip one sentence (→)")
                Text("\(index + 1) / \(total)").monospacedDigit().foregroundStyle(.secondary)
                if waiting && !paused { ProgressView().controlSize(.small).help("Preparing the next sentence…") }
                Spacer(minLength: 8)
                if let source = reader.sourceName {
                    Text(source).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Button("Stop") { reader.stop() }.help("Stop reading")
            } else if case .preparing = reader.state {
                Text("Read Aloud").font(.headline)
                Spacer()
                Button("Stop") { reader.stop() }
            } else {
                Text("Read Aloud").font(.headline)
                Spacer()
            }
        }
        .controlSize(.regular)
    }

    // MARK: Idle

    private var idle: some View {
        VStack(spacing: 14) {
            Image(systemName: "speaker.wave.2").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Nothing is being read").font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                Button { reader.readFrontPage() } label: { Label("Read This Page", systemImage: "safari") }
                    .help("Read the article in the browser window behind this one")
                Button { reader.readClipboard() } label: { Label("Read Copied Text or Link", systemImage: "doc.on.clipboard") }
            }
            .controlSize(.large)
            VStack(spacing: 4) {
                Text("Anywhere: select text, then right-click → Services → Read Aloud with Hark.")
                Text("Or select text and press ⌃⌥R.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Text

    /// The full text, current sentence highlighted, kept in view as reading moves on.
    private func text(current: Int) -> some View {
        let paragraphs = Self.paragraphs(reader.sentences)
        // why: sentences and state are published together, but a render could land between them during stop().
        let currentParagraph = reader.sentences.indices.contains(current) ? reader.sentences[current].paragraph : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(paragraphs) { paragraph in
                        Text(Self.attributed(paragraph, current: current))
                            .font(.system(size: 16))
                            .lineSpacing(5)
                            .tint(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(paragraph.id)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .onAppear { if let currentParagraph { proxy.scrollTo(currentParagraph, anchor: .center) } }
            .onChange(of: currentParagraph) { _, paragraph in
                guard let paragraph else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(paragraph, anchor: .center) }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "hark", url.host() == "sentence", let index = Int(url.lastPathComponent) else {
                NSLog("Hark: unexpected link in the reading window: \(url)")
                return .discarded
            }
            reader.jump(to: index)
            return .handled
        })
    }

    /// Groups consecutive sentences that share a paragraph number.
    private static func paragraphs(_ sentences: [Sentence]) -> [Paragraph] {
        var result: [Paragraph] = []
        var items: [(index: Int, text: String)] = []
        for (index, sentence) in sentences.enumerated() {
            if let last = items.last, sentences[last.index].paragraph != sentence.paragraph {
                result.append(Paragraph(id: sentences[last.index].paragraph, sentences: items))
                items = []
            }
            items.append((index, sentence.text))
        }
        if let last = items.last { result.append(Paragraph(id: sentences[last.index].paragraph, sentences: items)) }
        return result
    }

    /// One paragraph as styled text: past sentences dimmed, the current one highlighted,
    /// and every sentence a clickable link to itself.
    private static func attributed(_ paragraph: Paragraph, current: Int) -> AttributedString {
        var result = AttributedString()
        for (position, item) in paragraph.sentences.enumerated() {
            if position > 0 { result += AttributedString(" ") }
            var run = AttributedString(item.text)
            run.link = URL(string: "hark://sentence/\(item.index)")
            if item.index == current {
                run.backgroundColor = Color.yellow.opacity(0.45)
            } else if item.index < current {
                run.foregroundColor = .secondary
            }
            result += run
        }
        return result
    }
}
