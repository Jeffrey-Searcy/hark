//
// ReaderModel.swift — Read Aloud: speaks text or a web article with skip and rewind.
//
// How it works: the text is split into sentences (like tracks on a CD). The helper
// (ReaderEngine) turns each sentence into a small WAV file, staying up to
// `lookahead` sentences ahead of the one playing, so there are no gaps.
// ⏭ / ⏮ jump one sentence; ⏮ first restarts the current sentence if it has played
// for more than 2 seconds. The WAV files live in a temporary folder under
// AppPaths.readerCache that is deleted when reading stops.
// All members are used on the main thread only.
//

import AppKit
import AVFoundation
import NaturalLanguage

/// What Read Aloud is doing; drives the player in the floating bar.
enum ReaderState: Equatable {
    case idle
    /// Getting ready (e.g. downloading an article); the message says what's happening.
    case preparing(String)
    /// Reading sentence `index` (0-based) of `total`. `waiting` = that sentence's audio isn't made yet.
    case playing(index: Int, total: Int, paused: Bool, waiting: Bool)
}

/// Owns the sentence list, the audio player, and the helper. One instance for the app's lifetime.
final class ReaderModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// A Kokoro voice the user can pick. `id` is Kokoro's voice name.
    struct Voice: Identifiable {
        let id: String
        let name: String
    }

    /// Voices offered in the ⋯ menu: calm male narrators first.
    static let voices: [Voice] = [
        Voice(id: "bm_george", name: "George (British)"),
        Voice(id: "bm_fable", name: "Fable (British)"),
        Voice(id: "bm_lewis", name: "Lewis (British)"),
        Voice(id: "bm_daniel", name: "Daniel (British)"),
        Voice(id: "am_michael", name: "Michael (American)"),
        Voice(id: "am_onyx", name: "Onyx (American)"),
    ]
    private static let voiceKey = "readerVoice"
    /// Slightly slower than normal, for a narrator feel.
    private static let speed = 0.95
    /// How many sentences past the current one to prepare in advance.
    private static let lookahead = 3

    @Published private(set) var state: ReaderState = .idle

    /// Chosen voice id. Changing it mid-reading re-makes the sentences not yet played.
    @Published var voice: String {
        didSet {
            UserDefaults.standard.set(voice, forKey: Self.voiceKey)
            if cacheDir != nil {
                ready = ready.filter { $0.key <= current }
                pump()
            }
        }
    }

    /// Returns why reading can't start right now (e.g. recording), or nil if it can. Set by AppDelegate.
    var blockReason: (() -> String?)?

    private let engine = ReaderEngine()
    private var sentences: [String] = []
    private var current = 0
    private var paused = false
    /// Sentence index → its finished WAV file.
    private var ready: [Int: URL] = [:]
    /// True while the helper is making a sentence (one at a time, so skipping stays responsive).
    private var inFlight = false
    private var player: AVAudioPlayer?
    /// Temporary folder for this reading's WAV files; nil when not reading.
    private var cacheDir: URL?
    /// Bumped by stop(); replies that arrive for an older reading are ignored.
    private var runToken = 0

    /// The sentence being read, shown as a tooltip on the player.
    var currentSentence: String? { sentences.indices.contains(current) ? sentences[current] : nil }

    override init() {
        // why: register(defaults:) makes "George" the documented starting voice, not a hidden fallback.
        UserDefaults.standard.register(defaults: [Self.voiceKey: "bm_george"])
        voice = UserDefaults.standard.string(forKey: Self.voiceKey)!
        super.init()
    }

    // MARK: Starting

    /// Reads `input`: if it is a single web link, reads that page's article; otherwise reads the text.
    func read(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = Self.webLink(in: trimmed) {
            readArticle(at: url)
        } else {
            guard let token = begin() else { return }
            start(Self.sentences(in: trimmed), token: token)
        }
    }

    /// Reads whatever text or link is on the clipboard (no Accessibility permission needed).
    func readClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentError("Nothing to read", ReaderError.nothingCopied)
            return
        }
        read(text)
    }

    /// Downloads a page, pulls out the article, and reads its title and text.
    private func readArticle(at url: URL) {
        guard let token = begin() else { return }
        state = .preparing("Fetching the article…")
        engine.send(.extract(url)) { [weak self] result in
            guard let self, token == self.runToken else { return }
            switch result {
            case let .success(reply):
                let parts = [reply.title, reply.text].compactMap { $0 }.filter { !$0.isEmpty }
                self.start(Self.sentences(in: parts.joined(separator: "\n")), token: token)
            case let .failure(error):
                self.stop()
                presentError("Couldn't read that page", error)
            }
        }
    }

    /// Stops any current reading and checks reading is allowed. Returns the new run token, or nil if blocked.
    private func begin() -> Int? {
        if let reason = blockReason?() {
            presentError("Can't read aloud right now", ReaderError.blocked(reason))
            return nil
        }
        stop()
        return runToken
    }

    /// Sets up the temporary folder and starts making audio for the first sentences.
    private func start(_ list: [String], token: Int) {
        guard token == runToken else { return }
        guard !list.isEmpty else {
            stop()
            presentError("Nothing to read", ReaderError.nothingToRead)
            return
        }
        let dir = AppPaths.readerCache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            stop()
            presentError("Can't read aloud", error)
            return
        }
        cacheDir = dir
        sentences = list
        current = 0
        paused = false
        publish()
        pump()
    }

    // MARK: Controls

    /// Pauses or resumes.
    func togglePause() {
        guard cacheDir != nil else { return }
        paused.toggle()
        if paused { player?.pause() } else { player?.play() }
        publish()
    }

    /// Jumps to the next sentence (or stops after the last one).
    func next() {
        guard cacheDir != nil else { return }
        if current + 1 < sentences.count { go(to: current + 1) } else { stop() }
    }

    /// Restarts the current sentence if it has played for over 2 s; otherwise goes back one.
    func previous() {
        guard cacheDir != nil else { return }
        if let player, player.currentTime > 2 || current == 0 {
            player.currentTime = 0
        } else if current > 0 {
            go(to: current - 1)
        }
    }

    /// Stops reading and deletes this reading's audio files.
    /// If the helper is still making a sentence, the folder is deleted when that reply arrives (see pump()).
    func stop() {
        runToken += 1
        player?.stop()
        player = nil
        sentences = []
        ready = [:]
        current = 0
        paused = false
        if let dir = cacheDir {
            cacheDir = nil
            // why: deleting now would make the helper fail writing into a missing folder.
            if !inFlight { removeFolder(dir) }
        }
        inFlight = false
        state = .idle
    }

    /// Deletes one reading's temporary audio folder, showing an alert if that fails.
    private func removeFolder(_ dir: URL) {
        do { try FileManager.default.removeItem(at: dir) } catch {
            presentError("Couldn't delete Read Aloud's temporary files", error)
        }
    }

    /// Stops reading and the helper; called when the app quits.
    func shutdown() {
        stop()
        engine.shutdown()
    }

    /// Deletes temporary audio left by a reading that was cut off (e.g. a crash). Call at launch.
    func removeLeftoverAudio() throws {
        if FileManager.default.fileExists(atPath: AppPaths.readerCache.path) {
            try FileManager.default.removeItem(at: AppPaths.readerCache)
        }
    }

    // MARK: Internals

    /// Moves to sentence `index`, playing it now if its audio is ready.
    private func go(to index: Int) {
        player?.stop()
        player = nil
        current = index
        if ready[index] != nil { startPlayer() } else { publish() }
        pump()
    }

    /// Asks the helper for the next missing sentence in [current, current + lookahead].
    private func pump() {
        guard !inFlight, let dir = cacheDir, !sentences.isEmpty else { return }
        let end = min(current + Self.lookahead, sentences.count - 1)
        guard current <= end, let index = (current...end).first(where: { ready[$0] == nil }) else { return }
        inFlight = true
        let token = runToken
        // why: a new file name per request, so a re-made sentence (after a voice change) never collides.
        let out = dir.appendingPathComponent("\(index)-\(UUID().uuidString.prefix(8)).wav")
        let requestedVoice = voice
        engine.send(.speak(sentences[index], voice: requestedVoice, speed: Self.speed, out: out)) { [weak self] result in
            guard let self else { return }
            guard token == self.runToken else {
                // why: reading stopped while this was being made; stop() left the folder for us to delete.
                self.removeFolder(dir)
                return
            }
            self.inFlight = false
            switch result {
            case .success:
                // why: if the voice changed while this was being made, drop it; pump() re-makes it.
                if requestedVoice == self.voice { self.ready[index] = out }
                if index == self.current && self.player == nil { self.startPlayer() }
                self.pump()
            case let .failure(error):
                self.stop()
                presentError("Read Aloud stopped", error)
            }
        }
    }

    /// Starts (or, when paused, just loads) the player for the current sentence.
    private func startPlayer() {
        guard let url = ready[current] else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            if !paused { player.play() }
            self.player = player
            publish()
        } catch {
            stop()
            presentError("Read Aloud stopped", ReaderError.playbackFailed(error.localizedDescription))
        }
    }

    /// Pushes the current position to the floating bar.
    private func publish() {
        state = .playing(index: current, total: sentences.count, paused: paused, waiting: player == nil)
    }

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard finished === self.player else { return }
            guard flag else {
                self.stop()
                presentError("Read Aloud stopped", ReaderError.playbackFailed("the audio could not be decoded"))
                return
            }
            self.next()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ failed: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async {
            guard failed === self.player else { return }
            self.stop()
            presentError("Read Aloud stopped", ReaderError.playbackFailed(error.map(\.localizedDescription) ?? "decode error"))
        }
    }

    // MARK: Text helpers

    /// Splits text into sentences. Each line is split on its own, so headings without a period
    /// don't run into the next paragraph. Pieces with no letters or digits (bullets, dashes) are dropped.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        for line in text.components(separatedBy: .newlines) {
            let paragraph = line.trimmingCharacters(in: .whitespaces)
            guard !paragraph.isEmpty else { continue }
            tokenizer.string = paragraph
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                let sentence = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if sentence.rangeOfCharacter(from: .alphanumerics) != nil { result.append(sentence) }
                return true
            }
        }
        return result
    }

    /// Returns the URL if `text` is exactly one http(s) link, else nil.
    static func webLink(in text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }
}
