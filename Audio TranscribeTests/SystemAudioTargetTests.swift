import Testing
@testable import Audio_Transcribe
#if os(macOS)
import CoreAudio
#endif

struct SystemAudioTargetTests {
    @Test func labels() {
        #expect(SystemAudioTarget.allAudio.label == "System audio")
        #expect(SystemAudioTarget.app(bundleID: "us.zoom.xos", name: "zoom.us").label == "zoom.us")
    }

    #if os(macOS)
    @Test func allAudioUsesAGlobalTap() {
        let description = SystemAudioSource.tapDescription(for: .allAudio, processObjectIDs: [])
        #expect(description.isExclusive)
        #expect(description.processes.isEmpty)
        #expect(description.isPrivate)
    }

    @Test func appTargetTapsOnlyThatAppsProcesses() {
        let description = SystemAudioSource.tapDescription(
            for: .app(bundleID: "us.zoom.xos", name: "zoom.us"),
            processObjectIDs: [41, 42]
        )
        #expect(!description.isExclusive)
        #expect(description.processes == [41, 42])
        #expect(description.isPrivate)
    }

    @Test func startingAnAppThatIsNotRunningFails() {
        let source = SystemAudioSource()
        let error = #expect(throws: SystemAudioCaptureError.self) {
            _ = try source.start(target: .app(bundleID: "com.example.not-running", name: "Nope"))
        }
        #expect(error?.errorDescription == "Nope isn't running.")
    }
    #endif
}
