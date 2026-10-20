//
// FloatingBar.swift — the small always-on-top control bar.
//
// Layout (idle):       ⋮⋮  ● Record   🎤 Mic on   ⋯
//        (recording):  ⋮⋮  ■ Stop 0:42  🎤 Mic on  ⋯
//        (after stop): ⋮⋮  ✓ Transcript saved   Open   ✕
//        (reading):    ⋮⋮  ⏮ ⏸ ⏭  12 / 40          ✕     (Read Aloud player; replaces the rest)
// The ⋮⋮ grip drags the bar; its position is remembered between launches.
// FloatingBarPanel is a borderless, non-activating panel: it floats over every
// window and Space (including full-screen Zoom) and never steals keyboard focus.
//

import AppKit
import SwiftUI

/// Panel that hosts `FloatingBarView`.
final class FloatingBarPanel: NSPanel {
    static let size = NSSize(width: 290, height: 44)
    private static let originKey = "barOrigin"

    /// Creates the panel at its saved spot (or bottom-right of the main screen) and shows it.
    init(model: AppModel, reader: ReaderModel) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // why: show on every desktop Space and over full-screen apps like a full-screen Zoom call.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = FloatingBarView(model: model, reader: reader, onMoved: { [weak self] in self?.saveOrigin() })
        contentView = FirstClickHostingView(rootView: view)
        setFrameOrigin(Self.restoredOrigin())
        orderFrontRegardless()
    }

    /// Saved origin if it is still on a connected screen; otherwise bottom-right of the main screen.
    private static func restoredOrigin() -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: originKey) {
            let point = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(origin: point, size: size)) }) {
                return point
            }
        }
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
    }

    private func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }
}

/// Hosting view that reacts to the first click, since the panel never becomes active.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The bar's contents.
struct FloatingBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var reader: ReaderModel
    /// Called after the user drags the bar somewhere new.
    let onMoved: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            DragGrip(onMoved: onMoved)
                .frame(width: 14, height: 28)
                .help("Drag to move")
            if reader.state == .idle { content } else { player }
        }
        .padding(.horizontal, 8)
        .frame(width: FloatingBarPanel.size.width, height: FloatingBarPanel.size.height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10)))
        )
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            BarButton(tint: .red.opacity(0.18), help: "Start recording your mic and computer audio") {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text("Record")
            } action: { model.toggleRecording() }
            micButton
            Spacer(minLength: 0)
            moreMenu
        case let .recording(since):
            BarButton(tint: .red, help: "Stop and write the transcript") {
                RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 8, height: 8)
                Text("Stop")
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.elapsed(from: since, to: context.date)).monospacedDigit()
                }
            } action: { model.toggleRecording() }
            micButton
            Spacer(minLength: 0)
            moreMenu
        case .transcribing:
            ProgressView().controlSize(.small)
            Text("Writing transcript…").foregroundStyle(.secondary)
            Spacer(minLength: 0)
        case let .saved(url):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Transcript saved")
            Spacer(minLength: 0)
            BarButton(tint: .white.opacity(0.10), help: "Open it in the Hark window") {
                Text("Open")
            } action: { model.showLibrary?(url); model.dismissNotice() }
            closeButton
        case .noSpeech:
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("No speech heard, nothing saved").foregroundStyle(.secondary)
            Spacer(minLength: 0)
            closeButton
        }
    }

    /// Read Aloud controls, shown instead of the recorder while reading.
    @ViewBuilder private var player: some View {
        switch reader.state {
        case .idle:
            EmptyView()
        case let .preparing(message):
            ProgressView().controlSize(.small)
            Text(message).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            stopReadingButton
        case let .playing(index, total, paused, waiting):
            PlayerButton(symbol: "backward.fill", help: "Back one sentence") { reader.previous() }
            if waiting && !paused {
                ProgressView().controlSize(.small).frame(width: 30, height: 28).help("Preparing the next sentence…")
            } else {
                PlayerButton(symbol: paused ? "play.fill" : "pause.fill", help: paused ? "Resume" : "Pause") {
                    reader.togglePause()
                }
            }
            PlayerButton(symbol: "forward.fill", help: "Skip one sentence") { reader.next() }
            Text("\(index + 1) / \(total)")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .help(reader.currentSentence ?? "")
            Spacer(minLength: 0)
            stopReadingButton
        }
    }

    private var stopReadingButton: some View {
        Button { reader.stop() } label: {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help("Stop reading")
    }

    /// Mic on/off switch, separate from Record so muting never stops a recording.
    private var micButton: some View {
        BarButton(tint: model.micMuted ? .orange.opacity(0.25) : .white.opacity(0.08),
                  help: model.micMuted ? "Your mic is off. Click to record your voice too."
                                       : "Your mic is on. Click to leave your voice out.") {
            Image(systemName: model.micMuted ? "mic.slash.fill" : "mic.fill")
                .foregroundStyle(model.micMuted ? Color.orange : Color.primary)
            Text(model.micMuted ? "Mic off" : "Mic on")
        } action: { model.micMuted.toggle() }
    }

    private var moreMenu: some View {
        Menu {
            Button("Show Transcripts") { model.showLibrary?(nil) }
            Divider()
            Button("Read Copied Text or Link") { reader.readClipboard() }
            Text("Read Selected Text: ⌃⌥R")
            Picker("Reading Voice", selection: $reader.voice) {
                ForEach(ReaderModel.voices) { voice in Text(voice.name).tag(voice.id) }
            }
            Divider()
            if let error = model.leftoverError {
                Text("Can't check leftover recordings: \(error)")
            } else if model.leftoverCount > 0 {
                Button("Transcribe Leftover Recordings (\(model.leftoverCount))") { model.transcribeLeftovers() }
            }
            Divider()
            Button("Quit Hark") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis").frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private var closeButton: some View {
        Button { model.dismissNotice() } label: {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help("Dismiss")
    }

    /// "M:SS", or "H:MM:SS" after an hour.
    static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Rounded pill button used throughout the bar.
private struct BarButton<Label: View>: View {
    let tint: Color
    let help: String
    @ViewBuilder let label: () -> Label
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { label() }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Round icon-only button for the Read Aloud player.
private struct PlayerButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Six-dot grip; dragging it moves the whole panel.
private struct DragGrip: NSViewRepresentable {
    let onMoved: () -> Void

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ view: GripView, context: Context) { view.onMoved = onMoved }

    final class GripView: NSView {
        var onMoved: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {
            // why: performDrag runs the system's own window-move loop and returns on mouse-up.
            window?.performDrag(with: event)
            onMoved?()
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.35).setFill()
            for row in 0..<3 {
                for col in 0..<2 {
                    let x = bounds.midX - 3.5 + CGFloat(col) * 5
                    let y = bounds.midY - 6.5 + CGFloat(row) * 5
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 3, height: 3)).fill()
                }
            }
        }
    }
}
