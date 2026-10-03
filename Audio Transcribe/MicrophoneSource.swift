import AVFoundation
#if os(macOS)
import CoreAudio
#endif

nonisolated enum MicrophoneError: LocalizedError {
    case deviceSelectionFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .deviceSelectionFailed(let status):
            "Couldn't use the selected microphone (status \(status))."
        }
    }
}

/// Captures microphone audio and exposes it as a stream of PCM buffers.
@MainActor
final class MicrophoneSource {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var isRunning = false
    #if os(macOS)
    private var deviceID: AudioDeviceID?
    private var configurationObserver: NSObjectProtocol?
    #endif

    /// Starts capturing. On macOS, `deviceID` is the Core Audio input device to record from (`nil` uses the system
    /// default). Other platforms use the current audio route and ignore it.
    ///
    /// On macOS the stream finishes by itself if the device is disconnected while recording.
    func start(deviceID: UInt32? = nil) throws -> AsyncStream<AVAudioPCMBuffer> {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.continuation = continuation
        #if os(macOS)
        self.deviceID = deviceID
        #endif

        do {
            try startEngine()
        } catch {
            continuation.finish()
            self.continuation = nil
            throw error
        }
        isRunning = true

        #if os(macOS)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }
        #endif
        return stream
    }

    func stop() {
        guard isRunning else { return }
        #if os(macOS)
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        #endif
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        isRunning = false
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Points the input node at the chosen device (macOS), installs the tap, and starts the engine.
    private func startEngine() throws {
        guard let continuation else { return }
        let inputNode = engine.inputNode
        #if os(macOS)
        if let deviceID {
            try Self.setInputDevice(deviceID, on: inputNode)
        }
        #endif
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            continuation.yield(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    #if os(macOS)
    /// The engine stops itself whenever the audio hardware changes, including output-only changes such as plugging
    /// in headphones. Keep recording if the microphone is still connected. Otherwise stop, which ends the stream
    /// so the channel can report the disconnect.
    private func handleConfigurationChange() {
        guard isRunning else { return }
        let deviceStillConnected = deviceID.map { id in AudioInputDevices.all().contains { $0.id == id } } ?? true
        if deviceStillConnected {
            engine.stop()
            if (try? startEngine()) != nil { return }
        }
        stop()
    }

    private static func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw MicrophoneError.deviceSelectionFailed(kAudioUnitErr_Uninitialized)
        }
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw MicrophoneError.deviceSelectionFailed(status) }
    }
    #endif
}
