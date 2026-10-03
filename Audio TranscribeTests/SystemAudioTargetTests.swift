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

    @Test func processListIsUnchangedWhenTheSameProcessesResolve() {
        #expect(SystemAudioSource.updatedProcessList(current: [41, 42], resolved: [41, 42]) == nil)
        #expect(SystemAudioSource.updatedProcessList(current: [41, 42], resolved: [42, 41]) == nil)
    }

    @Test func processListIsKeptWhenNoProcessesResolve() {
        #expect(SystemAudioSource.updatedProcessList(current: [41, 42], resolved: []) == nil)
    }

    @Test func processListIncludesHelpersThatStartedLater() {
        #expect(SystemAudioSource.updatedProcessList(current: [41], resolved: [41, 57]) == [41, 57])
    }

    @Test func processListDropsProcessesThatExited() {
        #expect(SystemAudioSource.updatedProcessList(current: [41, 57], resolved: [41]) == [41])
    }

    @Test func updatedTapDescriptionKeepsTheTapsUUID() {
        let target = SystemAudioTarget.app(bundleID: "com.google.Chrome", name: "Google Chrome")
        let original = SystemAudioSource.tapDescription(for: target, processObjectIDs: [41])
        let updated = SystemAudioSource.tapDescription(for: target, processObjectIDs: [41, 57], uuid: original.uuid)
        #expect(updated.uuid == original.uuid)
        #expect(updated.processes == [41, 57])
        #expect(updated.isPrivate)
        #expect(!updated.isExclusive)
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
