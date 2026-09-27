# Multi-source capture: source selection and simultaneous mic + system audio

Date: 2026-09-27
Status: Draft, awaiting review

## Goal

Make Audio Transcribe useful for calls and meetings on macOS:

1. **Source selection.** Choose the microphone input device, and choose the system-audio target: all system audio, or one specific app.
2. **Simultaneous transcription.** Transcribe the microphone ("You") and system/app audio (the remote participants) at the same time, and export the result as one combined, speaker-labeled transcript, as separate per-source transcripts, or both.

### Success criteria

- During a Zoom/Meet/Teams call with headphones, the user checks Microphone and System audio → Zoom, presses Start, and sees one live transcript whose lines are labeled **You** and **Zoom** in time order.
- After stopping, the user can export `… .txt` (combined), `…-You.txt` + `…-Zoom.txt` (separate), or all three.
- Mic-only and system-audio-only sessions still work, and they look like today's app (no labels).
- File transcription is unchanged, apart from gaining Export.

### Non-goals

- Echo cancellation. With speakers instead of headphones, remote speech can appear twice. The README recommends headphones.
- Selecting several apps, or excluding apps, from system audio.
- Changing devices or targets during a recording.
- A different language per source.
- Auto-saving while recording.
- Input-device selection on iOS / visionOS. Those platforms keep the default input, and the system-audio row is hidden as it is today.

## Approach

One `TranscriptionEngine`, with its own `SpeechAnalyzer`, per active source ("channel"). The view model merges the channels' segments by time. Mixing the sources into one analyzer was rejected: it can't produce separate transcripts or speaker labels. A single engine that multiplexes two analyzers was also rejected: it adds session management to the engine actor for no benefit.

## UI (macOS)

The top segmented picker becomes **Live | File**. File mode is today's UI. Live mode shows:

```
[✓] Microphone     [ MacBook Pro Microphone      ▾ ]
[✓] System audio   [ All system audio            ▾ ]
                     ├ All system audio
                     ├ ──────────
                     ├ Zoom
                     └ Google Chrome   (with app icons)
Language  [ English | 日本語 ]
[ ● Start ]
```

- Each row has a toggle and a menu. **Start** is enabled only when at least one row is on.
- **Mic menu**: every input device, with the system default marked "(Default)". The initial selection is the default device.
- **App menu**: "All system audio", a divider, then the apps that are currently Core Audio clients, sorted by name. The list refreshes each time the menu opens. It never includes Audio Transcribe itself.
- The rows, menus, and language picker are disabled while recording.
- **Live transcript**:
  - With two active channels, one time-ordered list. Each row shows `MM:SS`, a small colored label ("You" / app name), and the text. Each channel's in-progress text appears dimmed at the bottom, prefixed with its label.
  - With one active channel, no labels, as today.
- **iOS / visionOS**: Live mode shows only the Microphone row, with no device menu. The toggle is always on.

## Components

### Capture layer

**`AudioInputDevices`** (macOS)
- `nonisolated struct AudioInputDevice: Identifiable, Hashable, Sendable { id: AudioDeviceID; uid: String; name: String }`
- `static func all() -> [AudioInputDevice]` reads `kAudioHardwarePropertyDevices` and keeps devices that have streams in the input scope.
- `static func defaultDeviceID() -> AudioDeviceID?` reads `kAudioHardwarePropertyDefaultInputDevice`.
- The view model stores the selection by `uid`. At start, the uid is resolved to an ID; if the device is gone, the default is used.

**`MicrophoneSource.start(deviceID: AudioDeviceID?)`**
- On macOS, when `deviceID` is non-nil, it sets `kAudioOutputUnitProperty_CurrentDevice` on `engine.inputNode.audioUnit` before reading the input format and installing the tap.
- On other platforms the parameter is ignored.
- It observes `AVAudioEngineConfigurationChange`. When a notification arrives mid-session, it finishes its buffer stream, which ends that channel (see Error handling).

**`AudioApps`** (macOS)
- `nonisolated struct AudioApp: Identifiable, Hashable, Sendable { id: String /* bundle ID */; name: String }`. Icons are looked up in the view through `NSWorkspace` from the bundle ID.
- `static func running() -> [AudioApp]`:
  1. Reads `kAudioHardwarePropertyProcessObjectList`.
  2. For each process object, reads `kAudioProcessPropertyPID` and `kAudioProcessPropertyBundleID`.
  3. Resolves each process to its owning app and groups by that app's bundle ID.
- `static func processObjectIDs(for bundleID: String) -> [AudioObjectID]` returns the current process objects owned by that app, helpers included.
- **Grouping** is a pure function: `static func group(_ processes: [AudioProcessInfo], ownBundleID: String) -> [AudioApp]`, where `AudioProcessInfo` holds pid, bundleID, and the owning app's bundle ID and name.
  - The owning app is found by walking the bundle ID's prefix. For example, `com.google.Chrome.helper` maps to the running app `com.google.Chrome`, looked up through `NSRunningApplication`.
  - When that lookup fails, the process's own bundle ID is used.
  - Processes owned by `ownBundleID` are dropped.
  - The pure function is what the tests exercise.

**`SystemAudioTarget`**: `nonisolated enum { case allAudio; case app(bundleID: String, name: String) }`.
- `SystemAudioSource.start(target:)` builds the tap description through a pure helper, `static func tapDescription(for target:, processObjectIDs:) -> CATapDescription`:
  - `.allAudio` uses `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, as today.
  - `.app` uses `CATapDescription(stereoMixdownOfProcesses: ids)`.
- The process IDs are resolved at start. If an `.app` target has no process objects, start throws `SystemAudioCaptureError.appNotRunning(name)`.

### Transcription layer

**`TranscriptionEngine`**: unchanged. One instance per channel.

**`LiveChannel`** (`@MainActor @Observable final class`)
- Properties:
  - `kind: ChannelKind` (`.microphone`, `.systemAudio`)
  - `label: String` ("You" for the mic; the app name, or "System audio" for all audio)
  - `timeOffset: TimeInterval`
  - `segments: [TranscriptSegment]`
  - `volatileText: String`
  - `endedUnexpectedly: Bool`
- `start(language:, sessionStart: Date, labelSegments: Bool) async throws`:
  1. Calls `engine.startLiveTranscription(language:)`.
  2. Starts its source.
  3. Sets `timeOffset = Date().timeIntervalSince(sessionStart)`.
  4. Launches the feed and results tasks, the same logic `TranscriptionViewModel.start()` has today.
  5. When `labelSegments` is true, each appended segment gets `speaker = label`.
- `stop() async throws` stops the source and calls `engine.finishLiveTranscription()`.
- The source is injected as a closure, `() throws -> AsyncStream<AVAudioPCMBuffer>`, plus a stop closure. The view model builds these from `MicrophoneSource` / `SystemAudioSource`, so `LiveChannel` has no platform conditionals.
- When the feed stream ends while the channel is still recording, the channel sets `endedUnexpectedly = true` and finishes its engine.

**`TranscriptSegment`** gains `speaker: String?`. It is `nil` in file mode and in single-channel sessions. Segment `start`/`end` hold session-relative times: the channel's offset is added when the segment is appended.

### Coordination: `TranscriptionViewModel`

- `mode: CaptureMode` (`.live`, `.file`) replaces `sourceKind`.
- Live settings: `micEnabled`, `selectedMicUID: String?`, `systemAudioEnabled`, `systemAudioTarget: SystemAudioTarget`.
- `canStart: Bool` is true when `micEnabled || systemAudioEnabled` and the model is not busy.
- `channels: [LiveChannel]`
- `start()`:
  1. Validates `canStart`.
  2. When the mic is enabled, requests record permission. On denial, fails the whole start.
  3. Calls `prepareAssets()` once.
  4. Sets `sessionStart = Date()`.
  5. Builds the enabled channels and starts them concurrently, passing `labelSegments: channels.count > 1`.
  6. If any channel throws, stops the ones already started, sets `.failed(message)`, and leaves `channels` empty.
- `stop()` stops all channels concurrently (task group) and sets `.idle`, or `.failed` with the first error.
- `mergedSegments: [TranscriptSegment]` concatenates all channels' segments and sorts stably by `start`, ties keeping channel order (mic first). In file mode it returns the file segments.
- `volatileLines: [(label: String?, text: String)]` holds the non-empty `volatileText` per channel.
- `fullText` (Copy/Share):
  - Single-channel and file transcripts are unchanged: segments joined as-is.
  - Multi-channel transcripts use one line per segment, `Label: text`, with the text trimmed.
- `channelWarning: String?` is set when a channel ends unexpectedly, for example "Microphone disconnected; system audio is still being transcribed."

### Export: `TranscriptExporter`

A pure `nonisolated enum`.
- `static func combined(_ segments: [TranscriptSegment]) -> String`: one line per segment, `[MM:SS] Label: text` or `[MM:SS] text` when `speaker` is nil. The text is trimmed of surrounding whitespace, and lines are joined with `\n`.
- `static func separate(_ channels: [(label: String, segments: [TranscriptSegment])]) -> [(label: String, text: String)]`: each channel's lines as `[MM:SS] text`.
- `static func fileName(base: String, label: String?) -> String`: `"<base>.txt"` or `"<base>-<label>.txt"`. Filesystem-unsafe characters (`/`, `:`) in labels are replaced with `-`.
- `static func defaultBaseName(for date: Date) -> String` returns `"Transcript yyyy-MM-dd HH.mm"`.

**UI.** An **Export** menu sits next to Copy and Share, and appears when segments exist and nothing is recording:
- For single-channel and file transcripts, it offers one item, "Export…", which saves one combined-format file through `fileExporter` with `.plainText`.
- For multi-channel transcripts, it offers:
  - "Combined…", which uses `fileExporter`.
  - "Separate…" and "Combined + Separate…", which use `fileImporter` with `allowedContentTypes: [.folder]` to pick a folder, then write the files inside it through security-scoped access. An existing name gets ` 2`, ` 3`, … appended.
- Entitlement: `com.apple.security.files.user-selected.read-only` becomes `read-write`.

## Error handling

| Situation | Behavior |
|---|---|
| Neither source enabled | Start is disabled. |
| Mic permission denied, with any combination of sources | Start fails with "Microphone access was denied." Nothing records. |
| System-audio capture permission denied, or tap creation fails | Start fails with the existing `SystemAudioCaptureError` message. Channels already started are stopped. |
| Selected app not running at start | Start fails with "<App> isn't running." |
| Selected app quits mid-session | The tap goes silent and the session continues. |
| Selected mic uid not found at start | The system default input is used silently. |
| Mic device disconnects mid-session | The mic channel ends, `channelWarning` shows in the status bar, and the other channel continues. When the last channel ends, the status goes to `.idle`. |
| Export write fails | The status shows `.failed(error.localizedDescription)`. The transcript is kept. |

## Testing (Swift Testing, TDD)

- **`TranscriptExporter`**:
  - Combined line format, with and without labels.
  - Trimming of English leading spaces, and Japanese text without spaces.
  - Separate output per channel.
  - File-name sanitizing.
  - Default base-name formatting with a fixed date.
- **Merging** (view model or a small pure helper):
  - Interleaving by time across channels with offsets applied.
  - Stable ordering on ties.
  - `speaker` set only for multi-channel sessions.
  - Multi-channel `fullText` format.
- **`AudioApps.group`**:
  - Helpers grouped under their parent app.
  - Own app excluded.
  - Fallback to the process's own bundle ID.
  - Output sorted by name.
- **`SystemAudioSource.tapDescription(for:processObjectIDs:)`**: the global tap for `.allAudio`, and the mixdown of the given IDs for `.app`.
- **View model**:
  - `canStart` for each toggle combination.
  - Mode switch preserves settings.
- **Existing tests** are updated for the `sourceKind` → `mode` rename.
- **Manual check** on macOS:
  - A real call with headphones, mic + app target: labels, live view, and all three export options.
  - Mic only and all system audio only: no labels.
  - Unplugging a USB mic mid-session.
  - File mode export.

## Documentation

Update the README:
- Features, source table, and project-structure table for the new files.
- The entitlement change.
- A headphones note under Known limitations.
