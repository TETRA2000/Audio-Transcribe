# Multi-source Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick the microphone input device and the system-audio target (all audio or one app), transcribe the mic and system audio at the same time with speaker labels, and export combined or per-source `.txt` files.

**Architecture:**
- Each live source becomes a `LiveChannel`: a capture source plus its own `TranscriptionEngine` (`SpeechAnalyzer`), with segments stored on a shared session timeline.
- `TranscriptionViewModel` owns the channels, merges their segments by time, and hands pure formatting to `TranscriptExporter`.
- Core Audio device and process enumeration lives in small macOS-only helpers (`AudioInputDevices`, `AudioApps`), kept current in the UI by `AudioSourceCatalog`.

**Tech Stack:** Swift 5 language mode, SwiftUI, Observation, AVFoundation (`AVAudioEngine`), Core Audio (process taps, aggregate devices, `AudioObjectGetPropertyData`), Speech (`SpeechAnalyzer`/`SpeechTranscriber`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-multi-source-capture-design.md`

## Global Constraints

- **Deployment targets:** macOS / iOS / visionOS 27.0.
- **Language mode:** Swift 5, with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in both the app and test targets. Every type is main-actor isolated unless marked `nonisolated` or declared as an `actor`.
- **Project file:** new `.swift` files placed in `Audio Transcribe/` or `Audio TranscribeTests/` join their targets automatically (file-system synchronized groups). Do not add file references to `project.pbxproj`. The only `project.pbxproj` edit in this plan is `ENABLE_USER_SELECTED_FILES` (Task 9).
- **Platforms:** anything touching Core Audio devices, processes, or taps is wrapped in `#if os(macOS)`. The iOS build must keep succeeding: `xcodebuild build -scheme "Audio Transcribe" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`.
- **Speaker labels:** the microphone is `"You"`. System audio is `"System audio"` for all audio, or the app's name for one app.
- **Export line format:** `[MM:SS] Label: text` (combined, multi-source) or `[MM:SS] text`. Text is trimmed of surrounding whitespace.
- **Export default base name:** `Transcript yyyy-MM-dd HH.mm`.
- **Export file names:** separate files are `<base>-<label>.txt`, with `/` and `:` in labels replaced by `-`.
- **Tests:** Swift Testing (`import Testing`, `@Test`, `#expect`) only. No XCTest.
- **Dependencies:** no third-party dependencies.
- **Commits:** commit messages follow the repo style (a plain imperative sentence) and end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_015fuauoR6c8DfMT23Xcmsce
  ```

**Test command (one suite):** `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/<SuiteName>" 2>&1 | tail -20`

**Test command (all):** `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' 2>&1 | tail -30`

A compile error in a test file fails the whole test build. "Expected: FAIL" below means either the build error named or a failing `#expect`.

## Review Focus

1. **Output-device changes mid-call.** Plugging in headphones or switching output while recording must not end the mic channel; only removal of the selected microphone should. Owner: Task 3, manual step 3.7.
2. **Existing files in the export folder.** Exporting "Separate" into a folder that already has `Transcript …-You.txt` must not overwrite it, and two sources with the same label must not overwrite each other. Owner: Task 2, tests `writeDoesNotOverwriteExistingFiles` and `writeKeepsFilesWithTheSameNameApart`.
3. **Clear while recording.** Clearing the transcript during a recording must not orphan running channels, which would leave the mic and tap live with no way to stop them. Owner: Task 7, test `clearDoesNothingWhileRecording`, plus Task 8 hiding Clear while recording.
4. **Start fails halfway.** If one source fails at Start (selected app no longer running, tap permission denied), nothing may be left recording and the error must name the cause. Owner: Task 5, test `startingAnAppThatIsNotRunningFails`; Task 6, test `startAllStopsStartedChannelsWhenOneFails`.
5. **Words spoken just before Stop.** They must end up in the transcript and export, so Stop waits for the transcriber's final results. Owner: Task 6, test `stopWaitsForPendingResults`.

---

### Task 1: Speaker labels on segments and timeline merging

**Files:**
- Modify: `Audio Transcribe/TranscriptSegment.swift`
- Test: `Audio TranscribeTests/TranscriptModelTests.swift`

**Interfaces:**
- Produces:
  - `TranscriptSegment.speaker: String?`, default `nil`. The memberwise init becomes `TranscriptSegment(start:end:text:speaker:)`, and `speaker` can be omitted.
  - `static func TranscriptSegment.merged(_ channels: [[TranscriptSegment]]) -> [TranscriptSegment]`

- [ ] **Step 1: Write the failing tests.** Append to `Audio TranscribeTests/TranscriptModelTests.swift`:

```swift
struct TranscriptMergeTests {
    @Test func segmentsHaveNoSpeakerByDefault() {
        #expect(TranscriptSegment(start: 0, end: 1, text: "Hi").speaker == nil)
    }

    @Test func mergeInterleavesChannelsByStartTime() {
        let mic = [
            TranscriptSegment(start: 0, end: 2, text: "a", speaker: "You"),
            TranscriptSegment(start: 10, end: 12, text: "c", speaker: "You"),
        ]
        let app = [TranscriptSegment(start: 5, end: 6, text: "b", speaker: "Zoom")]

        let merged = TranscriptSegment.merged([mic, app])

        #expect(merged.map(\.text) == ["a", "b", "c"])
        #expect(merged.map(\.speaker) == ["You", "Zoom", "You"])
    }

    @Test func mergeKeepsChannelOrderForTies() {
        let mic = [TranscriptSegment(start: 3, end: 4, text: "mic")]
        let app = [
            TranscriptSegment(start: 3, end: 4, text: "app 1"),
            TranscriptSegment(start: 3, end: 4, text: "app 2"),
        ]
        #expect(TranscriptSegment.merged([mic, app]).map(\.text) == ["mic", "app 1", "app 2"])
    }

    @Test func mergeOfNothingIsEmpty() {
        #expect(TranscriptSegment.merged([]).isEmpty)
        #expect(TranscriptSegment.merged([[], []]).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/TranscriptMergeTests" 2>&1 | tail -20`
Expected: FAIL. The build error is "extra argument 'speaker' in call" / "type 'TranscriptSegment' has no member 'merged'".

- [ ] **Step 3: Implement.** Replace `Audio Transcribe/TranscriptSegment.swift` with:

```swift
import Foundation

struct TranscriptSegment: Identifiable, Sendable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Who spoke: "You", an app name, or "System audio". `nil` for file transcripts and single-source sessions.
    var speaker: String? = nil

    /// The segment's start time as `MM:SS`, with minutes continuing past 59 (e.g. `62:05`).
    var formattedStart: String {
        guard start.isFinite, start >= 0 else { return "--:--" }
        let totalSeconds = Int(start)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    /// Merges several channels' segments into one timeline ordered by start time. Segments that start at the same
    /// time keep the order of `channels` (the microphone is listed first), then their order within the channel.
    static func merged(_ channels: [[TranscriptSegment]]) -> [TranscriptSegment] {
        channels.enumerated()
            .flatMap { channelIndex, segments in
                segments.enumerated().map { index, segment in (segment: segment, channel: channelIndex, index: index) }
            }
            .sorted { lhs, rhs in
                if lhs.segment.start != rhs.segment.start { return lhs.segment.start < rhs.segment.start }
                if lhs.channel != rhs.channel { return lhs.channel < rhs.channel }
                return lhs.index < rhs.index
            }
            .map(\.segment)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/TranscriptMergeTests" -only-testing:"Audio TranscribeTests/TranscriptSegmentTests" 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit.**

```bash
git add "Audio Transcribe/TranscriptSegment.swift" "Audio TranscribeTests/TranscriptModelTests.swift"
git commit -m "Add speaker labels to transcript segments and timeline merging

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015fuauoR6c8DfMT23Xcmsce"
```

---

### Task 2: TranscriptExporter (formatting, file names, writing)

**Files:**
- Create: `Audio Transcribe/TranscriptExporter.swift`
- Test: `Audio TranscribeTests/TranscriptExporterTests.swift`

**Interfaces:**
- Consumes: `TranscriptSegment(start:end:text:speaker:)`, `TranscriptSegment.formattedStart`, and `TranscriptSegment.merged(_:)` (Task 1).
- Produces:
  - `enum ExportKind: Hashable, CaseIterable { case combined, separate, combinedAndSeparate }`
  - `struct ExportFile: Equatable { let name: String; let text: String }`
  - `TranscriptExporter.combined(_ segments: [TranscriptSegment]) -> String`
  - `TranscriptExporter.separate(_ channels: [(label: String, segments: [TranscriptSegment])]) -> [(label: String, text: String)]`
  - `TranscriptExporter.files(_ kind: ExportKind, baseName: String, combined: [TranscriptSegment], channels: [(label: String, segments: [TranscriptSegment])]) -> [ExportFile]`
  - `TranscriptExporter.fileName(base: String, label: String?) -> String`
  - `TranscriptExporter.defaultBaseName(for date: Date) -> String`
  - `TranscriptExporter.write(_ files: [ExportFile], to folder: URL) throws -> [URL]`

- [ ] **Step 1: Write the failing tests.** Create `Audio TranscribeTests/TranscriptExporterTests.swift`:

```swift
import Foundation
import Testing
@testable import Audio_Transcribe

struct TranscriptExporterTests {
    private let mic = [TranscriptSegment(start: 0, end: 1, text: " Hello.", speaker: "You")]
    private let app = [TranscriptSegment(start: 2, end: 3, text: " Hi.", speaker: "Zoom")]

    @Test func combinedPrefixesTimestampsAndSpeakers() {
        let segments = [
            TranscriptSegment(start: 12, end: 14, text: " Hi, can you hear me?", speaker: "You"),
            TranscriptSegment(start: 15, end: 17, text: " Yes, loud and clear.", speaker: "Zoom"),
        ]
        #expect(TranscriptExporter.combined(segments) == """
            [00:12] You: Hi, can you hear me?
            [00:15] Zoom: Yes, loud and clear.
            """)
    }

    @Test func combinedOmitsTheLabelWhenSegmentsHaveNoSpeaker() {
        let segments = [
            TranscriptSegment(start: 65, end: 66, text: "こんにちは。"),
            TranscriptSegment(start: 66, end: 67, text: "これはテストです。"),
        ]
        #expect(TranscriptExporter.combined(segments) == "[01:05] こんにちは。\n[01:06] これはテストです。")
    }

    @Test func combinedOfNoSegmentsIsEmpty() {
        #expect(TranscriptExporter.combined([]) == "")
    }

    @Test func separateDropsSpeakerLabels() {
        let texts = TranscriptExporter.separate([(label: "You", segments: mic), (label: "Zoom", segments: app)])
        #expect(texts.map(\.label) == ["You", "Zoom"])
        #expect(texts.map(\.text) == ["[00:00] Hello.", "[00:02] Hi."])
    }

    @Test(arguments: [
        (ExportKind.combined, ["T.txt"]),
        (.separate, ["T-You.txt", "T-Zoom.txt"]),
        (.combinedAndSeparate, ["T.txt", "T-You.txt", "T-Zoom.txt"]),
    ])
    func filesForEachKind(kind: ExportKind, names: [String]) {
        let files = TranscriptExporter.files(
            kind,
            baseName: "T",
            combined: TranscriptSegment.merged([mic, app]),
            channels: [(label: "You", segments: mic), (label: "Zoom", segments: app)]
        )
        #expect(files.map(\.name) == names)
    }

    @Test func combinedFileHoldsTheLabeledTimeline() throws {
        let files = TranscriptExporter.files(
            .combined,
            baseName: "T",
            combined: TranscriptSegment.merged([mic, app]),
            channels: [(label: "You", segments: mic), (label: "Zoom", segments: app)]
        )
        let file = try #require(files.first)
        #expect(file.text == "[00:00] You: Hello.\n[00:02] Zoom: Hi.")
    }

    @Test(arguments: [
        (nil as String?, "Transcript.txt"),
        ("You", "Transcript-You.txt"),
        ("zoom.us", "Transcript-zoom.us.txt"),
        ("A/B: Call", "Transcript-A-B- Call.txt"),
    ])
    func fileName(label: String?, expected: String) {
        #expect(TranscriptExporter.fileName(base: "Transcript", label: label) == expected)
    }

    @Test func defaultBaseNameUsesLocalDateAndTime() throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 14, minute: 5)))
        #expect(TranscriptExporter.defaultBaseName(for: date) == "Transcript 2026-09-27 14.05")
    }

    @Test func writeCreatesUTF8Files() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let urls = try TranscriptExporter.write([ExportFile(name: "T.txt", text: "こんにちは")], to: folder)

        #expect(urls.map(\.lastPathComponent) == ["T.txt"])
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "こんにちは")
    }

    @Test func writeDoesNotOverwriteExistingFiles() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "old".write(to: folder.appending(path: "T.txt"), atomically: true, encoding: .utf8)

        let urls = try TranscriptExporter.write([ExportFile(name: "T.txt", text: "new")], to: folder)

        #expect(urls.map(\.lastPathComponent) == ["T 2.txt"])
        #expect(try String(contentsOf: folder.appending(path: "T.txt"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "new")
    }

    @Test func writeKeepsFilesWithTheSameNameApart() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let urls = try TranscriptExporter.write(
            [ExportFile(name: "T-You.txt", text: "mic"), ExportFile(name: "T-You.txt", text: "app")],
            to: folder
        )

        #expect(urls.map(\.lastPathComponent) == ["T-You.txt", "T-You 2.txt"])
        #expect(try String(contentsOf: urls[1], encoding: .utf8) == "app")
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/TranscriptExporterTests" 2>&1 | tail -20`
Expected: FAIL with "cannot find 'TranscriptExporter' in scope".

- [ ] **Step 3: Implement.** Create `Audio Transcribe/TranscriptExporter.swift`:

```swift
import Foundation

/// Which files an export produces for a multi-source transcript.
enum ExportKind: Hashable, CaseIterable {
    /// One file with every source on one timeline, each line labeled with its speaker.
    case combined
    /// One file per source.
    case separate
    case combinedAndSeparate
}

/// A text file to export: its file name and contents.
struct ExportFile: Equatable {
    let name: String
    let text: String
}

/// Formats transcripts as plain text and writes export files.
enum TranscriptExporter {
    /// One line per segment: `[MM:SS] Speaker: text`, or `[MM:SS] text` when the segment has no speaker.
    static func combined(_ segments: [TranscriptSegment]) -> String {
        segments.map { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let speaker = segment.speaker {
                return "[\(segment.formattedStart)] \(speaker): \(text)"
            }
            return "[\(segment.formattedStart)] \(text)"
        }
        .joined(separator: "\n")
    }

    /// One text per channel, in the same line format as `combined(_:)` but without speaker labels.
    static func separate(_ channels: [(label: String, segments: [TranscriptSegment])]) -> [(label: String, text: String)] {
        channels.map { channel in
            let unlabeled = channel.segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text) }
            return (label: channel.label, text: combined(unlabeled))
        }
    }

    /// The files for `kind`: the combined timeline first, then one file per channel.
    static func files(
        _ kind: ExportKind,
        baseName: String,
        combined segments: [TranscriptSegment],
        channels: [(label: String, segments: [TranscriptSegment])]
    ) -> [ExportFile] {
        var files: [ExportFile] = []
        if kind != .separate {
            files.append(ExportFile(name: fileName(base: baseName, label: nil), text: combined(segments)))
        }
        if kind != .combined {
            files += separate(channels).map { ExportFile(name: fileName(base: baseName, label: $0.label), text: $0.text) }
        }
        return files
    }

    /// `<base>.txt`, or `<base>-<label>.txt` with `/` and `:` in the label replaced so it stays one file name.
    static func fileName(base: String, label: String?) -> String {
        guard let label else { return "\(base).txt" }
        let safeLabel = label
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(base)-\(safeLabel).txt"
    }

    /// `Transcript yyyy-MM-dd HH.mm` in the local time zone.
    static func defaultBaseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Transcript \(formatter.string(from: date))"
    }

    /// Writes each file into `folder` as UTF-8. Instead of overwriting an existing file, a number is added before
    /// the extension (`T 2.txt`, `T 3.txt`, …). Returns the URLs written, in order.
    static func write(_ files: [ExportFile], to folder: URL) throws -> [URL] {
        try files.map { file in
            let url = availableURL(for: file.name, in: folder)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    private static func availableURL(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var url = folder.appending(path: name)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = folder.appending(path: "\(base) \(counter).\(pathExtension)")
            counter += 1
        }
        return url
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/TranscriptExporterTests" 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit.**

```bash
git add "Audio Transcribe/TranscriptExporter.swift" "Audio TranscribeTests/TranscriptExporterTests.swift"
git commit -m "Add TranscriptExporter for combined and per-source text files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015fuauoR6c8DfMT23Xcmsce"
```

---

### Task 3: Input device listing and microphone device selection (macOS)

**Files:**
- Create: `Audio Transcribe/CoreAudioProperty.swift`
- Create: `Audio Transcribe/AudioInputDevices.swift`
- Modify: `Audio Transcribe/MicrophoneSource.swift` (whole file)
- Test: `Audio TranscribeTests/AudioInputDevicesTests.swift`

**Interfaces:**
- Produces (macOS only):
  - `enum CoreAudioProperty` with:
    - `address(_:scope:)`
    - `value<T>(of:_:scope:initial:) -> T?`
    - `array<T>(of:_:scope:initial:) -> [T]`
    - `string(of:_:scope:) -> String?`
  - `struct AudioInputDevice: Identifiable, Hashable { let id: AudioDeviceID; let uid: String; let name: String }`
  - `AudioInputDevices.all() -> [AudioInputDevice]`
  - `AudioInputDevices.defaultDeviceID() -> AudioDeviceID?`
  - `AudioInputDevices.resolve(uid: String?, in: [AudioInputDevice], defaultID: AudioDeviceID?) -> AudioDeviceID?`
- Produces (all platforms):
  - `MicrophoneSource.start(deviceID: UInt32? = nil) throws -> AsyncStream<AVAudioPCMBuffer>`. `AudioDeviceID` is `UInt32`. The parameter is ignored outside macOS.
  - `nonisolated enum MicrophoneError: LocalizedError { case deviceSelectionFailed(OSStatus) }`
  - When the selected device disappears mid-recording, the returned stream finishes by itself.

- [ ] **Step 1: Write the failing tests.** Create `Audio TranscribeTests/AudioInputDevicesTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/AudioInputDevicesTests" 2>&1 | tail -20`
Expected: FAIL with "cannot find 'AudioInputDevice' in scope".

- [ ] **Step 3: Implement the Core Audio property helpers.** Create `Audio Transcribe/CoreAudioProperty.swift`:

```swift
#if os(macOS)
import CoreAudio

/// Small typed wrappers around `AudioObjectGetPropertyData`.
enum CoreAudioProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size property value, or `nil` if the object doesn't have the property.
    static func value<T>(
        of object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) -> T? {
        var address = Self.address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// Reads a variable-length array property, such as a list of object IDs. Returns `[]` on failure.
    static func array<T>(
        of object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) -> [T] {
        var address = Self.address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [T](repeating: initial, count: Int(size) / MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr else { return [] }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// Reads a `CFString` property.
    static func string(
        of object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = Self.address(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
#endif
```

- [ ] **Step 4: Implement the device listing.** Create `Audio Transcribe/AudioInputDevices.swift`:

```swift
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
```

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/AudioInputDevicesTests" 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Add device selection and disconnect handling to `MicrophoneSource`.** Replace `Audio Transcribe/MicrophoneSource.swift` with:

```swift
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
```

- [ ] **Step 7: Build both platforms.**

Run: `xcodebuild build -scheme "Audio Transcribe" -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD" ; xcodebuild build -scheme "Audio Transcribe" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **` twice. The existing `installTap` deprecation warning is fine.

- [ ] **Step 8: Commit.**

```bash
git add "Audio Transcribe/CoreAudioProperty.swift" "Audio Transcribe/AudioInputDevices.swift" "Audio Transcribe/MicrophoneSource.swift" "Audio TranscribeTests/AudioInputDevicesTests.swift"
git commit -m "Add input device listing and microphone device selection

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015fuauoR6c8DfMT23Xcmsce"
```

Manual check 3.7, for Review Focus #1: after Task 8, when the UI exists, record with a USB or Bluetooth mic selected.
- Switching the output device (for example, plugging in wired headphones) keeps the transcript going.
- Unplugging the selected mic shows the disconnect warning.

This manual check is repeated in Task 10.

---

### Task 4: Audio app listing (macOS)

**Files:**
- Create: `Audio Transcribe/AudioApps.swift`
- Test: `Audio TranscribeTests/AudioAppsTests.swift`

**Interfaces:**
- Consumes: `CoreAudioProperty` (Task 3).
- Produces (macOS only):
  - `struct AudioApp: Identifiable, Hashable { let id: String /* bundle ID */; let name: String; let processObjectIDs: [AudioObjectID] }`
  - `struct AudioProcess: Equatable { let objectID: AudioObjectID; let bundleID: String; let name: String?; let isRunningOutput: Bool }`
  - `AudioApps.running() -> [AudioApp]`
  - `AudioApps.group(_ processes: [AudioProcess], ownBundleID: String, appName: (String) -> String?) -> [AudioApp]`
  - `AudioApps.processObjectIDs(for bundleID: String) -> [AudioObjectID]`

**Refinement of the spec:** a process whose owning regular app can't be found appears on its own, but only while it is playing audio. Safari plays audio through `com.apple.WebKit.GPU`, which appears as "Safari Graphics and Media" while playing. Without this rule, idle background daemons would crowd the menu.

- [ ] **Step 1: Write the failing tests.** Create `Audio TranscribeTests/AudioAppsTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/AudioAppsTests" 2>&1 | tail -20`
Expected: FAIL with "cannot find 'AudioProcess' in scope".

- [ ] **Step 3: Implement.** Create `Audio Transcribe/AudioApps.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/AudioAppsTests" 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit.**

```bash
git add "Audio Transcribe/AudioApps.swift" "Audio TranscribeTests/AudioAppsTests.swift"
git commit -m "List audio apps with their helper processes for per-app capture

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015fuauoR6c8DfMT23Xcmsce"
```

---

### Task 5: System audio target (all audio or one app)

**Files:**
- Create: `Audio Transcribe/SystemAudioTarget.swift` (not platform-conditional, so the view model compiles everywhere)
- Modify: `Audio Transcribe/SystemAudioSource.swift`:
  - the error enum (lines 5-24)
  - the `start()` signature and tap creation (lines 34-36)
  - a new static helper after `stop()`
- Test: `Audio TranscribeTests/SystemAudioTargetTests.swift`

**Interfaces:**
- Consumes: `AudioApps.processObjectIDs(for:)` (Task 4).
- Produces:
  - `enum SystemAudioTarget: Hashable { case allAudio; case app(bundleID: String, name: String) }`, with `var label: String`.
  - `SystemAudioSource.start(target: SystemAudioTarget = .allAudio) throws -> AsyncStream<AVAudioPCMBuffer>` (macOS).
  - `static func SystemAudioSource.tapDescription(for: SystemAudioTarget, processObjectIDs: [AudioObjectID]) -> CATapDescription` (macOS).
  - `SystemAudioCaptureError.appNotRunning(String)`, whose message is `"<name> isn't running."`

- [ ] **Step 1: Write the failing tests.** Create `Audio TranscribeTests/SystemAudioTargetTests.swift`:

```swift
import Testing
@testable import Audio_Transcribe

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
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/SystemAudioTargetTests" 2>&1 | tail -20`
Expected: FAIL with "cannot find 'SystemAudioTarget' in scope".

- [ ] **Step 3: Create the target type.** Create `Audio Transcribe/SystemAudioTarget.swift`:

```swift
/// What system audio to capture: everything the Mac plays, or one app's audio.
enum SystemAudioTarget: Hashable {
    case allAudio
    case app(bundleID: String, name: String)

    /// The speaker label for this source in multi-source transcripts.
    var label: String {
        switch self {
        case .allAudio: "System audio"
        case .app(_, let name): name
        }
    }
}
```

- [ ] **Step 4: Update `SystemAudioSource`.** In `Audio Transcribe/SystemAudioSource.swift`, make these changes.

Add a case to `SystemAudioCaptureError`, after `case startFailed(OSStatus)`:

```swift
    case appNotRunning(String)
```

Add a matching case to `errorDescription`, after the `.startFailed` case:

```swift
        case .appNotRunning(let name):
            "\(name) isn't running."
```

Replace the doc comment and first lines of `start()`, which currently are:

```swift
    func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.isPrivate = true
```

with:

```swift
    func start(target: SystemAudioTarget = .allAudio) throws -> AsyncStream<AVAudioPCMBuffer> {
        var processObjectIDs: [AudioObjectID] = []
        if case .app(let bundleID, let name) = target {
            // Resolve at start so helper processes launched since the menu was shown are included.
            processObjectIDs = AudioApps.processObjectIDs(for: bundleID)
            guard !processObjectIDs.isEmpty else { throw SystemAudioCaptureError.appNotRunning(name) }
        }
        let tapDescription = Self.tapDescription(for: target, processObjectIDs: processObjectIDs)
```

Change the class doc comment to:

```swift
/// Captures system audio output (everything the Mac is playing, or one app's audio) using a
/// Core Audio process tap, and exposes it as a stream of PCM buffers.
```

Add after `func stop() { tearDown() }`:

```swift
    /// A private stereo tap of all system audio, or a mixdown of just `processObjectIDs` for an app target.
    static func tapDescription(for target: SystemAudioTarget, processObjectIDs: [AudioObjectID]) -> CATapDescription {
        let description = switch target {
        case .allAudio: CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .app: CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        }
        description.isPrivate = true
        return description
    }
```

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/SystemAudioTargetTests" -only-testing:"Audio TranscribeTests/SystemAudioBufferCopyTests" 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit.**

```bash
git add "Audio Transcribe/SystemAudioTarget.swift" "Audio Transcribe/SystemAudioSource.swift" "Audio TranscribeTests/SystemAudioTargetTests.swift"
git commit -m "Capture system audio from all apps or a single app

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015fuauoR6c8DfMT23Xcmsce"
```

---

### Task 6: LiveChannel (one source + one transcriber)

**Files:**
- Create: `Audio Transcribe/LiveChannel.swift`
- Create: `Audio TranscribeTests/LiveTestDoubles.swift`
- Test: `Audio TranscribeTests/LiveChannelTests.swift`

**Interfaces:**
- Consumes:
  - `TranscriptionEngine`, with `startLiveTranscription(language:)`, `appendLiveAudio(_:)`, and `finishLiveTranscription()`. It is unchanged.
  - `TranscriptUpdate`
  - `TranscriptSegment(start:end:text:speaker:)` (Task 1)
- Produces:
  - `nonisolated protocol LiveTranscribing: Sendable`, with the three engine methods as `async` requirements. `TranscriptionEngine` conforms.
  - `enum ChannelKind: Hashable { case microphone, systemAudio }`
  - `struct LiveAudioSource { let start: () throws -> AsyncStream<AVAudioPCMBuffer>; let stop: () -> Void }`
  - `@Observable final class LiveChannel` with:
    - `kind`, `label`, `timeOffset`
    - `var segments: [TranscriptSegment]` and `var volatileText: String`
    - `isRunning` and `endedUnexpectedly`
    - `var onUnexpectedEnd: (() -> Void)?` and `var onFailure: ((Error) -> Void)?`
    - `init(kind:label:source:transcriber:)`
    - `start(language:sessionStart:labelSegments:) async throws` and `stop() async throws`
    - `static startAll(_:language:sessionStart:labelSegments:) async throws` and `static stopAll(_:) async throws`
  - Test doubles, reused by Task 7:
    - `actor FakeTranscriber`, with `emit(_:)`, `fail(_:)`, and `finishCount`
    - `final class FakeSource`, with `startError`, `stopCount`, `liveAudioSource`, and `endUnexpectedly()`
    - `struct TestError: LocalizedError`
    - `func makeIdleChannel(_:label:segments:volatileText:) -> LiveChannel`

A `LiveChannel` runs once. The view model creates new channels for every session.

- [ ] **Step 1: Write the test doubles.** Create `Audio TranscribeTests/LiveTestDoubles.swift`:

```swift
import AVFoundation
import Foundation
@testable import Audio_Transcribe

struct TestError: LocalizedError {
    var errorDescription: String? { "Test error." }
}

/// A transcriber whose results the test drives by hand.
actor FakeTranscriber: LiveTranscribing {
    private let startError: Error?
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private(set) var finishCount = 0

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func startLiveTranscription(language: TranscriptionLanguage) throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        self.continuation = continuation
        return stream
    }

    func appendLiveAudio(_ buffer: AVAudioPCMBuffer) {}

    func finishLiveTranscription() throws {
        finishCount += 1
        continuation?.finish()
        continuation = nil
    }

    func emit(_ update: TranscriptUpdate) {
        continuation?.yield(update)
    }

    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

/// A capture source whose lifetime the test drives by hand.
final class FakeSource {
    var startError: Error?
    private(set) var stopCount = 0
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    var liveAudioSource: LiveAudioSource {
        LiveAudioSource(
            start: { [self] in
                if let startError { throw startError }
                let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
                self.continuation = continuation
                return stream
            },
            stop: { [self] in
                stopCount += 1
                continuation?.finish()
                continuation = nil
            }
        )
    }

    /// Ends the buffer stream without `stop()`, as when a device is unplugged.
    func endUnexpectedly() {
        continuation?.finish()
        continuation = nil
    }
}

/// A channel that has not been started, with its transcript filled in directly.
func makeIdleChannel(
    _ kind: ChannelKind,
    label: String,
    segments: [TranscriptSegment] = [],
    volatileText: String = ""
) -> LiveChannel {
    let channel = LiveChannel(kind: kind, label: label, source: FakeSource().liveAudioSource, transcriber: FakeTranscriber())
    channel.segments = segments
    channel.volatileText = volatileText
    return channel
}
```

- [ ] **Step 2: Write the failing tests.** Create `Audio TranscribeTests/LiveChannelTests.swift`:

```swift
import Foundation
import Testing
@testable import Audio_Transcribe

struct LiveChannelTests {
    private func makeChannel(_ source: FakeSource, _ transcriber: FakeTranscriber, label: String = "Zoom") -> LiveChannel {
        LiveChannel(kind: .systemAudio, label: label, source: source.liveAudioSource, transcriber: transcriber)
    }

    @Test func finalResultsMoveOntoTheSessionTimelineWithTheSpeakerLabel() async throws {
        let source = FakeSource()
        let transcriber = FakeTranscriber()
        let channel = makeChannel(source, transcriber)

        try await channel.start(language: .english, sessionStart: Date(timeIntervalSinceNow: -5), labelSegments: true)
        await transcriber.emit(TranscriptUpdate(text: " Hi there.", start: 1, end: 2, isFinal: true))
        try await channel.stop()

        let segment = try #require(channel.segments.first)
        #expect(segment.text == " Hi there.")
        #expect(abs(segment.start - 6) < 0.5)
        #expect(abs(segment.end - 7) < 0.5)
        #expect(segment.speaker == "Zoom")
    }

    @Test func segmentsHaveNoSpeakerWhenLabelsAreOff() async throws {
        let transcriber = FakeTranscriber()
        let channel = makeChannel(FakeSource(), transcriber)

        try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)
        await transcriber.emit(TranscriptUpdate(text: "Hi.", start: 0, end: 1, isFinal: true))
        await transcriber.emit(TranscriptUpdate(text: " Nex", start: 1, end: 1.5, isFinal: false))
        try await channel.stop()

        #expect(channel.segments.map(\.speaker) == [nil])
        #expect(channel.volatileText == " Nex")
    }

    @Test func stopWaitsForPendingResults() async throws {
        let source = FakeSource()
        let transcriber = FakeTranscriber()
        let channel = makeChannel(source, transcriber)

        try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)
        for index in 0..<3 {
            await transcriber.emit(TranscriptUpdate(text: "\(index)", start: Double(index), end: Double(index) + 1, isFinal: true))
        }
        try await channel.stop()

        #expect(channel.segments.map(\.text) == ["0", "1", "2"])
        #expect(!channel.isRunning)
        #expect(source.stopCount == 1)
        #expect(await transcriber.finishCount == 1)
    }

    @Test func stoppingDoesNotReportAnUnexpectedEnd() async throws {
        let channel = makeChannel(FakeSource(), FakeTranscriber())
        var reported = false
        channel.onUnexpectedEnd = { reported = true }

        try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)
        try await channel.stop()
        for _ in 0..<10 { await Task.yield() }

        #expect(!reported)
        #expect(!channel.endedUnexpectedly)
    }

    @Test func sourceEndingByItselfEndsTheChannel() async throws {
        let source = FakeSource()
        let transcriber = FakeTranscriber()
        let channel = makeChannel(source, transcriber)
        try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)

        await withCheckedContinuation { continuation in
            channel.onUnexpectedEnd = { continuation.resume() }
            source.endUnexpectedly()
        }

        #expect(channel.endedUnexpectedly)
        #expect(!channel.isRunning)
        #expect(source.stopCount == 1)
        #expect(await transcriber.finishCount == 1)

        try await channel.stop()
        #expect(source.stopCount == 1)
        #expect(await transcriber.finishCount == 1)
    }

    @Test func sourceFailureFinishesTheTranscriberAndRethrows() async {
        let source = FakeSource()
        source.startError = TestError()
        let transcriber = FakeTranscriber()
        let channel = makeChannel(source, transcriber)

        await #expect(throws: TestError.self) {
            try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)
        }
        #expect(!channel.isRunning)
        #expect(await transcriber.finishCount == 1)
    }

    @Test func transcriberErrorsAreReported() async throws {
        let transcriber = FakeTranscriber()
        let channel = makeChannel(FakeSource(), transcriber)
        try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)

        let error = await withCheckedContinuation { (continuation: CheckedContinuation<Error, Never>) in
            channel.onFailure = { continuation.resume(returning: $0) }
            Task { await transcriber.fail(TestError()) }
        }

        #expect(error is TestError)
        try await channel.stop()
    }

    @Test func startAllStopsStartedChannelsWhenOneFails() async {
        let micSource = FakeSource()
        let micTranscriber = FakeTranscriber()
        let appSource = FakeSource()
        appSource.startError = TestError()
        let mic = LiveChannel(kind: .microphone, label: "You", source: micSource.liveAudioSource, transcriber: micTranscriber)
        let app = makeChannel(appSource, FakeTranscriber())

        await #expect(throws: TestError.self) {
            try await LiveChannel.startAll([mic, app], language: .english, sessionStart: Date(), labelSegments: true)
        }

        #expect(!mic.isRunning)
        #expect(!app.isRunning)
        #expect(micSource.stopCount == 1)
        #expect(await micTranscriber.finishCount == 1)
    }

    @Test func stopAllStopsEveryChannel() async throws {
        let sources = [FakeSource(), FakeSource()]
        let channels = sources.map { makeChannel($0, FakeTranscriber()) }

        try await LiveChannel.startAll(channels, language: .english, sessionStart: Date(), labelSegments: true)
        #expect(channels.allSatisfy(\.isRunning))
        try await LiveChannel.stopAll(channels)

        #expect(channels.allSatisfy { !$0.isRunning })
        #expect(sources.map(\.stopCount) == [1, 1])
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/LiveChannelTests" 2>&1 | tail -20`
Expected: FAIL with "cannot find type 'LiveTranscribing' in scope".

- [ ] **Step 4: Implement.** Create `Audio Transcribe/LiveChannel.swift`:

```swift
import AVFoundation
import Observation

/// Transcribes a live stream of audio buffers. `TranscriptionEngine` is the real implementation; tests use a fake.
nonisolated protocol LiveTranscribing: Sendable {
    func startLiveTranscription(language: TranscriptionLanguage) async throws -> AsyncThrowingStream<TranscriptUpdate, Error>
    func appendLiveAudio(_ buffer: AVAudioPCMBuffer) async
    func finishLiveTranscription() async throws
}

extension TranscriptionEngine: LiveTranscribing {}

enum ChannelKind: Hashable {
    case microphone
    case systemAudio
}

/// Starts and stops one capture source, such as `MicrophoneSource` or `SystemAudioSource`.
struct LiveAudioSource {
    let start: () throws -> AsyncStream<AVAudioPCMBuffer>
    let stop: () -> Void
}

/// One live capture source paired with its own transcriber. Segments are stored on the session timeline:
/// `timeOffset` (how long after the session started this channel started) is added to the transcriber's times.
/// A channel runs once; start a new one for each session.
@Observable
final class LiveChannel {
    let kind: ChannelKind
    /// "You" for the microphone; the app name or "System audio" for system audio.
    let label: String
    private(set) var timeOffset: TimeInterval = 0
    var segments: [TranscriptSegment] = []
    var volatileText = ""
    private(set) var isRunning = false
    /// Set when the source stopped by itself, for example because the microphone was unplugged.
    private(set) var endedUnexpectedly = false

    @ObservationIgnored var onUnexpectedEnd: (() -> Void)?
    @ObservationIgnored var onFailure: ((Error) -> Void)?

    private let source: LiveAudioSource
    private let transcriber: any LiveTranscribing
    @ObservationIgnored private var labelSegments = false
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?

    init(kind: ChannelKind, label: String, source: LiveAudioSource, transcriber: any LiveTranscribing) {
        self.kind = kind
        self.label = label
        self.source = source
        self.transcriber = transcriber
    }

    /// Starts the transcriber, then the source. If the source fails to start, the transcriber is finished and the
    /// error is rethrown. With `labelSegments`, each segment's `speaker` is set to `label`.
    func start(language: TranscriptionLanguage, sessionStart: Date, labelSegments: Bool) async throws {
        self.labelSegments = labelSegments
        let results = try await transcriber.startLiveTranscription(language: language)

        let buffers: AsyncStream<AVAudioPCMBuffer>
        do {
            buffers = try source.start()
        } catch {
            try? await transcriber.finishLiveTranscription()
            throw error
        }
        timeOffset = Date().timeIntervalSince(sessionStart)
        isRunning = true

        resultsTask = Task { [weak self] in
            await self?.consume(results)
        }
        feedTask = Task { [weak self, transcriber] in
            for await buffer in buffers {
                await transcriber.appendLiveAudio(buffer)
            }
            await self?.sourceDidEnd()
        }
    }

    /// Stops the source and waits until the transcriber has delivered its final results. Does nothing if the
    /// channel isn't running.
    func stop() async throws {
        guard isRunning else { return }
        isStopping = true
        source.stop()
        feedTask?.cancel()
        feedTask = nil
        try await finishTranscriber()
    }

    /// Starts every channel concurrently. If any fails, stops the ones that started and rethrows the first error.
    static func startAll(
        _ channels: [LiveChannel],
        language: TranscriptionLanguage,
        sessionStart: Date,
        labelSegments: Bool
    ) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for channel in channels {
                    group.addTask {
                        try await channel.start(language: language, sessionStart: sessionStart, labelSegments: labelSegments)
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            for channel in channels {
                try? await channel.stop()
            }
            throw error
        }
    }

    /// Stops every channel concurrently, then throws the first error, if any.
    static func stopAll(_ channels: [LiveChannel]) async throws {
        var firstError: Error?
        await withTaskGroup(of: Error?.self) { group in
            for channel in channels {
                group.addTask {
                    do {
                        try await channel.stop()
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            for await case let error? in group where firstError == nil {
                firstError = error
            }
        }
        if let firstError { throw firstError }
    }

    private func finishTranscriber() async throws {
        isRunning = false
        let resultsTask = self.resultsTask
        self.resultsTask = nil
        do {
            try await transcriber.finishLiveTranscription()
        } catch {
            resultsTask?.cancel()
            throw error
        }
        await resultsTask?.value
    }

    private func sourceDidEnd() async {
        guard isRunning, !isStopping else { return }
        endedUnexpectedly = true
        source.stop()
        try? await finishTranscriber()
        onUnexpectedEnd?()
    }

    private func consume(_ results: AsyncThrowingStream<TranscriptUpdate, Error>) async {
        do {
            for try await update in results {
                if update.isFinal {
                    segments.append(TranscriptSegment(
                        start: update.start + timeOffset,
                        end: update.end + timeOffset,
                        text: update.text,
                        speaker: labelSegments ? label : nil
                    ))
                    volatileText = ""
                } else {
                    volatileText = update.text
                }
            }
        } catch {
            onFailure?(error)
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/LiveChannelTests" 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit.**

```bash
git add "Audio Transcribe/LiveChannel.swift" "Audio TranscribeTests/LiveTestDoubles.swift" "Audio TranscribeTests/LiveChannelTests.swift"
git commit -m "Add LiveChannel pairing a capture source with its own transcriber

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015fuauoR6c8DfMT23Xcmsce"
```

---

### Task 7: View model — live sessions with several channels

**Files:**
- Modify: `Audio Transcribe/TranscriptionViewModel.swift` (whole file)
- Modify: `Audio Transcribe/ContentView.swift`. These are minimal renames so the app still builds; Task 8 replaces the UI.
- Test: `Audio TranscribeTests/TranscriptionViewModelTests.swift` (whole file)

**Interfaces:**
- Consumes:
  - `LiveChannel`, `LiveAudioSource`, `ChannelKind` (Task 6)
  - `TranscriptSegment.merged` (Task 1)
  - `TranscriptExporter.files`, `ExportKind`, `ExportFile` (Task 2)
  - `AudioInputDevices.resolve/all/defaultDeviceID` (Task 3)
  - `MicrophoneSource.start(deviceID:)` (Task 3)
  - `SystemAudioSource.start(target:)` and `SystemAudioTarget` (Task 5)
- Produces:
  - `enum CaptureMode: String, CaseIterable, Identifiable { case live, file }`, with `displayName` returning "Live" or "File". This replaces `TranscriptionSource`.
  - `struct VolatileLine: Identifiable, Equatable { let label: String?; let text: String }`
  - `TranscriptionViewModel` members:
    - `mode`, `micEnabled`, `selectedMicUID: String?`, `systemAudioEnabled`, `systemAudioTarget`
    - `var channels: [LiveChannel]`, `var fileSegments`, `var fileVolatileText`, `var channelWarning: String?`
    - `supportsSystemAudio`, `canStart`, `segments` (computed), `volatileLines`, `fullText`, `hasSeparateSources`
    - `exportFiles(_:baseName:) -> [ExportFile]`
    - `start()`, `stop()`, `transcribe(fileURL:)`, `clear()`, `consume(_:)`
    - `static func warning(for kind: ChannelKind, othersStillRunning: Bool) -> String`

- [ ] **Step 1: Write the failing tests.** Replace `Audio TranscribeTests/TranscriptionViewModelTests.swift` with:

```swift
import Foundation
import Testing
@testable import Audio_Transcribe

struct TranscriptionViewModelTests {
    @Test func startsInLiveModeWithOnlyTheMicrophoneOn() {
        let viewModel = TranscriptionViewModel()
        #expect(viewModel.mode == .live)
        #expect(viewModel.micEnabled)
        #expect(!viewModel.systemAudioEnabled)
        #expect(viewModel.systemAudioTarget == .allAudio)
        #expect(viewModel.selectedMicUID == nil)
    }

    @Test func systemAudioIsOfferedOnlyOnMacOS() {
        #if os(macOS)
        #expect(TranscriptionViewModel().supportsSystemAudio)
        #else
        #expect(!TranscriptionViewModel().supportsSystemAudio)
        #endif
    }

    @Test(arguments: [
        (true, false, true),
        (false, true, true),
        (true, true, true),
        (false, false, false),
    ])
    func canStartNeedsAnEnabledSource(mic: Bool, systemAudio: Bool, expected: Bool) {
        let viewModel = TranscriptionViewModel()
        viewModel.micEnabled = mic
        viewModel.systemAudioEnabled = systemAudio
        #if os(macOS)
        #expect(viewModel.canStart == expected)
        #else
        #expect(viewModel.canStart == mic)
        #endif
    }

    @Test(arguments: [TranscriptionStatus.recording, .preparingModel, .transcribingFile])
    func cannotStartWhileRecordingOrBusy(status: TranscriptionStatus) {
        let viewModel = TranscriptionViewModel()
        viewModel.status = status
        #expect(!viewModel.canStart)
    }

    @Test(arguments: [
        (TranscriptionStatus.idle, false, false),
        (.preparingModel, false, true),
        (.recording, true, false),
        (.transcribingFile, false, true),
        (.failed("error"), false, false),
    ])
    func recordingAndBusyFlags(status: TranscriptionStatus, isRecording: Bool, isBusy: Bool) {
        let viewModel = TranscriptionViewModel()
        viewModel.status = status
        #expect(viewModel.isRecording == isRecording)
        #expect(viewModel.isBusy == isBusy)
    }

    @Test func fullTextKeepsEnglishSpacingFromTheTranscriber() {
        let viewModel = TranscriptionViewModel()
        viewModel.fileSegments = [
            TranscriptSegment(start: 0, end: 2, text: "Hello, this is a test."),
            TranscriptSegment(start: 2, end: 4, text: " The quick brown fox."),
        ]
        #expect(viewModel.fullText == "Hello, this is a test. The quick brown fox.")
    }

    @Test func fullTextDoesNotInsertSpacesIntoJapanese() {
        let viewModel = TranscriptionViewModel()
        viewModel.fileSegments = [
            TranscriptSegment(start: 0, end: 2, text: "こんにちは。"),
            TranscriptSegment(start: 2, end: 4, text: "これはテストです。"),
        ]
        #expect(viewModel.fullText == "こんにちは。これはテストです。")
    }

    @Test func multiSourceTranscriptIsMergedAndLabeled() {
        let viewModel = TranscriptionViewModel()
        viewModel.channels = [
            makeIdleChannel(.microphone, label: "You", segments: [
                TranscriptSegment(start: 0, end: 1, text: " Hello.", speaker: "You"),
                TranscriptSegment(start: 4, end: 5, text: " Bye.", speaker: "You"),
            ]),
            makeIdleChannel(.systemAudio, label: "Zoom", segments: [
                TranscriptSegment(start: 2, end: 3, text: " Hi.", speaker: "Zoom"),
            ]),
        ]
        #expect(viewModel.segments.map(\.text) == [" Hello.", " Hi.", " Bye."])
        #expect(viewModel.fullText == "You: Hello.\nZoom: Hi.\nYou: Bye.")
        #expect(viewModel.hasSeparateSources)
    }

    @Test func liveChannelsReplaceTheFileTranscript() {
        let viewModel = TranscriptionViewModel()
        viewModel.fileSegments = [TranscriptSegment(start: 0, end: 1, text: "file")]
        viewModel.channels = [makeIdleChannel(.microphone, label: "You", segments: [TranscriptSegment(start: 0, end: 1, text: "live")])]
        #expect(viewModel.segments.map(\.text) == ["live"])
        #expect(!viewModel.hasSeparateSources)
    }

    @Test func volatileLinesAreLabeledOnlyWithSeveralSources() {
        let viewModel = TranscriptionViewModel()
        viewModel.channels = [
            makeIdleChannel(.microphone, label: "You", volatileText: "Hel"),
            makeIdleChannel(.systemAudio, label: "Zoom"),
        ]
        #expect(viewModel.volatileLines == [VolatileLine(label: "You", text: "Hel")])

        viewModel.channels = [makeIdleChannel(.microphone, label: "You", volatileText: "Hel")]
        #expect(viewModel.volatileLines == [VolatileLine(label: nil, text: "Hel")])

        viewModel.channels = []
        viewModel.fileVolatileText = "fi"
        #expect(viewModel.volatileLines == [VolatileLine(label: nil, text: "fi")])
    }

    @Test func exportFilesUseTheMergedAndPerSourceTranscripts() {
        let viewModel = TranscriptionViewModel()
        viewModel.channels = [
            makeIdleChannel(.microphone, label: "You", segments: [TranscriptSegment(start: 0, end: 1, text: " Hello.", speaker: "You")]),
            makeIdleChannel(.systemAudio, label: "Zoom", segments: [TranscriptSegment(start: 2, end: 3, text: " Hi.", speaker: "Zoom")]),
        ]
        let files = viewModel.exportFiles(.combinedAndSeparate, baseName: "T")
        #expect(files == [
            ExportFile(name: "T.txt", text: "[00:00] You: Hello.\n[00:02] Zoom: Hi."),
            ExportFile(name: "T-You.txt", text: "[00:00] Hello."),
            ExportFile(name: "T-Zoom.txt", text: "[00:02] Hi."),
        ])
    }

    @Test func clearRemovesTranscript() {
        let viewModel = TranscriptionViewModel()
        viewModel.fileSegments = [TranscriptSegment(start: 0, end: 1, text: "Hello")]
        viewModel.fileVolatileText = "wor"
        viewModel.channels = [makeIdleChannel(.microphone, label: "You")]
        viewModel.channelWarning = "warning"
        viewModel.clear()
        #expect(viewModel.fileSegments.isEmpty)
        #expect(viewModel.fileVolatileText.isEmpty)
        #expect(viewModel.channels.isEmpty)
        #expect(viewModel.channelWarning == nil)
    }

    @Test func clearDoesNothingWhileRecording() {
        let viewModel = TranscriptionViewModel()
        viewModel.channels = [makeIdleChannel(.microphone, label: "You")]
        viewModel.status = .recording
        viewModel.clear()
        #expect(viewModel.channels.count == 1)
    }

    @Test(arguments: [
        (ChannelKind.microphone, true, "The microphone was disconnected. Other sources are still being transcribed."),
        (.microphone, false, "The microphone was disconnected."),
        (.systemAudio, true, "System audio capture stopped. Other sources are still being transcribed."),
        (.systemAudio, false, "System audio capture stopped."),
    ])
    func channelWarning(kind: ChannelKind, othersStillRunning: Bool, expected: String) {
        #expect(TranscriptionViewModel.warning(for: kind, othersStillRunning: othersStillRunning) == expected)
    }

    @Test func consumeReplacesVolatileTextAndAppendsFinalResults() async {
        let viewModel = TranscriptionViewModel()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        continuation.yield(TranscriptUpdate(text: "Hel", start: 0, end: 0.5, isFinal: false))
        continuation.yield(TranscriptUpdate(text: "Hello wor", start: 0, end: 1, isFinal: false))
        continuation.yield(TranscriptUpdate(text: "Hello world.", start: 0, end: 1.2, isFinal: true))
        continuation.yield(TranscriptUpdate(text: " Next", start: 1.2, end: 1.6, isFinal: false))
        continuation.finish()

        await viewModel.consume(stream)

        #expect(viewModel.fileSegments.map(\.text) == ["Hello world."])
        #expect(viewModel.fileSegments.first?.start == 0)
        #expect(viewModel.fileSegments.first?.end == 1.2)
        #expect(viewModel.fileVolatileText == " Next")
    }

    @Test func consumeClearsVolatileTextWhenItBecomesFinal() async {
        let viewModel = TranscriptionViewModel()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        continuation.yield(TranscriptUpdate(text: "こんにち", start: 0, end: 0.5, isFinal: false))
        continuation.yield(TranscriptUpdate(text: "こんにちは。", start: 0, end: 1, isFinal: true))
        continuation.finish()

        await viewModel.consume(stream)

        #expect(viewModel.fileSegments.map(\.text) == ["こんにちは。"])
        #expect(viewModel.fileVolatileText.isEmpty)
    }

    @Test func consumeReportsStreamErrors() async {
        let viewModel = TranscriptionViewModel()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        continuation.yield(TranscriptUpdate(text: "Partial.", start: 0, end: 1, isFinal: true))
        continuation.finish(throwing: TranscriptionError.unsupportedLocale)

        await viewModel.consume(stream)

        #expect(viewModel.fileSegments.map(\.text) == ["Partial."])
        #expect(viewModel.status == .failed(TranscriptionError.unsupportedLocale.localizedDescription))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/TranscriptionViewModelTests" 2>&1 | tail -20`
Expected: FAIL with "value of type 'TranscriptionViewModel' has no member 'mode'".

- [ ] **Step 3: Implement the view model.** Replace `Audio Transcribe/TranscriptionViewModel.swift` with:

```swift
import Foundation
import AVFoundation
import Observation

enum CaptureMode: String, CaseIterable, Identifiable, Hashable {
    case live
    case file

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .live: "Live"
        case .file: "File"
        }
    }
}

enum TranscriptionStatus: Equatable {
    case idle
    case preparingModel
    case recording
    case transcribingFile
    case failed(String)
}

/// In-progress text for one source. `label` is set only when several sources are live.
struct VolatileLine: Identifiable, Equatable {
    let label: String?
    let text: String

    var id: String { label ?? "" }
}

@MainActor
@Observable
final class TranscriptionViewModel {
    var mode: CaptureMode = .live
    var language: TranscriptionLanguage = .english
    var status: TranscriptionStatus = .idle

    var micEnabled = true
    /// The chosen input device's UID (macOS). `nil` means the system default.
    var selectedMicUID: String?
    var systemAudioEnabled = false
    var systemAudioTarget: SystemAudioTarget = .allAudio

    /// The live session's channels. They are kept after stopping so the transcript can still be read and exported.
    var channels: [LiveChannel] = []
    /// The last file transcription.
    var fileSegments: [TranscriptSegment] = []
    var fileVolatileText = ""
    /// Shown when one source of a live session stops by itself, such as an unplugged microphone.
    var channelWarning: String?
    /// Download progress for the on-device language model, when a download is needed.
    var modelDownloadProgress: Progress?

    var supportsSystemAudio: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var canStart: Bool {
        let hasSource = micEnabled || (supportsSystemAudio && systemAudioEnabled)
        return hasSource && !isRecording && !isBusy
    }

    /// The transcript on one timeline: the live channels merged by time, or else the file transcript.
    var segments: [TranscriptSegment] {
        channels.isEmpty ? fileSegments : TranscriptSegment.merged(channels.map(\.segments))
    }

    var volatileLines: [VolatileLine] {
        if channels.isEmpty {
            return fileVolatileText.isEmpty ? [] : [VolatileLine(label: nil, text: fileVolatileText)]
        }
        let labeled = channels.count > 1
        return channels
            .filter { !$0.volatileText.isEmpty }
            .map { VolatileLine(label: labeled ? $0.label : nil, text: $0.volatileText) }
    }

    /// Whether the transcript came from several sources, so it can be exported as separate files.
    var hasSeparateSources: Bool { channels.count > 1 }

    /// The transcript as plain text for Copy and Share. A single-source transcript is concatenated as-is: the
    /// transcriber already includes leading spaces where the language needs them (English) and none where it doesn't
    /// (Japanese). A multi-source transcript puts each segment on its own `Speaker: text` line.
    var fullText: String {
        let segments = self.segments
        if segments.contains(where: { $0.speaker != nil }) {
            return segments
                .map { segment in
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return segment.speaker.map { "\($0): \(text)" } ?? text
                }
                .joined(separator: "\n")
        }
        return segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isRecording: Bool {
        if case .recording = status { return true }
        return false
    }

    var isBusy: Bool {
        switch status {
        case .preparingModel, .transcribingFile: true
        case .idle, .recording, .failed: false
        }
    }

    /// Prepares language assets and transcribes files. Each live channel has its own engine.
    private let engine = TranscriptionEngine()
    private let microphoneSource = MicrophoneSource()
    #if os(macOS)
    private let systemAudioSource = SystemAudioSource()
    #endif

    func start() async {
        guard mode == .live, canStart else { return }
        clear()

        if micEnabled {
            guard await AVAudioApplication.requestRecordPermission() else {
                status = .failed("Microphone access was denied.")
                return
            }
        }

        let newChannels = makeChannels()
        do {
            try await prepareAssets()
            channels = newChannels
            try await LiveChannel.startAll(
                newChannels,
                language: language,
                sessionStart: Date(),
                labelSegments: newChannels.count > 1
            )
            status = newChannels.contains(where: \.isRunning) ? .recording : .idle
        } catch {
            channels = []
            status = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        do {
            try await LiveChannel.stopAll(channels)
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func transcribe(fileURL: URL) async {
        clear()

        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            try await prepareAssets()

            status = .transcribingFile
            let resultsStream = try await engine.transcribeFile(at: fileURL, language: language)
            await consume(resultsStream)
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Clears the transcript. Does nothing while recording, so running channels are never dropped.
    func clear() {
        guard !isRecording else { return }
        channels = []
        fileSegments = []
        fileVolatileText = ""
        channelWarning = nil
    }

    func exportFiles(_ kind: ExportKind, baseName: String) -> [ExportFile] {
        TranscriptExporter.files(
            kind,
            baseName: baseName,
            combined: segments,
            channels: channels.map { (label: $0.label, segments: $0.segments) }
        )
    }

    static func warning(for kind: ChannelKind, othersStillRunning: Bool) -> String {
        let message = switch kind {
        case .microphone: "The microphone was disconnected."
        case .systemAudio: "System audio capture stopped."
        }
        return othersStillRunning ? "\(message) Other sources are still being transcribed." : message
    }

    private func makeChannels() -> [LiveChannel] {
        var channels: [LiveChannel] = []
        if micEnabled {
            #if os(macOS)
            let deviceID = AudioInputDevices.resolve(
                uid: selectedMicUID,
                in: AudioInputDevices.all(),
                defaultID: AudioInputDevices.defaultDeviceID()
            )
            #else
            let deviceID: UInt32? = nil
            #endif
            let microphone = microphoneSource
            channels.append(LiveChannel(
                kind: .microphone,
                label: "You",
                source: LiveAudioSource(
                    start: { try microphone.start(deviceID: deviceID) },
                    stop: { microphone.stop() }
                ),
                transcriber: TranscriptionEngine()
            ))
        }
        #if os(macOS)
        if systemAudioEnabled {
            let systemAudio = systemAudioSource
            let target = systemAudioTarget
            channels.append(LiveChannel(
                kind: .systemAudio,
                label: target.label,
                source: LiveAudioSource(
                    start: { try systemAudio.start(target: target) },
                    stop: { systemAudio.stop() }
                ),
                transcriber: TranscriptionEngine()
            ))
        }
        #endif
        for channel in channels {
            channel.onUnexpectedEnd = { [weak self, weak channel] in
                guard let self, let channel else { return }
                self.channelDidEndUnexpectedly(channel)
            }
            channel.onFailure = { [weak self] error in
                self?.liveTranscriptionDidFail(error)
            }
        }
        return channels
    }

    private func channelDidEndUnexpectedly(_ channel: LiveChannel) {
        let othersStillRunning = channels.contains(where: \.isRunning)
        channelWarning = Self.warning(for: channel.kind, othersStillRunning: othersStillRunning)
        if !othersStillRunning, isRecording {
            status = .idle
        }
    }

    private func liveTranscriptionDidFail(_ error: Error) {
        status = .failed(error.localizedDescription)
        let channels = self.channels
        Task {
            try? await LiveChannel.stopAll(channels)
        }
    }

    private func prepareAssets() async throws {
        status = .preparingModel
        defer { modelDownloadProgress = nil }
        try await engine.prepareAssets(for: language) { progress in
            Task { @MainActor in
                self.modelDownloadProgress = progress
            }
        }
    }

    /// Collects a file transcription's results.
    func consume(_ stream: AsyncThrowingStream<TranscriptUpdate, Error>) async {
        do {
            for try await update in stream {
                if update.isFinal {
                    fileSegments.append(TranscriptSegment(start: update.start, end: update.end, text: update.text))
                    fileVolatileText = ""
                } else {
                    fileVolatileText = update.text
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Keep `ContentView` compiling.** Make these edits in `Audio Transcribe/ContentView.swift`.

Replace the source picker:

```swift
            Picker("Source", selection: $viewModel.sourceKind) {
                ForEach(viewModel.availableSourceKinds) { source in
                    Text(source.displayName).tag(source)
                }
            }
```

with:

```swift
            Picker("Mode", selection: $viewModel.mode) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
```

In `actionButton`, replace `switch viewModel.sourceKind {` with `switch viewModel.mode {`, and `case .microphone, .systemAudio:` with `case .live:`. Replace the Start/Stop button's `.disabled(viewModel.isBusy)` with:

```swift
            .disabled(viewModel.isBusy || (!viewModel.isRecording && !viewModel.canStart))
```

In `transcriptView`, replace:

```swift
                    if !viewModel.volatileText.isEmpty {
                        Text(viewModel.volatileText)
                            .foregroundStyle(.secondary)
                            .id("volatile")
                    }
```

with:

```swift
                    ForEach(viewModel.volatileLines) { line in
                        Text(line.text)
                            .foregroundStyle(.secondary)
                    }
                    Color.clear
                        .frame(height: 0)
                        .id("volatile")
```

and replace `.onChange(of: viewModel.volatileText) {` with `.onChange(of: viewModel.volatileLines) {`.

- [ ] **Step 5: Run all tests and build iOS.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' 2>&1 | tail -30 ; xcodebuild build -scheme "Audio Transcribe" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"`
Expected: `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`. `TranscriptionEngineTests` may be skipped if the models are unavailable.

- [ ] **Step 6: Commit.**

```bash
git add "Audio Transcribe/TranscriptionViewModel.swift" "Audio Transcribe/ContentView.swift" "Audio TranscribeTests/TranscriptionViewModelTests.swift"
git commit -m "Run microphone and system audio as parallel live channels

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015fuauoR6c8DfMT23Xcmsce"
```

---

### Task 8: Source selection UI and labeled live transcript

**Files:**
- Create: `Audio Transcribe/AudioSourceCatalog.swift`
- Create: `Audio Transcribe/LiveSourcesView.swift`
- Modify: `Audio Transcribe/ContentView.swift` (whole file)

**Interfaces:**
- Consumes:
  - `AudioInputDevices`, `AudioInputDevice`, `CoreAudioProperty` (Task 3)
  - `AudioApps`, `AudioApp` (Task 4)
  - `SystemAudioTarget` (Task 5)
  - The view model API (Task 7)
- Produces (macOS):
  - `@Observable final class AudioSourceCatalog`, with `inputDevices`, `defaultInputName`, `apps`, `startObserving()`, and `refresh()`
  - `final class CoreAudioListener`
  - `struct LiveSourcesView: View`

No unit tests for this task: it is SwiftUI layout over tested logic. Verification is by building both platforms and running the app manually.

- [ ] **Step 1: Create the catalog.** Create `Audio Transcribe/AudioSourceCatalog.swift`:

```swift
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
```

- [ ] **Step 2: Create the source rows.** Create `Audio Transcribe/LiveSourcesView.swift`:

```swift
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The live sources: the microphone with its input device and, on macOS, system audio (all audio or one app).
struct LiveSourcesView: View {
    @Bindable var viewModel: TranscriptionViewModel
    #if os(macOS)
    @State private var catalog = AudioSourceCatalog()
    #endif

    var body: some View {
        #if os(macOS)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Toggle("Microphone", isOn: $viewModel.micEnabled)
                microphonePicker
                    .disabled(!viewModel.micEnabled)
            }
            GridRow {
                Toggle("System audio", isOn: $viewModel.systemAudioEnabled)
                systemAudioPicker
                    .disabled(!viewModel.systemAudioEnabled)
            }
        }
        .onAppear { catalog.startObserving() }
        #else
        Label("Microphone", systemImage: "mic")
            .foregroundStyle(.secondary)
        #endif
    }

    #if os(macOS)
    private var microphonePicker: some View {
        Picker("Microphone", selection: $viewModel.selectedMicUID) {
            Text(catalog.defaultInputName.map { "System Default (\($0))" } ?? "System Default")
                .tag(String?.none)
            Divider()
            ForEach(catalog.inputDevices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
            if let uid = viewModel.selectedMicUID, !catalog.inputDevices.contains(where: { $0.uid == uid }) {
                Text("Disconnected device").tag(Optional(uid))
            }
        }
        .labelsHidden()
    }

    private var systemAudioPicker: some View {
        Picker("System audio", selection: $viewModel.systemAudioTarget) {
            Text("All system audio").tag(SystemAudioTarget.allAudio)
            Divider()
            ForEach(catalog.apps) { app in
                Label { Text(app.name) } icon: { appIcon(bundleID: app.id) }
                    .tag(SystemAudioTarget.app(bundleID: app.id, name: app.name))
            }
            if case .app(let bundleID, let name) = viewModel.systemAudioTarget,
               !catalog.apps.contains(where: { $0.id == bundleID }) {
                Text("\(name) (not running)").tag(viewModel.systemAudioTarget)
            }
        }
        .labelsHidden()
    }

    private func appIcon(bundleID: String) -> Image {
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage()
        icon.size = NSSize(width: 16, height: 16)
        return Image(nsImage: icon)
    }
    #endif
}
```

- [ ] **Step 3: Update `ContentView`.** Replace `Audio Transcribe/ContentView.swift` with:

```swift
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ContentView: View {
    @State private var viewModel = TranscriptionViewModel()
    @State private var isImportingFile = false

    private var isLocked: Bool { viewModel.isRecording || viewModel.isBusy }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            statusBar
            Divider()
            transcriptView
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        #endif
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result {
                Task { await viewModel.transcribe(fileURL: url) }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $viewModel.mode) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isLocked)

            if viewModel.mode == .live {
                LiveSourcesView(viewModel: viewModel)
                    .disabled(isLocked)
            }

            Picker("Language", selection: $viewModel.language) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isLocked)

            actionButton
        }
        .padding()
    }

    @ViewBuilder
    private var actionButton: some View {
        switch viewModel.mode {
        case .live:
            Button {
                Task {
                    if viewModel.isRecording {
                        await viewModel.stop()
                    } else {
                        await viewModel.start()
                    }
                }
            } label: {
                Label(viewModel.isRecording ? "Stop" : "Start",
                      systemImage: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(viewModel.isRecording ? .red : .accentColor)
            .disabled(viewModel.isBusy || (!viewModel.isRecording && !viewModel.canStart))
        case .file:
            Button {
                isImportingFile = true
            } label: {
                Label("Open File…", systemImage: "folder")
            }
            .disabled(viewModel.isBusy)
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusContent
            if let warning = viewModel.channelWarning {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch viewModel.status {
        case .idle:
            EmptyView()
        case .preparingModel:
            HStack {
                if let progress = viewModel.modelDownloadProgress {
                    ProgressView(progress)
                        .labelsHidden()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(viewModel.modelDownloadProgress == nil ? "Preparing language model…" : "Downloading language model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        case .recording:
            HStack {
                Image(systemName: "waveform")
                Text("Listening…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
        case .transcribingFile:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing file…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        case .failed(let message):
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.segments) { segment in
                        transcriptRow(segment)
                            .id(segment.id)
                    }
                    ForEach(viewModel.volatileLines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let label = line.label {
                                speakerTag(label)
                            }
                            Text(line.text.trimmingCharacters(in: .whitespaces))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Color.clear
                        .frame(height: 0)
                        .id("volatile")
                }
                .padding()
            }
            .onChange(of: viewModel.segments.count) {
                withAnimation {
                    proxy.scrollTo(viewModel.segments.last?.id, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.volatileLines) {
                proxy.scrollTo("volatile", anchor: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.segments.isEmpty {
                transcriptActions
            }
        }
    }

    private var transcriptActions: some View {
        HStack {
            if !viewModel.isRecording {
                Button("Clear", role: .destructive) {
                    viewModel.clear()
                }
            }
            Spacer()
            Button {
                copyToClipboard(viewModel.fullText)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            ShareLink(item: viewModel.fullText) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .padding()
        .background(.bar)
    }

    private func transcriptRow(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(segment.formattedStart)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            if let speaker = segment.speaker {
                speakerTag(speaker)
            }
            Text(segment.text.trimmingCharacters(in: .whitespaces))
        }
    }

    /// A small colored label: the first source (the microphone when enabled) uses the accent color, others orange.
    private func speakerTag(_ speaker: String) -> some View {
        let color: Color = speaker == viewModel.channels.first?.label ? .accentColor : .orange
        return Text(speaker)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 4: Build both platforms.**

Run: `xcodebuild build -scheme "Audio Transcribe" -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD" ; xcodebuild build -scheme "Audio Transcribe" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **` twice.

- [ ] **Step 5: Manual check on macOS.** Run the app (⌘R in Xcode, or the `run` skill) and check:
  - The mic menu lists input devices. "System Default (…)" is selected.
  - Plugging in a USB mic adds it to the menu without restarting the app.
  - With a video playing in Chrome, the system-audio menu lists "Google Chrome" with its icon and never lists "Audio Transcribe".
  - Mic + Chrome shows **You** and **Google Chrome** labels, interleaved by time.
  - Mic only shows no labels.
  - Clear is hidden while recording.
  - With both toggles off, Start is disabled.
  - Review Focus #1: while recording with a USB or Bluetooth mic, switching the output device keeps transcription running, and unplugging the mic shows the disconnect warning.

- [ ] **Step 6: Commit.**

```bash
git add "Audio Transcribe/AudioSourceCatalog.swift" "Audio Transcribe/LiveSourcesView.swift" "Audio Transcribe/ContentView.swift"
git commit -m "Add microphone and system audio source selection to the UI

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015fuauoR6c8DfMT23Xcmsce"
```

---

### Task 9: Export UI and read-write file access

**Files:**
- Create: `Audio Transcribe/PlainTextDocument.swift`
- Modify: `Audio Transcribe/TranscriptionViewModel.swift` (add `export(_:toFolder:date:)`)
- Modify: `Audio Transcribe/ContentView.swift` (state, importer, `transcriptActions`)
- Modify: `Audio Transcribe.xcodeproj/project.pbxproj`: `ENABLE_USER_SELECTED_FILES = readonly;` becomes `readwrite;`, twice (Debug and Release)
- Test: `Audio TranscribeTests/TranscriptionViewModelTests.swift` (append)

**Interfaces:**
- Consumes:
  - `TranscriptionViewModel.exportFiles(_:baseName:)` and `hasSeparateSources` (Task 7)
  - `TranscriptExporter.write(_:to:)`, `defaultBaseName(for:)`, `ExportKind` (Task 2)
- Produces:
  - `nonisolated struct PlainTextDocument: FileDocument`
  - `TranscriptionViewModel.export(_ kind: ExportKind, toFolder folder: URL, date: Date = Date())`

- [ ] **Step 1: Write the failing test.** Append inside `struct TranscriptionViewModelTests` in `Audio TranscribeTests/TranscriptionViewModelTests.swift`:

```swift
    @Test func exportToFolderWritesSeparateFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 14, minute: 5)))

        let viewModel = TranscriptionViewModel()
        viewModel.channels = [
            makeIdleChannel(.microphone, label: "You", segments: [TranscriptSegment(start: 0, end: 1, text: " Hello.", speaker: "You")]),
            makeIdleChannel(.systemAudio, label: "Zoom", segments: [TranscriptSegment(start: 2, end: 3, text: " Hi.", speaker: "Zoom")]),
        ]
        viewModel.export(.separate, toFolder: folder, date: date)

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        #expect(names == ["Transcript 2026-09-27 14.05-You.txt", "Transcript 2026-09-27 14.05-Zoom.txt"])
        #expect(viewModel.status == .idle)
    }

    @Test func exportFailureIsReported() {
        let viewModel = TranscriptionViewModel()
        viewModel.channels = [makeIdleChannel(.microphone, label: "You", segments: [TranscriptSegment(start: 0, end: 1, text: "Hi")])]
        viewModel.export(.combined, toFolder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        guard case .failed = viewModel.status else {
            Issue.record("Expected a failed status, got \(viewModel.status)")
            return
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/TranscriptionViewModelTests" 2>&1 | tail -20`
Expected: FAIL with "value of type 'TranscriptionViewModel' has no member 'export'".

- [ ] **Step 3: Implement `export`.** In `Audio Transcribe/TranscriptionViewModel.swift`, add after `exportFiles(_:baseName:)`:

```swift
    /// Writes the export files for `kind` into a folder the user picked. Existing files are never overwritten.
    func export(_ kind: ExportKind, toFolder folder: URL, date: Date = Date()) {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        do {
            _ = try TranscriptExporter.write(
                exportFiles(kind, baseName: TranscriptExporter.defaultBaseName(for: date)),
                to: folder
            )
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/TranscriptionViewModelTests" 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Add the document type.** Create `Audio Transcribe/PlainTextDocument.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

/// A UTF-8 plain-text file for `fileExporter`.
nonisolated struct PlainTextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
```

- [ ] **Step 6: Wire export into `ContentView`.** In `Audio Transcribe/ContentView.swift`, make these changes. A view can have only one working `fileImporter`, so the audio-file picker and the export-folder picker share one importer with a purpose.

Add inside `ContentView`, above `@State private var viewModel`:

```swift
    private enum ImportPurpose {
        case audioFile
        case exportFolder(ExportKind)

        var contentTypes: [UTType] {
            switch self {
            case .audioFile: [.audio, .movie]
            case .exportFolder: [.folder]
            }
        }
    }
```

Replace `@State private var isImportingFile = false` with:

```swift
    @State private var isImporting = false
    @State private var importPurpose = ImportPurpose.audioFile
    @State private var isExportingFile = false
    @State private var exportDocument = PlainTextDocument(text: "")
    @State private var exportFileName = ""
```

Replace the `.fileImporter(...) { ... }` modifier in `body` with:

```swift
        .fileImporter(isPresented: $isImporting, allowedContentTypes: importPurpose.contentTypes) { result in
            guard case .success(let url) = result else { return }
            switch importPurpose {
            case .audioFile:
                Task { await viewModel.transcribe(fileURL: url) }
            case .exportFolder(let kind):
                viewModel.export(kind, toFolder: url)
            }
        }
        .fileExporter(
            isPresented: $isExportingFile,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportFileName
        ) { result in
            if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                viewModel.status = .failed(error.localizedDescription)
            }
        }
```

In `actionButton`'s `.file` case, replace `isImportingFile = true` with:

```swift
                importPurpose = .audioFile
                isImporting = true
```

In `transcriptActions`, insert before `Button { copyToClipboard(viewModel.fullText) }`:

```swift
            if !viewModel.isRecording {
                exportControl
            }
```

Add these members to `ContentView`, after `transcriptActions`:

```swift
    @ViewBuilder
    private var exportControl: some View {
        if viewModel.hasSeparateSources {
            Menu {
                Button("Combined…") { exportCombinedFile() }
                Button("Separate…") { chooseExportFolder(for: .separate) }
                Button("Combined + Separate…") { chooseExportFolder(for: .combinedAndSeparate) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .fixedSize()
        } else {
            Button {
                exportCombinedFile()
            } label: {
                Label("Export…", systemImage: "square.and.arrow.down")
            }
        }
    }

    private func exportCombinedFile() {
        let baseName = TranscriptExporter.defaultBaseName(for: Date())
        guard let file = viewModel.exportFiles(.combined, baseName: baseName).first else { return }
        exportDocument = PlainTextDocument(text: file.text)
        exportFileName = (file.name as NSString).deletingPathExtension
        isExportingFile = true
    }

    private func chooseExportFolder(for kind: ExportKind) {
        importPurpose = .exportFolder(kind)
        isImporting = true
    }
```

- [ ] **Step 7: Allow writing to user-selected locations.**

Run: `sed -i '' 's/ENABLE_USER_SELECTED_FILES = readonly;/ENABLE_USER_SELECTED_FILES = readwrite;/' "Audio Transcribe.xcodeproj/project.pbxproj" && grep -c "ENABLE_USER_SELECTED_FILES = readwrite;" "Audio Transcribe.xcodeproj/project.pbxproj"`
Expected: `2`

- [ ] **Step 8: Run all tests and build iOS.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' 2>&1 | tail -30 ; xcodebuild build -scheme "Audio Transcribe" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"`
Expected: `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Manual check on macOS.**
  - After a mic + app session:
    - Export › Combined… saves one labeled `.txt`.
    - Separate… into a folder writes `…-You.txt` and `…-<App>.txt`.
    - Repeating Separate… into the same folder writes `… 2.txt` files and leaves the first ones untouched.
  - After a file transcription, Export… saves one file with timestamps and no labels.
  - Cancelling any dialog shows no error.

- [ ] **Step 10: Commit.**

```bash
git add "Audio Transcribe/PlainTextDocument.swift" "Audio Transcribe/TranscriptionViewModel.swift" "Audio Transcribe/ContentView.swift" "Audio Transcribe.xcodeproj/project.pbxproj" "Audio TranscribeTests/TranscriptionViewModelTests.swift"
git commit -m "Export transcripts as combined or per-source text files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015fuauoR6c8DfMT23Xcmsce"
```

---

### Task 10: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the Features list.** In `README.md`, replace the Microphone, System audio, and Output bullets under `## Features` with:

```markdown
- **Microphone**: live transcription. The in-progress text is shown dimmed until it becomes final. On macOS you can choose the input device.
- **System audio (macOS only)**: transcribes everything the Mac is playing, or just one app (for example Zoom or Chrome). It captures audio with a Core Audio process tap.
- **Microphone + system audio together (macOS only)**: each source gets its own transcriber, and the transcript labels each line **You** or with the app's name, in time order. This works well for calls: use headphones, otherwise the microphone also hears the other participants.
- **Output**: Copy or Share the transcript as plain text, or Export it as `.txt`. Multi-source transcripts can be exported as one combined file, one file per source, or both.
```

- [ ] **Step 2: Update the entitlements list.** Replace `- \`com.apple.security.files.user-selected.read-only\`` with `- \`com.apple.security.files.user-selected.read-write\` (to open audio files and save exports)`.

- [ ] **Step 3: Update the project structure table.** Replace the rows for `MicrophoneSource.swift`, `SystemAudioSource.swift`, `TranscriptionViewModel.swift`, `TranscriptSegment.swift`, and `ContentView.swift`, and add the new files, so the table body reads:

```markdown
| `TranscriptionEngine.swift` | An actor that wraps `SpeechAnalyzer` / `SpeechTranscriber`. It installs model assets (`AssetInventory`) and runs both live streaming transcription and one-shot file transcription. |
| `LiveChannel.swift` | One live source plus its own `TranscriptionEngine`. It stores segments on the session timeline and reports when its source stops by itself. |
| `MicrophoneSource.swift` | Captures microphone audio with `AVAudioEngine`. On macOS it records from a chosen input device and survives output-device changes; on iOS and visionOS it configures `AVAudioSession`. |
| `SystemAudioSource.swift` | macOS only. Captures all system audio or one app's audio (`SystemAudioTarget`) through a Core Audio process tap and a private aggregate device. |
| `AudioInputDevices.swift`, `AudioApps.swift`, `CoreAudioProperty.swift` | macOS only. List input devices and audio apps (helper processes are grouped under their app) with Core Audio. |
| `AudioSourceCatalog.swift` | macOS only. Keeps the device and app lists current for the source menus. |
| `TranscriptionViewModel.swift` | An `@Observable` `@MainActor` view model that coordinates mode, sources, language, status, and the merged transcript. |
| `TranscriptSegment.swift` | One finalized transcript line (text, start and end times, optional speaker), plus merging of several sources by time. |
| `TranscriptExporter.swift` | Formats combined and per-source `.txt` exports and writes them without overwriting existing files. |
| `ContentView.swift`, `LiveSourcesView.swift`, `PlainTextDocument.swift` | The UI: Live/File mode, source rows, language, Start/Stop or Open File…, status bar, labeled transcript, and Copy/Share/Export. |
```

- [ ] **Step 4: Update Known limitations.** Append to `## Known limitations`:

```markdown
- Echo is not cancelled. When you record the microphone and system audio together through speakers, the microphone also picks up the other participants, so their words can appear twice. Use headphones.
- Some apps play audio from a helper process that isn't named after the app. Safari's audio comes from "Safari Graphics and Media", which is listed only while it is playing.
- Devices and targets can't be changed during a recording.
```

- [ ] **Step 5: Final verification.**

Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`

Then repeat the Task 8 Step 5 and Task 9 Step 9 manual checks once on the finished build. That includes Review Focus #1: switching the output device mid-recording keeps the mic channel running.

- [ ] **Step 6: Commit.**

```bash
git add README.md
git commit -m "Document source selection, simultaneous capture, and export

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015fuauoR6c8DfMT23Xcmsce"
```
