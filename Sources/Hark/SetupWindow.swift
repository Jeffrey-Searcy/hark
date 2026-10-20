//
// SetupWindow.swift — first-run setup: downloads the model files and builds the
// Read Aloud Python environment, so a buyer never opens Terminal.
//
// At launch, AppDelegate asks SetupModel.missingItems() which pieces are not on disk
// yet. If none are missing (for example on a Mac that ran setup-reader.sh), this window
// never appears. Otherwise it lists the missing pieces with their sizes and fetches them
// one at a time when the user clicks the button:
//   - Model files are downloaded from fixed versions (pinned commits / release tags),
//     to "<name>.part" first, checked against a SHA-256 checksum, then renamed. A bad
//     or cut-off download never ends up under the real name.
//   - The Read Aloud environment is made with uv in a "venv-setup" folder: uv fetches
//     its own Python (kept inside Hark's folder), installs the exact packages listed in
//     reader-requirements.txt (checksums required), the imports are tested, and only
//     then is the folder renamed to "venv".
// Anything that fails stays missing and shows its error; "Try Again" redoes only that.
// Output from uv goes to AppPaths.readerSetupLog.
//

import AppKit
import CryptoKit
import SwiftUI

/// One piece the setup can install.
struct SetupItem: Identifiable {
    enum Kind {
        /// A single file, checked against `sha256` (lowercase hex) after download.
        case download(url: URL, sha256: String, destination: URL)
        /// The Read Aloud Python environment.
        case readerEnvironment
    }

    let id: String
    let title: String
    /// Approximate size on disk, for the list and the free-space check.
    let bytes: Int64
    let kind: Kind

    /// True if this piece is already on disk.
    var isInstalled: Bool {
        switch kind {
        case let .download(_, _, destination): return FileManager.default.fileExists(atPath: destination.path)
        case .readerEnvironment: return FileManager.default.fileExists(atPath: AppPaths.readerPython.path)
        }
    }
}

/// Where one setup item stands.
enum SetupItemState: Equatable {
    case waiting
    /// `fraction` is nil when progress can't be measured; `note` says what's happening.
    case working(fraction: Double?, note: String)
    case done
    case failed(String)
}

/// Runs the setup and publishes its progress. Lives until setup finishes.
@MainActor
final class SetupModel: ObservableObject {
    /// Every piece Hark can set up, in the order they are fetched (recording first).
    /// URLs point at fixed versions; checksums were taken from those exact files.
    static let catalog: [SetupItem] = [
        SetupItem(id: "whisper", title: "Speech recognition model (Whisper large-v3-turbo)", bytes: 1_624_555_275,
                  kind: .download(url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin")!,
                                  sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
                                  destination: AppPaths.whisperModel)),
        SetupItem(id: "vad", title: "Silence detector (Silero VAD)", bytes: 885_098,
                  kind: .download(url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin")!,
                                  sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
                                  destination: AppPaths.vadModel)),
        SetupItem(id: "reader-env", title: "Read Aloud engine (Python + Kokoro)", bytes: 260_000_000,
                  kind: .readerEnvironment),
        SetupItem(id: "kokoro", title: "Reading voice model (Kokoro)", bytes: 325_505_369,
                  kind: .download(url: URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/kokoro-v1.0.onnx")!,
                                  sha256: "beb0d1848dee9a49da392cc3df26958d46cfa35d321edf434f52949153f0df3a",
                                  destination: AppPaths.kokoroModel)),
        SetupItem(id: "voices", title: "Reading voices (George, Fable, …)", bytes: 28_214_398,
                  kind: .download(url: URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/voices-v1.0.bin")!,
                                  sha256: "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d",
                                  destination: AppPaths.kokoroVoices)),
    ]

    /// The catalog items not yet on disk.
    static func missingItems() -> [SetupItem] { catalog.filter { !$0.isInstalled } }

    /// The pieces this setup run installs (fixed when the window opens).
    let items: [SetupItem]
    @Published private(set) var states: [String: SetupItemState]
    @Published private(set) var running = false
    /// Set when the last run stopped on an error; the window offers "Try Again".
    @Published private(set) var failed = false
    /// Called once everything is installed. Set by AppDelegate.
    var onFinished: (() -> Void)?

    /// The uv process currently running, so quitting can stop it.
    private var process: Process?

    /// - Parameter items: the missing pieces, from `missingItems()`.
    init(items: [SetupItem]) {
        self.items = items
        states = Dictionary(uniqueKeysWithValues: items.map { ($0.id, SetupItemState.waiting) })
    }

    /// Total download size of the pieces still to install.
    var remainingBytes: Int64 { items.filter { states[$0.id] != .done }.reduce(0) { $0 + $1.bytes } }

    /// Installs every piece not yet done, one at a time; stops at the first failure.
    func start() {
        guard !running else { return }
        running = true
        failed = false
        Task {
            defer { running = false }
            do {
                try checkFreeSpace()
            } catch {
                failed = true
                presentError("Not enough disk space", error)
                return
            }
            for item in items where states[item.id] != .done {
                do {
                    try await install(item)
                    states[item.id] = .done
                } catch {
                    states[item.id] = .failed(error.localizedDescription)
                    failed = true
                    return
                }
            }
            onFinished?()
        }
    }

    /// Stops a running uv process (called when the app quits mid-setup).
    func cancel() {
        process?.terminate()
    }

    // MARK: Steps

    /// Throws if the disk can't hold what's left plus 1 GB of room to spare.
    private func checkFreeSpace() throws {
        let values = try FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            throw SetupError.diskSpaceUnknown
        }
        let needed = remainingBytes + 1_000_000_000
        if available < needed { throw SetupError.notEnoughSpace(needed: needed, available: available) }
    }

    private func install(_ item: SetupItem) async throws {
        switch item.kind {
        case let .download(url, sha256, destination):
            try await download(item, from: url, sha256: sha256, to: destination)
        case .readerEnvironment:
            try await buildReaderEnvironment(item)
        }
    }

    /// Downloads to "<destination>.part", checks the checksum, then renames into place.
    private func download(_ item: SetupItem, from url: URL, sha256: String, to destination: URL) async throws {
        let id = item.id
        states[id] = .working(fraction: 0, note: "Downloading…")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = destination.appendingPathExtension("part")
        try await FileDownload.run(from: url, to: part) { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .working = self.states[id] else { return }
                self.states[id] = .working(fraction: fraction, note: "Downloading…")
            }
        }
        states[id] = .working(fraction: nil, note: "Checking the file…")
        let actual = try await Task.detached { try Self.sha256(of: part) }.value
        guard actual == sha256 else {
            try FileManager.default.removeItem(at: part)
            throw SetupError.checksumMismatch(file: destination.lastPathComponent, expected: sha256, actual: actual)
        }
        try FileManager.default.moveItem(at: part, to: destination)
    }

    /// Makes the Read Aloud Python environment with uv in a staging folder, tests it, then renames it to "venv".
    private func buildReaderEnvironment(_ item: SetupItem) async throws {
        let id = item.id
        guard FileManager.default.isExecutableFile(atPath: AppPaths.uv.path) else {
            throw HarkError.missingDependency(path: AppPaths.uv.path, hint: AppPaths.bundledTools
                ? "It should be inside Hark.app. Download Hark again."
                : "Install it with: brew install uv")
        }
        let requirements = try AppPaths.readerRequirements()
        let staging = AppPaths.reader.appendingPathComponent("venv-setup", isDirectory: true)
        let cache = AppPaths.reader.appendingPathComponent("uv-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: AppPaths.reader, withIntermediateDirectories: true)
        // why: a folder left by a cut-off attempt may be half-built; start it clean.
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        FileManager.default.createFile(atPath: AppPaths.readerSetupLog.path, contents: nil)

        let python = AppPaths.readerPythonVersion
        states[id] = .working(fraction: nil, note: "Getting Python \(python)…")
        try await runUV(["python", "install", python], cache: cache)
        states[id] = .working(fraction: nil, note: "Making a private Python environment…")
        try await runUV(["venv", "--relocatable", "--python", python, "--python-preference", "only-managed", staging.path], cache: cache)
        states[id] = .working(fraction: nil, note: "Installing the voice engine…")
        let stagingPython = staging.appendingPathComponent("bin/python3")
        try await runUV(["pip", "install", "--python", stagingPython.path, "--require-hashes", "-r", requirements.path], cache: cache)
        states[id] = .working(fraction: nil, note: "Testing it…")
        try await runTool(stagingPython, ["-I", "-c", "import kokoro_onnx, trafilatura"], environment: [:])

        try FileManager.default.moveItem(at: staging, to: AppPaths.readerVenv)
        // why: the download cache is only needed during install; it would waste ~200 MB.
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
    }

    /// Runs uv with settings that keep everything inside Hark's folder and ignore any uv config on this Mac.
    private func runUV(_ arguments: [String], cache: URL) async throws {
        try await runTool(AppPaths.uv, arguments, environment: [
            "UV_PYTHON_INSTALL_DIR": AppPaths.readerPythonInstall.path,
            "UV_CACHE_DIR": cache.path,
            "UV_NO_CONFIG": "1",
            "UV_NO_PROGRESS": "1",
        ])
    }

    /// Runs a tool, appending its output to the setup log.
    /// - Parameter environment: added to (and overriding) Hark's own environment.
    /// - Throws: `HarkError.processFailed` with the log's last lines if it exits non-zero.
    private func runTool(_ tool: URL, _ arguments: [String], environment: [String: String]) async throws {
        let log = try FileHandle(forWritingTo: AppPaths.readerSetupLog)
        defer { try? log.close() }
        try log.seekToEnd()
        try log.write(contentsOf: Data("$ \(tool.lastPathComponent) \(arguments.joined(separator: " "))\n".utf8))

        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = log
        process.standardError = log
        self.process = process
        defer { self.process = nil }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else {
            let text = try String(contentsOf: AppPaths.readerSetupLog, encoding: .utf8)
            throw HarkError.processFailed(tool: tool.lastPathComponent, exitCode: status,
                                          log: text.split(separator: "\n").suffix(8).joined(separator: "\n"))
        }
    }

    /// SHA-256 of a file as lowercase hex, read in 8 MB pieces so big models don't fill memory.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Setup failures that aren't covered by HarkError.
enum SetupError: LocalizedError {
    case diskSpaceUnknown
    case notEnoughSpace(needed: Int64, available: Int64)
    case checksumMismatch(file: String, expected: String, actual: String)
    case httpStatus(url: URL, code: Int)

    var errorDescription: String? {
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        switch self {
        case .diskSpaceUnknown:
            return "macOS didn't say how much free disk space there is."
        case let .notEnoughSpace(needed, available):
            return "Setup needs \(size(needed)) free, but only \(size(available)) is free. Make some room, then try again."
        case let .checksumMismatch(file, expected, actual):
            return "\(file) didn't download correctly (checksum \(actual.prefix(12))…, expected \(expected.prefix(12))…). Try again."
        case let .httpStatus(url, code):
            return "The server answered \(code) for \(url.absoluteString)."
        }
    }
}

/// One file download with progress, as an async call. URLSession keeps this object alive
/// until the download ends.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    /// Set in didFinishDownloadingTo if the reply was bad or the file couldn't be moved.
    private var finishError: Error?

    private init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    /// Downloads `url` to `destination`, replacing any file there.
    /// - Parameter progress: called (on a background queue) with 0…1 as bytes arrive.
    static func run(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let download = FileDownload(destination: destination, progress: progress)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            download.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: download, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // why: the temporary file is deleted as soon as this method returns, so it must be moved now.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw SetupError.httpStatus(url: downloadTask.originalRequest?.url ?? location, code: http.statusCode)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finishError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let error = error ?? finishError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

/// Contents of the setup window.
struct SetupView: View {
    @ObservedObject var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up Hark").font(.title2.weight(.semibold))
                    Text("Hark works entirely on your Mac, so it needs these files once. Nothing you record is ever uploaded.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                ForEach(setup.items) { item in
                    row(item)
                    if item.id != setup.items.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
            HStack {
                Text("Setup log: \(AppPaths.readerSetupLog.path)")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                Button(setup.failed ? "Try Again" : "Download and Set Up (\(Self.size(setup.remainingBytes)))") {
                    setup.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(setup.running)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func row(_ item: SetupItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon(setup.states[item.id])
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.title)
                    Spacer()
                    Text(Self.size(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
                }
                switch setup.states[item.id] {
                case let .working(fraction, note):
                    if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                    Text(note).font(.caption).foregroundStyle(.secondary)
                case let .failed(message):
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder private func icon(_ state: SetupItemState?) -> some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .working: ProgressView().controlSize(.small)
        default: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
