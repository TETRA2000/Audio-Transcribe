#if os(macOS)
import AppKit
import CoreAudio

/// An app that is a Core Audio client, with all of its audio processes (helpers included).
struct AudioApp: Identifiable, Hashable {
    /// The app's bundle identifier.
    let id: String
    let name: String
    let processObjectIDs: [AudioObjectID]
}

/// One entry of `kAudioHardwarePropertyProcessObjectList`.
struct AudioProcess: Equatable {
    let objectID: AudioObjectID
    let bundleID: String
    /// The process's own display name, such as "Safari Graphics and Media".
    let name: String?
    let isRunningOutput: Bool
}

/// Lists the apps whose audio can be captured with a process tap.
enum AudioApps {
    /// Apps that currently have audio processes, excluding this app, sorted by name.
    static func running() -> [AudioApp] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let processes = CoreAudioProperty.array(of: system, kAudioHardwarePropertyProcessObjectList, initial: AudioObjectID(0))
            .compactMap { objectID -> AudioProcess? in
                guard let bundleID = CoreAudioProperty.string(of: objectID, kAudioProcessPropertyBundleID),
                      !bundleID.isEmpty else { return nil }
                let pid = CoreAudioProperty.value(of: objectID, kAudioProcessPropertyPID, initial: pid_t(0))
                let isRunningOutput = CoreAudioProperty.value(of: objectID, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))
                return AudioProcess(
                    objectID: objectID,
                    bundleID: bundleID,
                    name: pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName },
                    isRunningOutput: (isRunningOutput ?? 0) != 0
                )
            }
        return group(processes, ownBundleID: Bundle.main.bundleIdentifier ?? "") { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { $0.activationPolicy == .regular }?
                .localizedName
        }
    }

    /// The current process objects of the app with `bundleID`, helpers included. Empty if it has none.
    static func processObjectIDs(for bundleID: String) -> [AudioObjectID] {
        running().first { $0.id == bundleID }?.processObjectIDs ?? []
    }

    /// Groups processes by the app that owns them. A process belongs to the nearest running app whose bundle ID is
    /// a prefix of its own (`com.google.Chrome.helper.Renderer` → `com.google.Chrome`). A process with no such app is
    /// listed on its own, but only while it is playing audio, so idle background services don't crowd the list.
    /// `appName` returns a regular running app's display name, or `nil` if no such app is running.
    static func group(_ processes: [AudioProcess], ownBundleID: String, appName: (String) -> String?) -> [AudioApp] {
        var apps: [String: AudioApp] = [:]
        for process in processes {
            let owner = owningApp(of: process.bundleID, appName: appName)
            let bundleID = owner?.bundleID ?? process.bundleID
            guard bundleID != ownBundleID else { continue }
            guard owner != nil || process.isRunningOutput else { continue }

            let name = owner?.name ?? process.name ?? process.bundleID
            let existing = apps[bundleID]
            apps[bundleID] = AudioApp(
                id: bundleID,
                name: existing?.name ?? name,
                processObjectIDs: (existing?.processObjectIDs ?? []) + [process.objectID]
            )
        }
        return apps.values.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    private static func owningApp(of bundleID: String, appName: (String) -> String?) -> (bundleID: String, name: String)? {
        var components = bundleID.split(separator: ".")
        while components.count >= 2 {
            let candidate = components.joined(separator: ".")
            if let name = appName(candidate) {
                return (candidate, name)
            }
            components.removeLast()
        }
        return nil
    }
}
#endif
