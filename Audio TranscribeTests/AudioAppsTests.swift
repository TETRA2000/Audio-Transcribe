#if os(macOS)
import CoreAudio
import Foundation
import Testing
@testable import Audio_Transcribe

struct AudioAppsTests {
    private let ownBundleID = "com.example.AudioTranscribe"
    private let runningApps = [
        "com.google.Chrome": "Google Chrome",
        "us.zoom.xos": "zoom.us",
        "com.example.AudioTranscribe": "Audio Transcribe",
    ]

    private func process(_ id: AudioObjectID, _ bundleID: String, name: String? = nil, playing: Bool = false) -> AudioProcess {
        AudioProcess(objectID: id, bundleID: bundleID, name: name, isRunningOutput: playing)
    }

    private func group(_ processes: [AudioProcess]) -> [AudioApp] {
        AudioApps.group(processes, ownBundleID: ownBundleID, appName: { runningApps[$0] })
    }

    @Test func helpersAreGroupedUnderTheirApp() {
        let apps = group([
            process(1, "com.google.Chrome"),
            process(2, "com.google.Chrome.helper"),
            process(3, "com.google.Chrome.helper.Renderer"),
        ])
        #expect(apps == [AudioApp(id: "com.google.Chrome", name: "Google Chrome", processObjectIDs: [1, 2, 3])])
    }

    @Test func thisAppIsExcluded() {
        let apps = group([process(1, ownBundleID, playing: true), process(2, "us.zoom.xos")])
        #expect(apps.map(\.id) == ["us.zoom.xos"])
    }

    @Test func processesWithoutAnAppAreListedOnlyWhilePlaying() {
        let idle = group([process(1, "com.apple.WebKit.GPU", name: "Safari Graphics and Media")])
        #expect(idle.isEmpty)

        let playing = group([process(1, "com.apple.WebKit.GPU", name: "Safari Graphics and Media", playing: true)])
        #expect(playing == [AudioApp(id: "com.apple.WebKit.GPU", name: "Safari Graphics and Media", processObjectIDs: [1])])
    }

    @Test func processesWithoutAnAppOrANameUseTheirBundleID() {
        let apps = group([process(1, "com.example.daemon", playing: true)])
        #expect(apps.map(\.name) == ["com.example.daemon"])
    }

    @Test func appsAreSortedByName() {
        let apps = group([process(1, "us.zoom.xos"), process(2, "com.google.Chrome")])
        #expect(apps.map(\.name) == ["Google Chrome", "zoom.us"])
    }

    @Test func runningAppsNeverIncludeThisApp() {
        let ownID = Bundle.main.bundleIdentifier ?? ""
        #expect(!AudioApps.running().contains { $0.id == ownID })
    }
}
#endif
