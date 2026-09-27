#if os(macOS)
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    /// Stable across reboots and reconnects; used to remember the user's choice.
    let uid: String
    let name: String
}

/// Lists the Mac's audio input devices.
enum AudioInputDevices {
    /// Every device that has at least one input stream.
    static func all() -> [AudioInputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return CoreAudioProperty.array(of: system, kAudioHardwarePropertyDevices, initial: AudioDeviceID(0))
            .compactMap { id in
                let inputStreams = CoreAudioProperty.array(
                    of: id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, initial: AudioStreamID(0)
                )
                guard !inputStreams.isEmpty,
                      let uid = CoreAudioProperty.string(of: id, kAudioDevicePropertyDeviceUID),
                      let name = CoreAudioProperty.string(of: id, kAudioObjectPropertyName) else { return nil }
                return AudioInputDevice(id: id, uid: uid, name: name)
            }
    }

    /// The system default input device, if there is one.
    static func defaultDeviceID() -> AudioDeviceID? {
        let id = CoreAudioProperty.value(
            of: AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultInputDevice,
            initial: AudioDeviceID(kAudioObjectUnknown)
        )
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// The device to record from: the one with `uid` if it's connected, otherwise the system default.
    static func resolve(uid: String?, in devices: [AudioInputDevice], defaultID: AudioDeviceID?) -> AudioDeviceID? {
        if let uid, let device = devices.first(where: { $0.uid == uid }) {
            return device.id
        }
        return defaultID
    }
}
#endif
