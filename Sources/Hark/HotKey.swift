//
// HotKey.swift — the ⌃⌥R "read the selection aloud" shortcut.
//
// GlobalHotKey registers a system-wide shortcut with Carbon's RegisterEventHotKey,
// which needs no permission. SelectionGrabber then copies whatever is selected in
// the front app by sending it ⌘C (this part needs Accessibility permission), reads
// the text, and puts the user's previous clipboard contents back.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Lives as long as this object does.
final class GlobalHotKey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Registers the shortcut.
    /// - Parameters:
    ///   - keyCode: Carbon virtual key code, e.g. `kVK_ANSI_R`.
    ///   - modifiers: Carbon modifier mask, e.g. `controlKey | optionKey`.
    ///   - action: runs on the main thread each time the shortcut is pressed.
    /// - Throws: `ReaderError.hotKey` if macOS refuses (usually: another app owns the shortcut).
    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) throws {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installStatus == noErr else {
            throw ReaderError.hotKey(step: "install the shortcut handler", status: installStatus)
        }
        let id = EventHotKeyID(signature: OSType(0x5452_4E53), id: 1) // 'TRNS'
        let registerStatus = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            RemoveEventHandler(handlerRef)
            throw ReaderError.hotKey(step: "register the ⌃⌥R shortcut", status: registerStatus)
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// Copies the front app's selected text without leaving it on the clipboard.
enum SelectionGrabber {
    /// One clipboard item: every type it offers, with its data.
    private typealias SavedItem = [(NSPasteboard.PasteboardType, Data)]

    /// Copies the selection and returns its text on the main thread.
    /// Fails with `.needsAccessibility` if permission is missing, or `.nothingSelected` if nothing was copied.
    static func copySelection(completion: @escaping (Result<String, Error>) -> Void) {
        guard AXIsProcessTrusted() else {
            completion(.failure(ReaderError.needsAccessibility))
            return
        }
        // why: the user is still holding ⌃⌥ when the shortcut fires; wait so ⌘C isn't sent as ⌃⌥⌘C.
        waitForModifierRelease(until: Date().addingTimeInterval(1.0)) {
            let pasteboard = NSPasteboard.general
            let saved = snapshot(pasteboard)
            let before = pasteboard.changeCount
            guard postCommandC() else {
                completion(.failure(ReaderError.keyEventFailed))
                return
            }
            waitForChange(pasteboard, from: before, until: Date().addingTimeInterval(1.0)) { changed in
                guard changed else {
                    completion(.failure(ReaderError.nothingSelected))
                    return
                }
                let text = pasteboard.string(forType: .string)
                restore(saved, to: pasteboard)
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    completion(.failure(ReaderError.nothingSelected))
                    return
                }
                completion(.success(text))
            }
        }
    }

    /// Explains why Accessibility is needed and offers to open the right Settings page.
    static func askForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Allow Hark to copy your selection"
        alert.informativeText = """
        To read selected text with ⌃⌥R, Hark sends a Copy (⌘C) to the app you're using. \
        macOS calls this Accessibility permission.

        Turn on Hark in System Settings → Privacy & Security → Accessibility, then press ⌃⌥R again.

        No permission? Copy the text or link yourself and choose "Read Copied Text or Link" in the bar's ⋯ menu.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // why: asking with the prompt option is what adds Hark to the Accessibility list.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Calls `then` once no modifier keys are held, or when `deadline` passes.
    private static func waitForModifierRelease(until deadline: Date, then: @escaping () -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        // why: if keys are still held at the deadline we go ahead; the ⌘C below sets its own modifier flags.
        if held.isEmpty || Date() >= deadline {
            then()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { waitForModifierRelease(until: deadline, then: then) }
        }
    }

    /// Calls `then(true)` once the clipboard changes, or `then(false)` at the deadline.
    private static func waitForChange(_ pasteboard: NSPasteboard, from count: Int, until deadline: Date,
                                      then: @escaping (Bool) -> Void) {
        if pasteboard.changeCount != count {
            then(true)
        } else if Date() >= deadline {
            then(false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                waitForChange(pasteboard, from: count, until: deadline, then: then)
            }
        }
    }

    /// Sends ⌘C to the front app. Returns false if macOS wouldn't create the key events.
    private static func postCommandC() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Copies every item and type currently on the clipboard.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [SavedItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    /// Puts a snapshot back on the clipboard.
    private static func restore(_ saved: [SavedItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
