#if os(macOS)
import CoreAudio
import Testing
@testable import Audio_Transcribe

struct AudioInputDevicesTests {
    private let builtIn = AudioInputDevice(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let usb = AudioInputDevice(id: 20, uid: "AppleUSBAudioEngine:Blue:Yeti", name: "Yeti")

    @Test func resolvesTheSelectedDevice() {
        #expect(AudioInputDevices.resolve(uid: usb.uid, in: [builtIn, usb], defaultID: builtIn.id) == usb.id)
    }

    @Test func fallsBackToTheDefaultWhenTheSelectedDeviceIsGone() {
        #expect(AudioInputDevices.resolve(uid: usb.uid, in: [builtIn], defaultID: builtIn.id) == builtIn.id)
    }

    @Test func usesTheDefaultWhenNothingIsSelected() {
        #expect(AudioInputDevices.resolve(uid: nil, in: [builtIn, usb], defaultID: builtIn.id) == builtIn.id)
        #expect(AudioInputDevices.resolve(uid: nil, in: [], defaultID: nil) == nil)
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
