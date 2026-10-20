//
// AppPaths.swift — every file location and external tool Hark depends on.
//
// Layout:
//   ~/Library/Application Support/Hark/models/    Whisper + VAD model files
//   ~/Library/Application Support/Hark/sessions/  one folder per recording,
//                                                 deleted once its transcript is saved
//   ~/Library/Application Support/Hark/reader/    Read Aloud: Python, voice model, log
//   ~/Documents/Transcripts/                      finished .txt transcripts
// The data folder can be moved with the HARK_DATA_DIR environment variable (used to
// test first-run setup without touching real data).
//
// Two kinds of build, chosen by the HarkBundledTools key in Info.plist:
//   - Developer build (build.sh, key absent): whisper-cli and uv come from Homebrew.
//   - Release build (release.sh sets the key to true): whisper-cli and uv ship inside
//     Hark.app/Contents/MacOS, so buyers install nothing by hand.
// Nothing here falls back from one to the other. If a file is missing, the setup window
// (SetupWindow.swift) downloads what it can, and `checkDependencies()` names the rest.
//

import Foundation

/// Static file locations and settings shared by the recorder and the transcriber.
enum AppPaths {
    /// Root folder for app data (models + in-progress recordings + Read Aloud).
    /// HARK_DATA_DIR replaces it on purpose (for testing); it is not a fallback.
    static let support: URL = {
        if let custom = ProcessInfo.processInfo.environment["HARK_DATA_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hark", isDirectory: true)
    }()

    /// True in release builds, which carry whisper-cli and uv inside the app (see the top of this file).
    static let bundledTools = Bundle.main.object(forInfoDictionaryKey: "HarkBundledTools") as? Bool == true

    /// Folder holding the downloaded GGML model files.
    static let models = support.appendingPathComponent("models", isDirectory: true)

    /// Folder holding one subfolder per recording session (raw audio + metadata).
    static let sessions = support.appendingPathComponent("sessions", isDirectory: true)

    /// Where finished transcripts are written.
    static let transcripts = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Transcripts", isDirectory: true)

    /// whisper.cpp command-line tool: inside the app (release) or from `brew install whisper.cpp` (developer).
    static let whisperCLI = bundledTools
        ? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/whisper-cli")
        : URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")

    /// uv, which builds the Read Aloud Python environment: inside the app (release) or from `brew install uv`.
    static let uv = bundledTools
        ? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/uv")
        : URL(fileURLWithPath: "/opt/homebrew/bin/uv")

    /// Built-in macOS tool used to convert recordings to 16 kHz mono WAV for Whisper.
    static let afconvert = URL(fileURLWithPath: "/usr/bin/afconvert")

    /// Whisper speech model (large-v3-turbo: near large-v3 accuracy, much faster).
    static let whisperModel = models.appendingPathComponent("ggml-large-v3-turbo.bin")

    /// Silero voice-activity model; lets Whisper skip silence instead of inventing text for it.
    static let vadModel = models.appendingPathComponent("ggml-silero-v5.1.2.bin")

    /// Spoken language passed to Whisper. "auto" also works but can misdetect on short clips.
    static let whisperLanguage = "en"

    /// Verifies every external file the app needs is present.
    /// - Throws: `HarkError.missingDependency` naming the first missing file and how to get it.
    static func checkDependencies() throws {
        let required: [(URL, String)] = [
            (whisperCLI, bundledTools ? "It should be inside Hark.app. Download Hark again." : "Install it with: brew install whisper.cpp"),
            (afconvert, "It ships with macOS; your system install looks damaged."),
            (whisperModel, "Download ggml-large-v3-turbo.bin from huggingface.co/ggerganov/whisper.cpp into \(models.path)"),
            (vadModel, "Download ggml-silero-v5.1.2.bin from huggingface.co/ggml-org/whisper-vad into \(models.path)"),
        ]
        for (url, hint) in required where !FileManager.default.fileExists(atPath: url.path) {
            throw HarkError.missingDependency(path: url.path, hint: hint)
        }
    }

    // MARK: Read Aloud
    // Kept separate from the recorder's files: recording works even if Read Aloud isn't set up.

    /// Root folder for Read Aloud: Python environment, voice model, log, temporary audio.
    static let reader = support.appendingPathComponent("reader", isDirectory: true)

    /// The private Python environment (made by the setup window or Resources/setup-reader.sh).
    static let readerVenv = reader.appendingPathComponent("venv", isDirectory: true)

    /// Python inside that environment.
    static let readerPython = readerVenv.appendingPathComponent("bin/python3")

    /// Where the setup window has uv put its own copy of Python, so nothing goes outside Hark's folder.
    static let readerPythonInstall = reader.appendingPathComponent("python", isDirectory: true)

    /// Exact Python version for Read Aloud (kokoro-onnx 0.6.1 supports 3.10–3.13).
    static let readerPythonVersion = "3.12.12"

    /// Log of the last Read Aloud environment setup.
    static let readerSetupLog = reader.appendingPathComponent("setup.log")

    /// Kokoro text-to-speech model.
    static let kokoroModel = reader.appendingPathComponent("models/kokoro-v1.0.onnx")

    /// Kokoro voice styles (George, Fable, …).
    static let kokoroVoices = reader.appendingPathComponent("models/voices-v1.0.bin")

    /// The helper's error output; replaced each time the helper starts.
    static let readerLog = reader.appendingPathComponent("helper.log")

    /// Temporary per-sentence audio; one subfolder per reading, deleted when it stops.
    static let readerCache = reader.appendingPathComponent("cache", isDirectory: true)

    /// The helper script, copied into the app bundle by build.sh.
    /// - Throws: `HarkError.missingDependency` if the app was built without it.
    static func readerHelperScript() throws -> URL {
        guard let url = Bundle.main.url(forResource: "reader_helper", withExtension: "py") else {
            throw HarkError.missingDependency(path: Bundle.main.bundlePath + "/Contents/Resources/reader_helper.py",
                                                     hint: "Rebuild the app with ./build.sh.")
        }
        return url
    }

    /// Locked list of Python packages (exact versions + checksums), copied into the app bundle.
    /// - Throws: `HarkError.missingDependency` if the app was built without it.
    static func readerRequirements() throws -> URL {
        guard let url = Bundle.main.url(forResource: "reader-requirements", withExtension: "txt") else {
            throw HarkError.missingDependency(path: Bundle.main.bundlePath + "/Contents/Resources/reader-requirements.txt",
                                              hint: "Rebuild the app with ./build.sh.")
        }
        return url
    }

    /// Verifies the Read Aloud environment and model files are present.
    /// - Throws: `HarkError.missingDependency` naming the first missing file.
    static func checkReaderDependencies() throws {
        let hint = "Quit and reopen Hark to finish setting up Read Aloud."
        for url in [readerPython, kokoroModel, kokoroVoices] where !FileManager.default.fileExists(atPath: url.path) {
            throw HarkError.missingDependency(path: url.path, hint: hint)
        }
    }
}

/// All errors Hark raises itself. Each case carries enough detail to show the user.
enum HarkError: LocalizedError {
    case missingDependency(path: String, hint: String)
    case coreAudio(step: String, status: OSStatus)
    case noMicrophone
    case micPermissionDenied
    case audioWrite(track: String, underlying: Error)
    case badAudioFormat(String)
    case processFailed(tool: String, exitCode: Int32, log: String)
    case badWhisperOutput(path: String, underlying: Error)
    case badSession(String)

    var errorDescription: String? {
        switch self {
        case let .missingDependency(path, hint):
            return "Missing file: \(path)\n\(hint)"
        case let .coreAudio(step, status):
            return "Core Audio failed to \(step) (error \(status))."
        case .noMicrophone:
            return "No microphone was found."
        case .micPermissionDenied:
            return "Hark is not allowed to use the microphone.\nTurn it on in System Settings → Privacy & Security → Microphone."
        case let .audioWrite(track, underlying):
            return "Could not save the \(track) audio: \(underlying.localizedDescription)"
        case let .badAudioFormat(detail):
            return "Unexpected audio format: \(detail)"
        case let .processFailed(tool, exitCode, log):
            return "\(tool) failed (exit code \(exitCode)).\n\(log)"
        case let .badWhisperOutput(path, underlying):
            return "Could not read Whisper's output at \(path): \(underlying.localizedDescription)"
        case let .badSession(detail):
            return "Recording folder is not usable: \(detail)"
        }
    }
}
