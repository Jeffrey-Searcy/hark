//
// AppDelegate.swift — app lifecycle: builds the menu bar, the floating bar, and the
// main Hark window, registers the ⌃⌥R Read Aloud shortcut, and confirms
// before quitting mid-recording.
//
// The app has a normal Dock icon. Clicking it (or "Show Transcripts" in the bar's
// ⋯ menu) opens the main window. Closing the window does not quit: the floating
// bar stays so you can record at any time.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// App controller. Lives for the whole app run.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let library = TranscriptLibrary()
    private lazy var model = AppModel(library: library)
    private let reader = ReaderModel()
    private var bar: FloatingBarPanel?
    private var hotKey: GlobalHotKey?
    private var libraryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try AppPaths.checkDependencies()
        } catch {
            model.showError("Hark can't start", error)
            NSApp.terminate(nil)
            return
        }
        NSApp.mainMenu = buildMainMenu()
        model.showLibrary = { [weak self] url in self?.showLibrary(selecting: url) }
        setUpReader()
        bar = FloatingBarPanel(model: model, reader: reader)
        showLibrary(selecting: nil)
    }

    /// Connects Read Aloud to recording and registers ⌃⌥R. Problems are shown but don't stop the app,
    /// because recording doesn't need Read Aloud.
    private func setUpReader() {
        // why: the system-audio recorder would capture the voice into the transcript.
        reader.blockReason = { [weak self] in
            guard let self, case .recording = self.model.state else { return nil }
            return "Read Aloud is off while recording, so the voice doesn't end up in your transcript."
        }
        model.willStartRecording = { [weak self] in self?.reader.stop() }
        do {
            try reader.removeLeftoverAudio()
        } catch {
            presentError("Couldn't clear old Read Aloud audio", error)
        }
        do {
            hotKey = try GlobalHotKey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey) { [weak self] in
                self?.readSelection()
            }
        } catch {
            presentError("The ⌃⌥R shortcut is not available", error)
        }
    }

    /// ⌃⌥R: copies the selected text (or link) in the front app and reads it aloud.
    private func readSelection() {
        SelectionGrabber.copySelection { [weak self] result in
            switch result {
            case let .success(text):
                self?.reader.read(text)
            case let .failure(error):
                if case ReaderError.needsAccessibility = error {
                    SelectionGrabber.askForAccessibility()
                } else {
                    presentError("Nothing to read", error)
                }
            }
        }
    }

    /// Clicking the Dock icon brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary(selecting: nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isBusy else {
            reader.shutdown()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = model.state == .transcribing ? "Quit while the transcript is being written?" : "Stop recording and quit?"
        alert.informativeText = "The audio stays in \(AppPaths.sessions.path). Use \"Transcribe Leftover Recordings\" in the bar's ⋯ menu next time to finish it."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.stopRecorders()
        reader.shutdown()
        return .terminateNow
    }

    /// Opens (or creates) the main window, refreshes the list, and optionally selects a transcript.
    @objc func showLibrary(selecting url: URL?) {
        library.reload()
        if let url { library.selection = url }
        if libraryWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: LibraryView(library: library, model: model)))
            window.title = "Hark"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 900, height: 560))
            window.center()
            window.setFrameAutosaveName("HarkLibrary")
            libraryWindow = window
        }
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func showLibraryFromMenu() { showLibrary(selecting: nil) }

    /// File → Read Copied Text or Link: same as the bar's ⋯ menu item.
    @objc private func readClipboardFromMenu() { reader.readClipboard() }

    /// Standard app / Edit / Window menus so ⌘Q, ⌘C, ⌘A, ⌘W work.
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Hark", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Hark", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Hark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Hark", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        let show = fileMenu.addItem(withTitle: "Show Transcripts", action: #selector(showLibraryFromMenu), keyEquivalent: "1")
        show.target = self
        let readCopied = fileMenu.addItem(withTitle: "Read Copied Text or Link", action: #selector(readClipboardFromMenu), keyEquivalent: "")
        readCopied.target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }
}
