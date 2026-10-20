//
// MicRecorder.swift — records the default microphone to a CAF file.
//
// Uses AVAudioEngine's input node. "Mute" does not stop the engine: it writes
// silence instead, so the mic track stays the same length as the system track
// and the two timelines still line up when they are merged.
//

import AVFoundation

/// Records the default input device. Create one per recording; not reusable after `stop()`.
final class MicRecorder {
    private let engine = AVAudioEngine()
    /// Guards `file`, `muted`, and `writeError`, which the audio thread and main thread share.
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var muted = false
    /// First error hit while writing on the audio thread; reported by `stop()`.
    private var writeError: Error?

    /// Whether the mic is muted. Safe to change at any time, including mid-recording.
    var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    /// Asks macOS for mic permission if it has not been decided yet.
    /// - Parameter completion: called on the main queue with whether access is granted.
    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    /// Starts recording the mic into `url` in the mic's native format.
    /// - Throws: `HarkError.noMicrophone`, file-creation errors, or engine start errors.
    func start(writingTo url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // why: a 0 Hz / 0-channel format means macOS has no usable input device.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw HarkError.noMicrophone }

        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        lock.withLock { self.file = file }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.write(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Writes one buffer (or silence of the same length when muted). Runs on the audio tap thread.
    private func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, writeError == nil else { return }
        do {
            try file.write(from: muted ? Self.silence(like: buffer) : buffer)
        } catch {
            writeError = HarkError.audioWrite(track: "microphone", underlying: error)
        }
    }

    /// Makes a zero-filled buffer with the same format and length as `buffer`.
    /// - Throws: `HarkError.badAudioFormat` if the buffer cannot be allocated.
    private static func silence(like buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let quiet = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            throw HarkError.badAudioFormat("could not allocate a silent mic buffer")
        }
        quiet.frameLength = buffer.frameLength
        // why: new buffers are not guaranteed to be zeroed, so clear every channel's bytes.
        let list = UnsafeMutableAudioBufferListPointer(quiet.mutableAudioBufferList)
        for audioBuffer in list where audioBuffer.mData != nil {
            memset(audioBuffer.mData, 0, Int(audioBuffer.mDataByteSize))
        }
        return quiet
    }

    /// Stops recording and closes the file.
    /// - Throws: the first write error that happened during recording, if any.
    func stop() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let error: Error? = lock.withLock {
            file?.close()
            file = nil
            return self.writeError
        }
        if let error { throw error }
    }
}
