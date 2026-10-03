#if os(macOS)
import CoreAudio
import Testing
@testable import Audio_Transcribe

struct AudioInputDevicesTests {
    private let builtIn = AudioInputDevice(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let usb = AudioInputDevice(id: 20, uid: "AppleUSBAudioEngine:Blue:Yeti", name: "Yeti")

    @Test func resolvesTheSelectedDevice() {
        #expect(AudioInputDevices.resolve(uid: usb.uid, in: [builtIn, usb]) == usb.id)
    }

    /// `nil` means "don't pin a device": the engine then follows the system default input, which is what
    /// "System Default" promises. Explicitly pinning the default device broke capture from AirPods.
    @Test func followsTheSystemDefaultWhenTheSelectedDeviceIsGone() {
        #expect(AudioInputDevices.resolve(uid: usb.uid, in: [builtIn]) == nil)
    }

    @Test func followsTheSystemDefaultWhenNothingIsSelected() {
        #expect(AudioInputDevices.resolve(uid: nil, in: [builtIn, usb]) == nil)
    }

    @Test func listedDevicesHaveUniqueUIDsAndNames() {
        let devices = AudioInputDevices.all()
        #expect(Set(devices.map(\.uid)).count == devices.count)
        #expect(devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
    }

    @Test func theDefaultInputIsAListedDevice() {
        guard let defaultID = AudioInputDevices.defaultDeviceID() else { return }
        #expect(AudioInputDevices.all().contains { $0.id == defaultID })
    }
}
#endif
