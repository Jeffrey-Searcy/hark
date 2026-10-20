//
// SystemAudioRecorder.swift — records everything the Mac plays (all apps) to a CAF file.
//
// How it works (Core Audio "process tap", macOS 14.2+):
//   1. Create a global tap: a copy of the mixed audio of every process. The audio
//      still plays normally (muteBehavior = .unmuted).
//   2. Wrap the tap in a private aggregate device clocked by the current output
//      device, because taps can only be read through a device.
//   3. Run an IO callback on that device and append each buffer to the file.
// macOS asks once for "System Audio Recording" permission. If it is denied the
// tap delivers silence rather than an error, so the transcript simply has no "Them".
//
// Known limit: the aggregate device follows the output device chosen at start.
// Switching outputs mid-recording (e.g. AirPods disconnecting) can stop capture.
//

import AVFoundation
import CoreAudio

/// Records system audio output. Create one per recording; not reusable after `stop()`.
final class SystemAudioRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "hark.system-audio", qos: .userInitiated)
    /// Guards `file` and `writeError`, which the IO queue and main thread share.
    private let lock = NSLock()
    private var file: AVAudioFile?
    /// First error hit while writing in the IO callback; reported by `stop()`.
    private var writeError: Error?

    /// Builds the tap + aggregate device and starts writing audio into `url`.
    /// On failure, everything created so far is torn down before the error is thrown.
    /// - Throws: `HarkError.coreAudio` naming the step that failed, or file errors.
    func start(writingTo url: URL) throws {
        do {
            try startUnchecked(writingTo: url)
        } catch {
            _ = teardown()
            throw error
        }
    }

    private func startUnchecked(writingTo url: URL) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Hark system audio"
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create the system audio tap")

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hark Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "create the capture device")

        var streamDescription = try tapStreamDescription()
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw HarkError.badAudioFormat("system tap reported \(streamDescription)")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        lock.withLock { self.file = file }

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.write(input, format: format)
        }, "attach to the capture device")
        try check(AudioDeviceStart(aggregateID, ioProcID), "start capturing system audio")
    }

    /// Appends one IO buffer to the file. Runs on `queue`.
    private func write(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, writeError == nil else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else {
            writeError = HarkError.badAudioFormat("system audio buffer did not match \(format)")
            return
        }
        do {
            try file.write(from: buffer)
        } catch {
            writeError = HarkError.audioWrite(track: "computer", underlying: error)
        }
    }

    /// Stops capture, removes the tap and aggregate device, and closes the file.
    /// - Throws: the first write error during recording, else the first teardown error.
    func stop() throws {
        let teardownError = teardown()
        let recordedError: Error? = lock.withLock { self.writeError }
        if let error = recordedError ?? teardownError { throw error }
    }

    /// Undoes everything `start` created, in reverse order. Every step runs even if an
    /// earlier one fails, so no stray devices are left behind.
    /// - Returns: the first error hit, or nil.
    private func teardown() -> Error? {
        var firstError: Error?
        func attempt(_ status: OSStatus, _ step: String) {
            if status != noErr, firstError == nil {
                firstError = HarkError.coreAudio(step: step, status: status)
            }
        }
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            attempt(AudioDeviceStop(aggregateID, ioProcID), "stop capturing system audio")
            attempt(AudioDeviceDestroyIOProcID(aggregateID, ioProcID), "detach from the capture device")
        }
        ioProcID = nil
        // why: wait for any IO callback already queued so the file is not closed mid-write.
        queue.sync {}
        lock.withLock {
            file?.close()
            file = nil
        }
        if aggregateID != kAudioObjectUnknown {
            attempt(AudioHardwareDestroyAggregateDevice(aggregateID), "remove the capture device")
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            attempt(AudioHardwareDestroyProcessTap(tapID), "remove the system audio tap")
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        return firstError
    }

    /// Reads the tap's audio format (sample rate, channels, float layout).
    private func tapStreamDescription() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description),
                  "read the system audio format")
        return description
    }

    /// Finds the unique ID of the device sound is currently playing through.
    private static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                0, nil, &size, &deviceID)
        guard status == noErr else { throw HarkError.coreAudio(step: "find the output device", status: status) }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard uidStatus == noErr, let uid else {
            throw HarkError.coreAudio(step: "read the output device ID", status: uidStatus)
        }
        return uid.takeRetainedValue() as String
    }

    /// Throws a `coreAudio` error naming `step` when `status` is not `noErr`.
    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw HarkError.coreAudio(step: step, status: status) }
    }
}
