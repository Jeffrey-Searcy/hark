//
// main.swift — entry point.
//
// Normal launch: starts the app (Dock icon, main window, floating record bar).
// `Hark --transcribe <session-folder>`: runs only the transcription step on an
// existing session folder and prints the result. Used for testing and for recovering
// a recording by hand from Terminal.
//

import AppKit

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--transcribe" {
    do {
        try AppPaths.checkDependencies()
        let session = try RecordingSession.load(from: URL(fileURLWithPath: arguments[2], isDirectory: true))
        switch try TranscriptionPipeline().run(session) {
        case let .saved(url): print("Saved: \(url.path)")
        case .noSpeech: print("No speech found; nothing saved.")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// why: top-level code runs on the main thread; this tells the compiler so it can build the @MainActor delegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // why: .regular gives the app a Dock icon and menu bar, so the main window is easy to find.
    app.setActivationPolicy(.regular)
    app.run()
}
