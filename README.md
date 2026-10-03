# Audio Transcribe

A SwiftUI app that transcribes speech on-device with Apple's Speech framework (`SpeechAnalyzer` + `SpeechTranscriber`). It can transcribe from the microphone, from everything your Mac is playing, or from audio and video files. It supports English and Japanese.

Transcription runs locally: the audio never leaves the device.

## Features

- **Microphone**: live transcription. The in-progress text is shown dimmed until it becomes final. On macOS you can choose the input device.
- **System audio (macOS only)**: transcribes everything the Mac is playing, or just one app (for example Zoom or Chrome). It captures audio with a Core Audio process tap.
- **Microphone + system audio together (macOS only)**: each source gets its own transcriber, and the transcript labels each line **You** or with the app's name, in time order. This works well for calls: use headphones, otherwise the microphone also hears the other participants.
- **Files**: transcribes audio or video files (`.m4a`, `.mp3`, `.wav`, `.mp4`, `.mov`, …) and shows timestamps.
- **Languages**: English (`en-US`) and Japanese (`ja-JP`).
- **Output**: Copy or Share the transcript as plain text, or Export it as `.txt`. Multi-source transcripts can be exported as one combined file, one file per source, or both.
- **Model download**: the on-device language models download on first use, with a progress bar.

| Source       | macOS | iOS / iPadOS | visionOS |
|--------------|:-----:|:------------:|:--------:|
| Microphone   | ✓     | ✓            | ✓        |
| System audio | ✓     | —            | —        |
| File         | ✓     | ✓            | ✓        |

System audio needs Core Audio process taps, which exist only on macOS. It is compiled out (`#if os(macOS)`) on the other platforms, where Live mode shows only the Microphone row.

## Requirements

- Xcode 27 or later
- macOS / iOS / iPadOS / visionOS 27.0 or later
- Hardware that supports the on-device Speech models. On unsupported devices, or where a language isn't available, the app shows an error. The iOS Simulator doesn't provide the models.

## Getting started

1. Open `Audio Transcribe.xcodeproj`.
2. Choose your development team under **Signing & Capabilities** for the `Audio Transcribe` target.
3. Select the **Audio Transcribe** scheme and a destination (e.g. *My Mac*), then run (⌘R).

The first time you use each source, the system asks for permission:

- **Microphone**: uses `NSMicrophoneUsageDescription`.
- **System audio**: uses `NSAudioCaptureUsageDescription`. You can change this later in System Settings › Privacy & Security.

The app runs in the App Sandbox with these entitlements:

- `com.apple.security.device.audio-input`
- `com.apple.security.files.user-selected.read-write` (to open audio files and save exports)

## Tests

Unit tests use Swift Testing and live in the `Audio TranscribeTests` target. Run them with ⌘U, or from the command line:

```sh
xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS'
```

`TranscriptionEngineTests` runs the real transcriber on short English and Japanese clips in `Audio TranscribeTests/Fixtures/`:

- It is skipped automatically where the Speech models are unavailable, such as the iOS Simulator.
- The first run may download the language models.

## Project structure

| File | Role |
|------|------|
| `TranscriptionEngine.swift` | An actor that wraps `SpeechAnalyzer` / `SpeechTranscriber`. It installs model assets (`AssetInventory`) and runs both live streaming transcription and one-shot file transcription. |
| `LiveChannel.swift` | One live source plus its own `TranscriptionEngine`. It stores segments on the session timeline and reports when its source stops by itself. |
| `MicrophoneSource.swift` | Captures microphone audio with `AVAudioEngine`. On macOS it records from a chosen input device and survives output-device changes; on iOS and visionOS it configures `AVAudioSession`. |
| `SystemAudioTarget.swift` | What system audio to capture: all audio or one app. |
| `SystemAudioSource.swift` | macOS only. Captures all system audio or one app's audio (`SystemAudioTarget`) through a Core Audio process tap and a private aggregate device. For one app, it adds the app's helper processes that start during the recording to the tap. |
| `AudioInputDevices.swift`, `AudioApps.swift`, `CoreAudioProperty.swift` | macOS only. List input devices and audio apps (helper processes are grouped under their app) with Core Audio. |
| `AudioSourceCatalog.swift` | macOS only. Keeps the device and app lists current for the source menus. |
| `TranscriptionViewModel.swift` | An `@Observable` `@MainActor` view model that coordinates mode, sources, language, status, and the merged transcript. |
| `TranscriptSegment.swift` | One finalized transcript line (text, start and end times, optional speaker), plus merging of several sources by time. |
| `TranscriptExporter.swift` | Formats combined and per-source `.txt` exports and writes them without overwriting existing files. |
| `ContentView.swift`, `LiveSourcesView.swift`, `PlainTextDocument.swift` | The UI: Live/File mode, source rows, language, Start/Stop or Open File…, status bar, labeled transcript, and Copy/Share/Export. |

For live sources, captured buffers are converted to the analyzer's preferred format with `AnalyzerInputConverter` and streamed into the analyzer through `SpeechTranscriber`'s `.progressiveTranscription` preset. Files use the `.transcription` preset and are analyzed directly from an `AVAudioFile`.

The target builds with Swift 5 language mode and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so types are main-actor isolated unless marked otherwise. Types used from the engine actor or on audio threads are explicitly `nonisolated` or `@Sendable`.

## Known limitations

- `AVAudioNode.installTap(onBus:bufferSize:format:block:)` is deprecated in the 27.0 SDKs. The replacement doesn't have a public Swift API yet, so the build shows one deprecation warning.
- Language availability depends on the device. The app checks `SpeechTranscriber.supportedLocales` at runtime.
- Echo is not cancelled. When you record the microphone and system audio together through speakers, the microphone also picks up the other participants, so their words can appear twice. Use headphones.
- Some apps play audio from a helper process that isn't named after the app. Safari's audio comes from "Safari Graphics and Media", which is listed only while it is playing.
- Devices and targets can't be changed during a recording.
