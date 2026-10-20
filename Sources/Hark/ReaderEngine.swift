//
// ReaderEngine.swift — runs and talks to the Python helper (Resources/reader_helper.py)
// that turns text into speech with Kokoro and pulls article text out of web pages.
//
// The helper starts on first use and stays running, so the voice model loads once.
// Messages are one JSON object per line over the helper's stdin/stdout; the protocol
// is documented at the top of reader_helper.py. The helper's stderr goes to
// AppPaths.readerLog. If the helper dies, every waiting request fails with its exit
// code and the last lines of that log.
// All members are used on the main thread only.
//

import Foundation

/// Errors from the Read Aloud feature.
enum ReaderError: LocalizedError {
    case blocked(String)
    case nothingToRead
    case nothingSelected
    case nothingCopied
    case needsAccessibility
    case keyEventFailed
    case hotKey(step: String, status: OSStatus)
    case helperFailed(String)
    case helperExited(code: Int32, log: String)
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case let .blocked(reason):
            return reason
        case .nothingToRead:
            return "There is no text to read."
        case .nothingSelected:
            return "No text was selected. Highlight some text (or a link), then press ⌃⌥R."
        case .nothingCopied:
            return "The clipboard has no text. Copy some text or a link first."
        case .needsAccessibility:
            return "Hark needs Accessibility permission to copy the text you selected."
        case .keyEventFailed:
            return "macOS would not let Hark send the Copy (⌘C) keystroke."
        case let .hotKey(step, status):
            return "Could not \(step) (error \(status)). Another app may already use ⌃⌥R."
        case let .helperFailed(message):
            return message
        case let .helperExited(code, log):
            return "The Read Aloud helper stopped (exit code \(code)).\n\(log)"
        case let .playbackFailed(detail):
            return "Could not play the audio: \(detail)"
        }
    }
}

/// Owns the helper process and matches replies to requests by id.
final class ReaderEngine {
    /// One request line sent to the helper. Nil fields are left out of the JSON.
    struct Request: Encodable {
        var id = 0
        let op: String
        var text: String?
        var voice: String?
        var speed: Double?
        var out: String?
        var url: String?

        static func speak(_ text: String, voice: String, speed: Double, out: URL) -> Request {
            Request(op: "speak", text: text, voice: voice, speed: speed, out: out.path)
        }

        static func extract(_ url: URL) -> Request {
            Request(op: "extract", url: url.absoluteString)
        }
    }

    /// One reply line. `title`/`text` are set only for "extract" replies.
    struct Reply: Decodable {
        let id: Int?
        let ok: Bool?
        let error: String?
        let fatal: String?
        let title: String?
        let text: String?
    }

    typealias Completion = (Result<Reply, Error>) -> Void

    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: Completion] = [:]
    private var nextID = 1
    /// Bytes read from the helper that don't yet end in a newline.
    private var buffer = Data()

    /// Sends a request, starting the helper first if needed. `completion` runs on the main thread.
    func send(_ request: Request, completion: @escaping Completion) {
        do {
            try launchIfNeeded()
        } catch {
            completion(.failure(error))
            return
        }
        var request = request
        request.id = nextID
        nextID += 1
        pending[request.id] = completion
        do {
            var line = try JSONEncoder().encode(request)
            line.append(0x0A)
            guard let input else { throw ReaderError.helperFailed("The Read Aloud helper is not running.") }
            try input.write(contentsOf: line)
        } catch {
            pending.removeValue(forKey: request.id)
            completion(.failure(error))
        }
    }

    /// Stops the helper (used when the app quits). Waiting requests fail.
    func shutdown() {
        process?.terminate()
    }

    /// Starts the helper process if it isn't running.
    private func launchIfNeeded() throws {
        if process != nil { return }
        try AppPaths.checkReaderDependencies()
        let script = try AppPaths.readerHelperScript()

        FileManager.default.createFile(atPath: AppPaths.readerLog.path, contents: nil)
        let log = try FileHandle(forWritingTo: AppPaths.readerLog)
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let process = Process()
        process.executableURL = AppPaths.readerPython
        // -I: isolated mode, so nothing in the current folder or env vars changes what Python loads.
        process.arguments = ["-I", script.path, "--model", AppPaths.kokoroModel.path, "--voices", AppPaths.kokoroVoices.path]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = log

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                self.input = nil
                self.buffer = Data()
                do { try log.close() } catch { NSLog("Hark: could not close helper log: \(error)") }
                self.failAll(ReaderError.helperExited(code: code, log: Self.logTail()))
            }
        }
        try process.run()
        self.process = process
        self.input = stdinPipe.fileHandleForWriting
    }

    /// Splits incoming bytes into lines and routes each reply to its request.
    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard !line.isEmpty else { continue }
            let reply: Reply
            do {
                reply = try JSONDecoder().decode(Reply.self, from: line)
            } catch {
                failAll(ReaderError.helperFailed("The Read Aloud helper sent something unreadable: \(String(decoding: line, as: UTF8.self))"))
                continue
            }
            if let fatal = reply.fatal {
                failAll(ReaderError.helperFailed(fatal))
                continue
            }
            guard let id = reply.id, let completion = pending.removeValue(forKey: id) else {
                failAll(ReaderError.helperFailed("The Read Aloud helper failed: \(reply.error ?? "reply without a request id")"))
                continue
            }
            if let error = reply.error {
                completion(.failure(ReaderError.helperFailed(error)))
            } else {
                completion(.success(reply))
            }
        }
    }

    /// Fails every waiting request with the same error.
    private func failAll(_ error: Error) {
        let waiting = pending
        pending = [:]
        for completion in waiting.values { completion(.failure(error)) }
    }

    /// Last lines of the helper's log, for error messages.
    private static func logTail() -> String {
        do {
            let text = try String(contentsOf: AppPaths.readerLog, encoding: .utf8)
            return text.split(separator: "\n").suffix(8).joined(separator: "\n")
        } catch {
            return "(could not read \(AppPaths.readerLog.path): \(error.localizedDescription))"
        }
    }
}
