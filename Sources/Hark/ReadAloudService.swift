//
// ReadAloudService.swift — the "Read Aloud with Hark" item in the macOS Services menu.
//
// Select text in any app, right-click → Services → Read Aloud with Hark. macOS copies the
// selection onto a private pasteboard and calls readAloud(_:userData:error:) here, so no
// Accessibility permission is needed (unlike ⌃⌥R). The menu item itself is declared under
// NSServices in Info.plist; NSMessage "readAloud" is the selector name below.
//

import AppKit

/// Receives text from the Services menu. Set as `NSApp.servicesProvider` at launch.
final class ReadAloudService: NSObject {
    /// Called with the selected text. Set by AppDelegate.
    var onText: ((String) -> Void)?

    /// Services entry point. Fills `error` (shown by macOS) when there is no text.
    /// - Parameters:
    ///   - pasteboard: holds the selection macOS sent.
    ///   - userData: the NSUserData value from Info.plist (unused).
    ///   - error: set to a message for macOS to show if the request can't be handled.
    @objc(readAloud:userData:error:)
    func readAloud(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }
        guard let onText else {
            error.pointee = "Hark is still starting. Try again in a moment." as NSString
            return
        }
        onText(text)
    }
}
