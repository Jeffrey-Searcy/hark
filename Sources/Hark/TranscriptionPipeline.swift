//
// TranscriptionPipeline.swift — turns a finished RecordingSession into a .txt transcript.
//
// Steps for each track (mic = "Me", system = "Them"):
//   1. afconvert → 16 kHz mono 16-bit WAV (the input whisper.cpp expects)
//   2. whisper-cli with Silero VAD → JSON segments with start/end times in ms
// Then both tracks' segments are merged in time order, back-to-back lines from the
// same speaker are joined, and the result is written to ~/Documents/Transcripts.
// If neither track contains speech, no file is written.
// Runs synchronously; call it off the main thread. It can take a minute or two for
// an hour of audio on Apple Silicon.
//

import AVFoundation
import Foundation

/// Who said a line.
enum Speaker: String {
    case me = "Me"
    case them = "Them"
}

/// One stretch of speech from one track, with times relative to recording start.
struct Segment {
    let speaker: Speaker
    let startMs: Int
    let endMs: Int
    var text: String
}

/// What happened to a session.
enum TranscriptionOutcome {
    /// A transcript was written to this file.
    case saved(URL)
    /// Nobody spoke, so no file was written.
    case noSpeech
}

/// Converts, transcribes, merges, and saves one session. Stateless; safe to create per use.
struct TranscriptionPipeline {
    /// Segments from the same speaker closer than this are joined into one line.
    private let joinGapMs = 1500

    /// Runs the full pipeline. Deletes the session folder only after success.
    /// - Parameter session: a stopped recording.
    /// - Returns: `.saved(url)` or `.noSpeech`.
    /// - Throws: any conversion, Whisper, or file error. The session folder is kept on failure.
    func run(_ session: RecordingSession) throws -> TranscriptionOutcome {
        var segments: [Segment] = []
        for (speaker, audio) in [(Speaker.me, session.micURL), (Speaker.them, session.systemURL)] {
            segments += try transcribe(audio, as: speaker, workDir: session.directory)
        }

        let lines = merge(segments)
        guard !lines.isEmpty else {
            try FileManager.default.removeItem(at: session.directory)
            return .noSpeech
        }

        let duration = try max(audioDuration(session.micURL), audioDuration(session.systemURL))
        let text = render(lines, startedAt: session.startedAt, duration: duration)
        let output = try uniqueTranscriptURL(for: session.startedAt)
        try FileManager.default.createDirectory(at: AppPaths.transcripts, withIntermediateDirectories: true)
        try text.write(to: output, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: session.directory)
        return .saved(output)
    }

    /// Converts one track and runs Whisper on it.
    /// - Returns: speech segments, with non-speech markers like "[BLANK_AUDIO]" removed.
    private func transcribe(_ audio: URL, as speaker: Speaker, workDir: URL) throws -> [Segment] {
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw HarkError.badSession("missing \(audio.lastPathComponent)")
        }
        let wav = workDir.appendingPathComponent("\(speaker.rawValue.lowercased())-16k.wav")
        try runTool(AppPaths.afconvert, ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, wav.path],
                    log: workDir.appendingPathComponent("afconvert-\(speaker.rawValue.lowercased()).log"))

        let outBase = workDir.appendingPathComponent("whisper-\(speaker.rawValue.lowercased())")
        try runTool(AppPaths.whisperCLI, [
            "-m", AppPaths.whisperModel.path,
            "-f", wav.path,
            "-l", AppPaths.whisperLanguage,
            "--vad", "-vm", AppPaths.vadModel.path,
            "-t", "8",
            "-oj", "-of", outBase.path,
            "-np",
        ], log: outBase.appendingPathExtension("log"))

        let jsonURL = outBase.appendingPathExtension("json")
        let output: WhisperOutput
        do {
            output = try JSONDecoder().decode(WhisperOutput.self, from: Data(contentsOf: jsonURL))
        } catch {
            throw HarkError.badWhisperOutput(path: jsonURL.path, underlying: error)
        }
        return output.transcription.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Self.isNonSpeech(text) else { return nil }
            return Segment(speaker: speaker, startMs: item.offsets.from, endMs: item.offsets.to, text: text)
        }
    }

    /// True for empty text and Whisper's non-speech markers: "[BLANK_AUDIO]", "(music)", "♪♪".
    static func isNonSpeech(_ text: String) -> Bool {
        if text.isEmpty { return true }
        let stripped = text.trimmingCharacters(in: CharacterSet(charactersIn: "♪♫ .").union(.whitespaces))
        if stripped.isEmpty { return true }
        let bracketed = (stripped.hasPrefix("[") && stripped.hasSuffix("]"))
            || (stripped.hasPrefix("(") && stripped.hasSuffix(")"))
        return bracketed
    }

    /// Sorts segments by start time and joins back-to-back segments from the same speaker.
    func merge(_ segments: [Segment]) -> [Segment] {
        var lines: [Segment] = []
        for segment in segments.sorted(by: { $0.startMs < $1.startMs }) {
            if let last = lines.last, last.speaker == segment.speaker, segment.startMs - last.endMs < joinGapMs {
                lines[lines.count - 1] = Segment(speaker: last.speaker, startMs: last.startMs,
                                                 endMs: max(last.endMs, segment.endMs),
                                                 text: last.text + " " + segment.text)
            } else {
                lines.append(segment)
            }
        }
        return lines
    }

    /// Formats the transcript: a header, then one "[HH:MM:SS] Speaker: text" line per turn.
    private func render(_ lines: [Segment], startedAt: Date, duration: TimeInterval) -> String {
        let day = DateFormatter()
        day.dateFormat = "EEE MMM d, yyyy"
        let time = DateFormatter()
        time.dateFormat = "h:mm a"
        let endedAt = startedAt.addingTimeInterval(duration)
        let length = duration < 60 ? "\(Int(duration.rounded())) sec" : "\(Int((duration / 60).rounded())) min"
        var out = "Transcript — \(day.string(from: startedAt)), \(time.string(from: startedAt)) to \(time.string(from: endedAt)) (\(length))\n"
        out += "Speakers: Me = my microphone, Them = audio played on my computer\n\n"
        for line in lines {
            let s = line.startMs / 1000
            out += String(format: "[%02d:%02d:%02d] ", s / 3600, (s / 60) % 60, s % 60)
            out += "\(line.speaker.rawValue): \(line.text)\n"
        }
        return out
    }

    /// Length of an audio file in seconds.
    private func audioDuration(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Picks "yyyy-MM-dd_HH-mm.txt", adding "_2", "_3", ... if that name is taken.
    private func uniqueTranscriptURL(for date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let base = formatter.string(from: date)
        var candidate = AppPaths.transcripts.appendingPathComponent("\(base).txt")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = AppPaths.transcripts.appendingPathComponent("\(base)_\(n).txt")
            n += 1
        }
        return candidate
    }

    /// Runs a command-line tool, sending stdout+stderr to `log`.
    /// - Throws: `HarkError.processFailed` with the log's last lines if it exits non-zero.
    private func runTool(_ tool: URL, _ arguments: [String], log: URL) throws {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        // why: writing to a file (not a pipe) avoids a deadlock when output exceeds the pipe buffer.
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let tail = (try? String(contentsOf: log, encoding: .utf8))
                .map { $0.split(separator: "\n").suffix(15).joined(separator: "\n") } ?? "(log unreadable: \(log.path))"
            throw HarkError.processFailed(tool: tool.lastPathComponent, exitCode: process.terminationStatus, log: tail)
        }
    }
}

/// Shape of whisper-cli's `-oj` JSON (only the fields we use).
private struct WhisperOutput: Decodable {
    struct Item: Decodable {
        struct Offsets: Decodable {
            /// Start time in ms from the start of the audio.
            let from: Int
            /// End time in ms.
            let to: Int
        }
        let offsets: Offsets
        let text: String
    }
    let transcription: [Item]
}
