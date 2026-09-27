#if os(macOS)
import AVFoundation
import CoreAudio

nonisolated enum SystemAudioCaptureError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case formatUnavailable(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case startFailed(OSStatus)
    case appNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            "Couldn't create a system audio tap (status \(status))."
        case .aggregateDeviceCreationFailed(let status):
            "Couldn't create the aggregate audio device for capture (status \(status))."
        case .formatUnavailable(let status):
            "Couldn't determine the system audio format (status \(status))."
        case .ioProcCreationFailed(let status):
            "Couldn't register an audio callback (status \(status))."
        case .startFailed(let status):
            "Couldn't start system audio capture (status \(status))."
        case .appNotRunning(let name):
            "\(name) isn't running."
        }
    }
}

/// Captures system audio output (everything the Mac is playing, or one app's audio) using a
/// Core Audio process tap, and exposes it as a stream of PCM buffers.
@MainActor
final class SystemAudioSource {
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    func start(target: SystemAudioTarget = .allAudio) throws -> AsyncStream<AVAudioPCMBuffer> {
        var processObjectIDs: [AudioObjectID] = []
        if case .app(let bundleID, let name) = target {
            // Resolve at start so helper processes launched since the menu was shown are included.
            processObjectIDs = AudioApps.processObjectIDs(for: bundleID)
            guard !processObjectIDs.isEmpty else { throw SystemAudioCaptureError.appNotRunning(name) }
        }
        let tapDescription = Self.tapDescription(for: target, processObjectIDs: processObjectIDs)

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr else { throw SystemAudioCaptureError.tapCreationFailed(status) }
        tapID = newTapID

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audio Transcribe Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateDeviceID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw SystemAudioCaptureError.aggregateDeviceCreationFailed(status)
        }
        aggregateDeviceID = newAggregateDeviceID

        var asbd = AudioStreamBasicDescription()
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &propertyAddress, 0, nil, &dataSize, &asbd)
        guard status == noErr, let audioFormat = AVAudioFormat(streamDescription: &asbd) else {
            tearDown()
            throw SystemAudioCaptureError.formatUnavailable(status)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.continuation = continuation

        var newIOProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, nil) { @Sendable _, inputData, _, _, _ in
            // `inputData` is only valid for the duration of this callback, so copy it before handing it off.
            guard let pcmBuffer = Self.copyBuffer(inputData, format: audioFormat) else { return }
            continuation.yield(pcmBuffer)
        }
        guard status == noErr, let ioProcID = newIOProcID else {
            tearDown()
            throw SystemAudioCaptureError.ioProcCreationFailed(status)
        }
        self.ioProcID = ioProcID

        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            tearDown()
            throw SystemAudioCaptureError.startFailed(status)
        }

        return stream
    }

    func stop() {
        tearDown()
    }

    /// A private stereo tap of all system audio, or a mixdown of just `processObjectIDs` for an app target.
    static func tapDescription(for target: SystemAudioTarget, processObjectIDs: [AudioObjectID]) -> CATapDescription {
        let description = switch target {
        case .allAudio: CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .app: CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        }
        description.isPrivate = true
        return description
    }

    nonisolated static func copyBuffer(_ bufferList: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList),
              source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let copyBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (sourceBuffer, copyBuffer) in zip(sourceBuffers, copyBuffers) {
            guard let sourceData = sourceBuffer.mData, let copyData = copyBuffer.mData else { continue }
            memcpy(copyData, sourceData, Int(min(sourceBuffer.mDataByteSize, copyBuffer.mDataByteSize)))
        }
        return copy
    }

    private func tearDown() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        continuation?.finish()
        continuation = nil
    }
}
#endif
