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

    /// The device to pin the microphone to: the one with `uid` if it's connected. `nil` means don't pin a device,
    /// so the engine follows the system default input (and keeps following it if the default changes).
    /// Pinning the default device explicitly instead breaks capture from Bluetooth headsets such as AirPods.
    static func resolve(uid: String?, in devices: [AudioInputDevice]) -> AudioDeviceID? {
        guard let uid else { return nil }
        return devices.first(where: { $0.uid == uid })?.id
    }
}
#endif
