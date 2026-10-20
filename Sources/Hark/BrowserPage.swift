//
// BrowserPage.swift — finds the web page you're looking at, for "Read This Page".
//
// Step 1: find the browser window nearest the front of the screen. The window list
// from CGWindowListCopyWindowInfo is in front-to-back order, so the first window owned
// by a known browser is the one you're looking at. This works whether you clicked the
// floating bar (browser still in front) or Hark's own window (browser just behind it).
// Step 2: ask that browser for its front tab's address with AppleScript. macOS asks
// you once per browser whether Hark may do this (Privacy & Security → Automation);
// the reason shown comes from NSAppleEventsUsageDescription in Info.plist.
// Firefox has no AppleScript support, so it gets a clear error with a workaround.
//

import AppKit

/// Gets the address of the front browser tab. Stateless.
enum BrowserPage {
    /// The two AppleScript vocabularies browsers use for "the tab you're looking at".
    private enum Dialect {
        /// Safari: `current tab of front window`.
        case safari
        /// Chrome and the browsers built on it: `active tab of front window`.
        case chromium
    }

    /// Browsers Hark can ask, by bundle id.
    private static let scriptable: [String: Dialect] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.brave.Browser": .chromium,
        "company.thebrowser.Browser": .chromium,  // Arc
        "com.vivaldi.Vivaldi": .chromium,
    ]

    /// Browsers that can't be asked; finding one in front gives a clear error instead of picking another browser.
    private static let unscriptable: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
    ]

    /// AppleScript can wait on a permission prompt, so it runs here instead of on the main thread.
    private static let queue = DispatchQueue(label: "app.hark.browser-page")

    /// Finds the front browser tab's address.
    /// - Parameter completion: runs on the main thread with an http(s) URL, or a ReaderError explaining what to do.
    static func frontTabURL(completion: @escaping (Result<URL, Error>) -> Void) {
        let browser: NSRunningApplication
        do {
            browser = try frontBrowser()
        } catch {
            completion(.failure(error))
            return
        }
        // why: frontBrowser() only returns apps whose bundle id is in one of the two lists.
        let bundleID = browser.bundleIdentifier!
        let name = browser.localizedName ?? bundleID
        guard let dialect = scriptable[bundleID] else {
            completion(.failure(ReaderError.browserCantShare(name)))
            return
        }
        queue.async {
            let result = Result { try askForURL(bundleID: bundleID, name: name, dialect: dialect) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The known browser that owns the on-screen window nearest the front.
    /// - Throws: `ReaderError.noBrowser` if no known browser has a window on screen.
    private static func frontBrowser() throws -> NSRunningApplication {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            throw ReaderError.browserFailed(browser: "the window list", detail: "macOS returned no window list")
        }
        for window in windows {
            // why: layer 0 holds normal app windows; menus, the Dock, and floating panels use other layers.
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let id = app.bundleIdentifier,
                  scriptable[id] != nil || unscriptable.contains(id) else { continue }
            return app
        }
        throw ReaderError.noBrowser
    }

    /// Runs the AppleScript that returns the front tab's address. Call on `queue`.
    /// - Throws: `browserNotAllowed` if the user said no in the Automation prompt,
    ///   `browserFailed` for other script errors, `notAWebPage` for non-http(s) tabs.
    private static func askForURL(bundleID: String, name: String, dialect: Dialect) throws -> URL {
        let tab = dialect == .safari ? "current tab" : "active tab"
        let source = "tell application id \"\(bundleID)\" to return URL of \(tab) of front window"
        guard let script = NSAppleScript(source: source) else {
            throw ReaderError.browserFailed(browser: name, detail: "the script could not be created")
        }
        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -1743 = errAEEventNotPermitted: the user turned this off in Automation settings.
            if errorInfo[NSAppleScript.errorNumber] as? Int == -1743 { throw ReaderError.browserNotAllowed(name) }
            if let message = errorInfo[NSAppleScript.errorMessage] as? String {
                throw ReaderError.browserFailed(browser: name, detail: message)
            }
            throw ReaderError.browserFailed(browser: name, detail: "\(errorInfo)")
        }
        guard let address = output.stringValue else {
            throw ReaderError.browserFailed(browser: name, detail: "it returned no address")
        }
        guard let url = ReaderModel.webLink(in: address) else { throw ReaderError.notAWebPage(address) }
        return url
    }
}
