#if os(macOS)
import AppKit
import CoreAudio
import Observation

/// Calls `handler` on the main queue whenever one of the Core Audio system object's `selectors` changes,
/// until this object is deallocated.
final class CoreAudioListener {
    private let addresses: [AudioObjectPropertyAddress]
    private let block: AudioObjectPropertyListenerBlock

    init(selectors: [AudioObjectPropertySelector], handler: @escaping @MainActor () -> Void) {
        addresses = selectors.map { CoreAudioProperty.address($0) }
        block = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        for var address in addresses {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    deinit {
        for var address in addresses {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }
}

/// The input devices and audio apps available right now, for the source menus. It stays current through Core
/// Audio notifications and refreshes when the app becomes active (so apps that just started playing appear).
@Observable
final class AudioSourceCatalog {
    private(set) var inputDevices: [AudioInputDevice] = []
    private(set) var defaultInputName: String?
    private(set) var apps: [AudioApp] = []

    @ObservationIgnored private var listener: CoreAudioListener?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    func startObserving() {
        refresh()
        guard listener == nil else { return }
        listener = CoreAudioListener(selectors: [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyProcessObjectList,
        ]) { [weak self] in
            self?.refresh()
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        inputDevices = AudioInputDevices.all()
        let defaultID = AudioInputDevices.defaultDeviceID()
        defaultInputName = inputDevices.first { $0.id == defaultID }?.name
        apps = AudioApps.running()
    }
}
#endif
