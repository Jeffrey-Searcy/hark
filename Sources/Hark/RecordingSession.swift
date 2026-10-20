//
// RecordingSession.swift — one recording on disk.
//
// Each session is a folder under AppPaths.sessions:
//   mic.caf      microphone track ("Me")
//   system.caf   computer audio track ("Them")
//   meta.json    { "startedAt": <ISO-8601 date> }
// The folder is created when recording starts and deleted once a transcript is
// saved (or once we know nothing was said). If anything fails, the folder stays,
// so the audio is never lost and can be transcribed again from the button's menu.
//

import Foundation

/// A recording's folder plus the time it started.
struct RecordingSession {
    /// The session's folder.
    let directory: URL
    /// Wall-clock time recording began; used for the transcript header and file name.
    let startedAt: Date

    /// Microphone track file.
    var micURL: URL { directory.appendingPathComponent("mic.caf") }
    /// Computer-audio track file.
    var systemURL: URL { directory.appendingPathComponent("system.caf") }
    /// Metadata file holding `startedAt`.
    var metaURL: URL { directory.appendingPathComponent("meta.json") }

    /// Shape of meta.json.
    private struct Meta: Codable { let startedAt: Date }

    /// Creates a new, empty session folder named after the current time and writes meta.json.
    /// - Returns: the new session.
    /// - Throws: file-system errors from creating the folder or writing metadata.
    static func create() throws -> RecordingSession {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = AppPaths.sessions.appendingPathComponent(formatter.string(from: now), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = RecordingSession(directory: dir, startedAt: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Meta(startedAt: now)).write(to: session.metaURL)
        return session
    }

    /// Loads an existing session folder (used to re-transcribe leftovers).
    /// - Parameter directory: a folder previously made by `create()`.
    /// - Throws: `HarkError.badSession` if meta.json is missing or unreadable.
    static func load(from directory: URL) throws -> RecordingSession {
        let metaURL = directory.appendingPathComponent("meta.json")
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let meta = try decoder.decode(Meta.self, from: Data(contentsOf: metaURL))
            return RecordingSession(directory: directory, startedAt: meta.startedAt)
        } catch {
            throw HarkError.badSession("\(metaURL.path): \(error.localizedDescription)")
        }
    }

    /// Lists session folders left on disk (a crash, a failed transcription, or one in progress).
    /// - Returns: folder URLs, oldest first. Empty if the sessions folder does not exist yet.
    static func leftoverDirectories() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: AppPaths.sessions.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: AppPaths.sessions, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
