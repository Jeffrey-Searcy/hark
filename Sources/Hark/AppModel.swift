//
// AppModel.swift — the record → transcribe → save cycle, shared by the floating bar
// and the main window.
//
// State flow:  idle --Record--> recording --Stop--> transcribing --> saved | noSpeech --(a few s)--> idle
// Errors are always shown in an alert. When audio is kept after an error, the alert
// says where, and "Transcribe Leftover Recordings" in the bar's ⋯ menu retries it.
// All members are used on the main thread only; transcription runs on a background
// queue and hops back to main to publish results.
//

import AppKit
import Combine

/// What the recorder is doing right now; drives the floating bar.
enum RecorderState: Equatable {
    case idle
    case recording(since: Date)
    case transcribing
    /// A transcript was just saved to this file.
    case saved(URL)
    /// Recording finished but nobody spoke, so nothing was saved.
    case noSpeech
}

/// Owns the recorders and the current state. One instance for the app's lifetime.
final class AppModel: ObservableObject {
    private static let mutedKey = "micMuted"

    @Published private(set) var state: RecorderState = .idle
    /// Number of session folders that still need transcribing (after a crash or failure).
    @Published private(set) var leftoverCount = 0
    /// Set when the sessions folder can't be read; shown in the ⋯ menu instead of a count.
    @Published private(set) var leftoverError: String?

    /// Mic mute preference, remembered between launches and applied live while recording.
    @Published var micMuted: Bool = UserDefaults.standard.bool(forKey: mutedKey) {
        didSet {
            UserDefaults.standard.set(micMuted, forKey: Self.mutedKey)
            mic?.isMuted = micMuted
        }
    }

    /// The transcript list shown in the main window; reloaded after each save.
    let library: TranscriptLibrary
    /// Opens the main window, optionally selecting a transcript. Set by AppDelegate.
    var showLibrary: ((URL?) -> Void)?
    /// Runs just before recording starts. AppDelegate uses it to stop Read Aloud,
    /// so the voice isn't captured in the transcript.
    var willStartRecording: (() -> Void)?

    private var mic: MicRecorder?
    private var system: SystemAudioRecorder?
    private var session: RecordingSession?
    /// Bumped on every state change so a stale "return to idle" timer does nothing.
    private var stateToken = 0

    /// True while recording or transcribing (used to confirm before quitting).
    var isBusy: Bool { mic != nil || state == .transcribing }

    init(library: TranscriptLibrary) {
        self.library = library
        refreshLeftovers()
    }

    // MARK: Recording

    /// Starts recording when idle; stops and transcribes when recording; ignored while transcribing.
    func toggleRecording() {
        switch state {
        case .idle, .saved, .noSpeech: startRecording()
        case .recording: stopAndTranscribe()
        case .transcribing: NSSound.beep()
        }
    }

    /// Asks for mic access if needed, then starts both recorders.
    private func startRecording() {
        MicRecorder.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.showError("Can't record", HarkError.micPermissionDenied)
                return
            }
            self.willStartRecording?()
            do {
                let session = try RecordingSession.create()
                let mic = MicRecorder()
                mic.isMuted = self.micMuted
                try mic.start(writingTo: session.micURL)
                let system = SystemAudioRecorder()
                do {
                    try system.start(writingTo: session.systemURL)
                } catch {
                    // why: don't leave the mic running if system capture could not start.
                    var details = [error.localizedDescription]
                    do { try mic.stop() } catch { details.append("Also failed to stop the mic: \(error.localizedDescription)") }
                    do { try FileManager.default.removeItem(at: session.directory) } catch {
                        details.append("Also failed to remove \(session.directory.path): \(error.localizedDescription)")
                    }
                    throw HarkError.badSession(details.joined(separator: "\n"))
                }
                self.session = session
                self.mic = mic
                self.system = system
                self.setState(.recording(since: session.startedAt))
            } catch {
                self.showError("Can't start recording", error)
            }
        }
    }

    /// Stops both recorders. Returns the errors they reported (empty if all went well).
    @discardableResult
    func stopRecorders() -> [Error] {
        var errors: [Error] = []
        do { try system?.stop() } catch { errors.append(error) }
        do { try mic?.stop() } catch { errors.append(error) }
        system = nil
        mic = nil
        return errors
    }

    /// Stops recording and transcribes on a background queue.
    private func stopAndTranscribe() {
        guard let session else { return }
        self.session = nil
        let errors = stopRecorders()
        if !errors.isEmpty {
            setState(.idle)
            refreshLeftovers()
            showError("Recording had a problem",
                      HarkError.badSession(errors.map(\.localizedDescription).joined(separator: "\n")
                                                  + "\n\nAudio kept in \(session.directory.path)"))
            return
        }
        transcribe([session])
    }

    /// Re-runs transcription on every leftover session folder.
    func transcribeLeftovers() {
        do {
            let sessions = try RecordingSession.leftoverDirectories()
                .filter { $0 != session?.directory }
                .map(RecordingSession.load(from:))
            transcribe(sessions)
        } catch {
            showError("Can't read leftover recordings", error)
        }
    }

    /// Transcribes sessions one after another off the main thread, then publishes the result.
    private func transcribe(_ sessions: [RecordingSession]) {
        setState(.transcribing)
        DispatchQueue.global(qos: .userInitiated).async {
            var outcomes: [TranscriptionOutcome] = []
            var failure: (RecordingSession, Error)?
            for session in sessions {
                do {
                    outcomes.append(try TranscriptionPipeline().run(session))
                } catch {
                    failure = (session, error)
                    break
                }
            }
            DispatchQueue.main.async { self.finish(outcomes, failure: failure) }
        }
    }

    private func finish(_ outcomes: [TranscriptionOutcome], failure: (RecordingSession, Error)?) {
        library.reload()
        refreshLeftovers()
        if let (session, error) = failure {
            setState(.idle)
            showError("Transcription failed",
                      HarkError.badSession("\(error.localizedDescription)\n\nAudio kept in \(session.directory.path)"))
            return
        }
        let lastSaved = outcomes.reversed().compactMap { outcome -> URL? in
            if case let .saved(url) = outcome { return url } else { return nil }
        }.first
        if let lastSaved {
            setState(.saved(lastSaved), revertAfter: 10)
        } else {
            setState(.noSpeech, revertAfter: 5)
        }
    }

    /// Changes state; optionally returns to idle after `seconds` unless the state changed again first.
    private func setState(_ newState: RecorderState, revertAfter seconds: Double? = nil) {
        state = newState
        stateToken += 1
        guard let seconds else { return }
        let token = stateToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.stateToken == token else { return }
            self.setState(.idle)
        }
    }

    /// Clears a "saved" / "no speech" notice right away.
    func dismissNotice() {
        if state != .transcribing, mic == nil { setState(.idle) }
    }

    /// Recounts leftover session folders for the ⋯ menu.
    func refreshLeftovers() {
        do {
            leftoverCount = try RecordingSession.leftoverDirectories().filter { $0 != session?.directory }.count
            leftoverError = nil
        } catch {
            leftoverCount = 0
            leftoverError = error.localizedDescription
        }
    }

    // MARK: Errors

    /// Shows a modal alert with the error's full description.
    func showError(_ title: String, _ error: Error) {
        presentError(title, error)
    }
}

/// Shows a modal alert with the error's full description. Shared by recording and Read Aloud.
/// - Parameters:
///   - title: short headline, e.g. "Can't record".
///   - error: its `localizedDescription` becomes the alert's body.
func presentError(_ title: String, _ error: Error) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    NSApp.activate()
    alert.runModal()
}
