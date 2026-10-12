# Recap Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While recording live, summarize the conversation every 5, 10 or 15 minutes with Apple Intelligence's on-device model, and append each recap to a dedicated Recap side panel.

**Architecture:** `RecapScheduler` (`@Observable`) decides when a recap is due and which segments it covers, tracking coverage by segment ID. It calls a `RecapGenerating` protocol. `SystemRecapGenerator` implements it with a fresh `LanguageModelSession` per call and chunks large windows. `TranscriptionViewModel` owns the scheduler, drives it with a 30-second ticker while recording, and runs a final recap on Stop. `RecapView` renders it in a SwiftUI `.inspector`.

**Tech Stack:** Swift 5 mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (app and test targets), SwiftUI, Observation, FoundationModels, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-12-recap-mode-design.md`. Mockups: https://claude.ai/artifact/Ns3Rsgfk5pEhAXJoqP4b4k

## Global Constraints

- Deployment targets: macOS 26.0; iOS, iPadOS and visionOS 27.0. FoundationModels exists on all of them, so it needs no `#available` check to import. The only `#available` check is for `LanguageModelError` (macOS/iOS/visionOS 27).
- The project uses file-system-synchronized groups. A new `.swift` file in `Audio Transcribe/` or `Audio TranscribeTests/` is picked up automatically. **Do not edit `project.pbxproj`.**
- Everything is main-actor isolated by default. Types used off the main actor must be marked `nonisolated` (as `TranscriptionLanguage` is). `@Generable` structs are marked `nonisolated`.
- Interval presets: **5, 10, 15 minutes; default 10.**
- Content: `summary` (1–3 sentences) plus `keyPoints` (**at most 6**).
- Minimum window: **30 words** (English, split on whitespace) or **60 non-whitespace characters** (Japanese).
- Chunk budget: **6,000 characters (English), 2,500 (Japanese)**. Context-overflow halving stops below **500 characters**.
- Ticker period: **30 seconds**.
- Recaps never change `TranscriptionViewModel.status`.
- UI copy (verbatim): "Recap", "Every N min", "Summarize every", "N minutes", "Applies from the next recap.", "Summarizing MM:SS – MM:SS…", "On-device · Apple Intelligence", "FINAL", "Couldn't summarize this part.", "Retry", "First recap at about MM:SS", "N recaps", "Next recap around MM:SS", "Session ended · N recaps", "Open System Settings…".
- Run all commands from the repo root: `/Users/takahiko/repo/Audio Transcribe`.
- Test command shape: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/<Suite>"`. Expect `** TEST SUCCEEDED **` or `** TEST FAILED **` at the end.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

### Deviations from the spec (made while planning)

- `RecapGenerating` is main-actor isolated (the module default) instead of `Sendable`. The scheduler and the fake both live on the main actor, so `Sendable` would add nothing.
- The context-overflow check covers both the macOS 26 error (`LanguageModelSession.GenerationError.exceededContextWindowSize`) and the 27 error (`LanguageModelError.contextSizeExceeded`).
- The window has no `NavigationStack`, so a `.toolbar` button wouldn't appear on iOS. The Recap toggle is a button in the controls row next to Start/Stop on every platform.
- "Open System Settings…" is shown on macOS only. iOS has no public URL for the Apple Intelligence settings page.
- `finish` ignores a call that started before a `reset` or `clear`. Without this, pressing Start during the previous session's final recap would mark the new session as ended (see Review Focus).

## Review Focus

1. **Start pressed while the previous session's final recap is still generating.** The new session must start empty and not "ended", and the stale final recap must not appear in it. → test `resetDuringFinishDropsTheFinalRecap` (Task 3).
2. **Long quiet stretches.** Several short windows in a row must carry their text forward until enough has accumulated, then be recapped together. No text is lost. → test `shortWindowsCarryOverUntilThereIsEnough` (Task 3).
3. **Retry after newer recaps exist.** The retried entry stays in its original position and gets the summary from *before* it as `earlier`, not the latest one. → test `retryReplacesTheFailedEntryInPlace` (Task 3).
4. **Clear while a recap is generating.** No entry appears after the clear, and the panel isn't stuck on "Summarizing…". → test `clearDropsTheInFlightRecap` (Task 3).
5. **One enormous line**, such as a single long system-audio segment with no breaks. Chunking must make progress (truncate) instead of looping or overflowing. → tests `chunksTruncateAnOversizedLine` and `chunksIsolateAnOversizedLineBetweenShortOnes` (Task 2).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Audio Transcribe/TranscriptSegment.swift` | Modify | Add `static func formatted(_:)` (time as `MM:SS`) and `static func lines(_:)` (`Speaker: text`). |
| `Audio Transcribe/Recap.swift` | Create | `RecapContent` (`@Generable`), `RecapEntry`, `RecapInterval`, `RecapAvailability`. |
| `Audio Transcribe/RecapGenerator.swift` | Create | `RecapGenerating` protocol, `SystemRecapGenerator`, `RecapErrors`. |
| `Audio Transcribe/RecapScheduler.swift` | Create | When to recap, which segments, entries, retry, finish. |
| `Audio Transcribe/RecapView.swift` | Create | The panel UI. |
| `Audio Transcribe/Pasteboard.swift` | Create | The copy-to-clipboard helper, moved out of `ContentView`. |
| `Audio Transcribe/TranscriptionViewModel.swift` | Modify | Own the scheduler, ticker, finish on Stop/end, clear, retry. |
| `Audio Transcribe/ContentView.swift` | Modify | `.inspector` and the Recap toggle; use `Pasteboard`. |
| `Audio TranscribeTests/RecapTestDoubles.swift` | Create | `FakeRecapGenerator`, `FakeRecapError`, `speech(...)` helper. |
| `Audio TranscribeTests/RecapGeneratorTests.swift` | Create | Pure generator logic. |
| `Audio TranscribeTests/RecapModelTests.swift` | Create | Real-model tests (skipped when unavailable). |
| `Audio TranscribeTests/RecapSchedulerTests.swift` | Create | Scheduler behavior. |
| `Audio TranscribeTests/TranscriptModelTests.swift` | Modify | `formatted` and `lines`. |
| `Audio TranscribeTests/TranscriptionViewModelTests.swift` | Modify | Recap wiring. |
| `.github/workflows/tests.yml` | Modify | Skip `RecapModelTests` on CI. |
| `README.md` | Modify | Document the feature. |

---

### Task 1: Shared transcript formatting

**Files:**
- Modify: `Audio Transcribe/TranscriptSegment.swift`
- Modify: `Audio Transcribe/TranscriptionViewModel.swift` (`fullText`)
- Test: `Audio TranscribeTests/TranscriptModelTests.swift`

**Interfaces:**
- Produces: `TranscriptSegment.formatted(_ time: TimeInterval) -> String` (`"MM:SS"`, or `"--:--"` when the time isn't finite or is negative) and `TranscriptSegment.lines(_ segments: [TranscriptSegment]) -> [String]` (each trimmed text, prefixed with `"Speaker: "` when `speaker` is set).

- [ ] **Step 1: Write the failing tests.** Append to `Audio TranscribeTests/TranscriptModelTests.swift`:

```swift
struct TranscriptLinesTests {
    @Test(arguments: [(0.0, "00:00"), (605.0, "10:05"), (3725.0, "62:05"), (-1.0, "--:--"), (Double.nan, "--:--")])
    func formattedTime(seconds: TimeInterval, expected: String) {
        #expect(TranscriptSegment.formatted(seconds) == expected)
    }

    @Test func linesLabelSpeakersAndTrimText() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: " Hello. ", speaker: "You"),
            TranscriptSegment(start: 1, end: 2, text: " Hi.", speaker: "Zoom"),
        ]
        #expect(TranscriptSegment.lines(segments) == ["You: Hello.", "Zoom: Hi."])
    }

    @Test func linesWithoutSpeakersAreJustTheText() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: " The quick"),
            TranscriptSegment(start: 1, end: 2, text: "こんにちは。"),
        ]
        #expect(TranscriptSegment.lines(segments) == ["The quick", "こんにちは。"])
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail.**
Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/TranscriptLinesTests"`
Expected: build failure, "type 'TranscriptSegment' has no member 'formatted'".

- [ ] **Step 3: Implement.** In `Audio Transcribe/TranscriptSegment.swift`, replace `formattedStart` and add `lines` right after it:

```swift
    /// The segment's start time as `MM:SS`, with minutes continuing past 59 (e.g. `62:05`).
    var formattedStart: String { Self.formatted(start) }

    /// A session-timeline time as `MM:SS`, with minutes continuing past 59. `--:--` for invalid times.
    static func formatted(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "--:--" }
        let totalSeconds = Int(time)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    /// One line per segment: the trimmed text, prefixed with `Speaker: ` when the segment has a speaker.
    static func lines(_ segments: [TranscriptSegment]) -> [String] {
        segments.map { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return segment.speaker.map { "\($0): \(text)" } ?? text
        }
    }
```

In `Audio Transcribe/TranscriptionViewModel.swift`, in `fullText`, replace the body of `if segments.contains(where: { $0.speaker != nil }) { ... }` with:

```swift
            return TranscriptSegment.lines(segments).joined(separator: "\n")
```

- [ ] **Step 4: Run the tests and confirm they pass,** including the existing `fullText` tests.
Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/TranscriptLinesTests" -only-testing:"Audio TranscribeTests/TranscriptSegmentTests" -only-testing:"Audio TranscribeTests/TranscriptionViewModelTests"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
git add "Audio Transcribe/TranscriptSegment.swift" "Audio Transcribe/TranscriptionViewModel.swift" "Audio TranscribeTests/TranscriptModelTests.swift"
git commit -m "Share transcript line and time formatting

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Recap models and the on-device generator

**Files:**
- Create: `Audio Transcribe/Recap.swift`
- Create: `Audio Transcribe/RecapGenerator.swift`
- Create: `Audio TranscribeTests/RecapTestDoubles.swift`
- Create: `Audio TranscribeTests/RecapGeneratorTests.swift`
- Create: `Audio TranscribeTests/RecapModelTests.swift`
- Modify: `.github/workflows/tests.yml`

**Interfaces:**
- Consumes: `TranscriptSegment.formatted(_:)` (Task 1), `TranscriptionLanguage` (`.english`, `.japanese`).
- Produces:
  - `RecapContent(summary: String, keyPoints: [String])`, `Equatable`, with `var plainText: String`.
  - `RecapEntry { id: UUID; windowStart, windowEnd: TimeInterval; segmentIDs: [UUID]; isFinal: Bool; var state: State }`, where `State` is `.done(RecapContent)` or `.failed(message: String)`. Also `var content: RecapContent?`, `var formattedRange: String`, and `static func formattedRange(_ start: TimeInterval, _ end: TimeInterval) -> String`.
  - `RecapInterval` (`.five`, `.ten`, `.fifteen`), with `seconds: TimeInterval`, `menuLabel` ("10 minutes") and `shortLabel` ("Every 10 min").
  - `RecapAvailability` (`.available`, `.appleIntelligenceOff`, `.deviceNotEligible`, `.modelNotReady`), with `init(_ availability: SystemLanguageModel.Availability)` and `title: String?` / `message: String?` (nil when available).
  - `protocol RecapGenerating: AnyObject { var availability: RecapAvailability { get }; func recap(lines: [String], earlier: String?, language: TranscriptionLanguage) async throws -> RecapContent }`
  - `final class SystemRecapGenerator: RecapGenerating`, with the static functions `chunks(_:budget:)`, `budget(for:)`, `instructions(for:)`, `mergeInstructions(for:)`, `prompt(lines:earlier:)` and `mergePrompt(_:)`.
  - `enum RecapErrors { static func isContextOverflow(_:) -> Bool; static func message(for:) -> String }`.
  - Test doubles: `FakeRecapGenerator`, `FakeRecapError` ("Boom"), and `speech(_ words: Int, at start: TimeInterval, speaker: String? = nil) -> TranscriptSegment`.

- [ ] **Step 1: Write the test doubles.** Create `Audio TranscribeTests/RecapTestDoubles.swift`:

```swift
import Foundation
@testable import Audio_Transcribe

struct FakeRecapError: LocalizedError {
    var errorDescription: String? { "Boom" }
}

/// Records each call. Returns `results` in order, then `Summary N` / `["Point"]`.
/// With `holdsCalls`, each call waits until `releaseHeldCalls()`.
final class FakeRecapGenerator: RecapGenerating {
    struct Call {
        let lines: [String]
        let earlier: String?
        let language: TranscriptionLanguage
    }

    var availability: RecapAvailability = .available
    var results: [Result<RecapContent, Error>] = []
    var holdsCalls = false
    private(set) var calls: [Call] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    func recap(lines: [String], earlier: String?, language: TranscriptionLanguage) async throws -> RecapContent {
        calls.append(Call(lines: lines, earlier: earlier, language: language))
        let number = calls.count
        if holdsCalls {
            await withCheckedContinuation { held.append($0) }
        }
        let result = results.isEmpty
            ? .success(RecapContent(summary: "Summary \(number)", keyPoints: ["Point"]))
            : results.removeFirst()
        return try result.get()
    }

    func releaseHeldCalls() {
        let continuations = held
        held = []
        continuations.forEach { $0.resume() }
    }

    /// Waits until `count` calls have started, including ones still held.
    func waitForCalls(_ count: Int) async {
        while calls.count < count { await Task.yield() }
    }
}

/// A segment of `words` words starting at `start` and lasting 5 seconds.
func speech(_ words: Int, at start: TimeInterval, speaker: String? = nil) -> TranscriptSegment {
    TranscriptSegment(
        start: start,
        end: start + 5,
        text: Array(repeating: "word", count: words).joined(separator: " "),
        speaker: speaker
    )
}
```

- [ ] **Step 2: Write the failing tests.** Create `Audio TranscribeTests/RecapGeneratorTests.swift`:

```swift
import Foundation
import FoundationModels
import Testing
@testable import Audio_Transcribe

struct RecapGeneratorTests {
    @Test func chunksKeepLinesThatFitTogether() {
        // "aaaa\nbbbb" is exactly 9 characters.
        #expect(SystemRecapGenerator.chunks(["aaaa", "bbbb"], budget: 9) == [["aaaa", "bbbb"]])
    }

    @Test func chunksSplitOnLineBoundaries() {
        #expect(SystemRecapGenerator.chunks(["aaaa", "bbbb", "cc"], budget: 8) == [["aaaa"], ["bbbb", "cc"]])
    }

    @Test func chunksTruncateAnOversizedLine() {
        let line = String(repeating: "x", count: 10_000)
        #expect(SystemRecapGenerator.chunks([line], budget: 2_500) == [[String(repeating: "x", count: 2_500)]])
    }

    @Test func chunksIsolateAnOversizedLineBetweenShortOnes() {
        let long = String(repeating: "x", count: 20)
        #expect(SystemRecapGenerator.chunks(["a", long, "b"], budget: 10) == [["a"], [String(repeating: "x", count: 10)], ["b"]])
    }

    @Test func chunksOfNothingIsEmpty() {
        #expect(SystemRecapGenerator.chunks([], budget: 10).isEmpty)
    }

    @Test func budgetsPerLanguage() {
        #expect(SystemRecapGenerator.budget(for: .english) == 6_000)
        #expect(SystemRecapGenerator.budget(for: .japanese) == 2_500)
    }

    @Test func promptWithoutEarlierSummary() {
        #expect(SystemRecapGenerator.prompt(lines: ["You: Hi.", "Zoom: Hello."], earlier: nil)
            == "Transcript:\nYou: Hi.\nZoom: Hello.")
    }

    @Test func promptWithEarlierSummary() {
        #expect(SystemRecapGenerator.prompt(lines: ["You: Hi."], earlier: "They met.")
            == "Earlier: They met.\n\nTranscript:\nYou: Hi.")
    }

    @Test func instructionsNameTheResponseLanguage() {
        #expect(SystemRecapGenerator.instructions(for: .english).hasSuffix("Respond in English."))
        #expect(SystemRecapGenerator.instructions(for: .japanese).hasSuffix("Respond in Japanese."))
        #expect(SystemRecapGenerator.mergeInstructions(for: .japanese).hasSuffix("Respond in Japanese."))
    }

    @Test func mergePromptListsEachPart() {
        let parts = [
            RecapContent(summary: "A.", keyPoints: ["x"]),
            RecapContent(summary: "B.", keyPoints: []),
        ]
        #expect(SystemRecapGenerator.mergePrompt(parts) == "Part 1:\nA.\n- x\n\nPart 2:\nB.")
    }

    @Test(arguments: [
        (SystemLanguageModel.Availability.available, RecapAvailability.available),
        (.unavailable(.appleIntelligenceNotEnabled), .appleIntelligenceOff),
        (.unavailable(.deviceNotEligible), .deviceNotEligible),
        (.unavailable(.modelNotReady), .modelNotReady),
    ])
    func availabilityMapping(system: SystemLanguageModel.Availability, expected: RecapAvailability) {
        #expect(RecapAvailability(system) == expected)
    }

    @Test func onlyUnavailableStatesHaveMessages() {
        #expect(RecapAvailability.available.title == nil)
        #expect(RecapAvailability.appleIntelligenceOff.title == "Recaps need Apple Intelligence")
        #expect(RecapAvailability.modelNotReady.message == "The model is still downloading. Recaps will start when it's ready.")
    }

    @Test func otherErrorsUseTheirDescription() {
        #expect(!RecapErrors.isContextOverflow(FakeRecapError()))
        #expect(RecapErrors.message(for: FakeRecapError()) == "Boom")
    }

    @Test func plainTextListsKeyPoints() {
        #expect(RecapContent(summary: "S.", keyPoints: ["a", "b"]).plainText == "S.\n- a\n- b")
        #expect(RecapContent(summary: "S.", keyPoints: []).plainText == "S.")
    }

    @Test func entryRangeFormatting() {
        #expect(RecapEntry.formattedRange(0, 605) == "00:00 – 10:05")
    }

    @Test func intervalLabels() {
        #expect(RecapInterval.ten.seconds == 600)
        #expect(RecapInterval.five.menuLabel == "5 minutes")
        #expect(RecapInterval.fifteen.shortLabel == "Every 15 min")
    }
}
```

- [ ] **Step 3: Run the tests and confirm they fail.**
Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/RecapGeneratorTests"`
Expected: build failure, "cannot find type 'RecapContent' in scope".

- [ ] **Step 4: Create `Audio Transcribe/Recap.swift`.**

```swift
import Foundation
import FoundationModels

/// What the on-device model returns for one window of the conversation.
@Generable
nonisolated struct RecapContent: Equatable, Sendable {
    @Guide(description: "A summary of this part of the conversation in 1 to 3 sentences.")
    var summary: String
    @Guide(description: "Important names, numbers, dates, decisions and requests from this part.", .maximumCount(6))
    var keyPoints: [String]

    init(summary: String, keyPoints: [String]) {
        self.summary = summary
        self.keyPoints = keyPoints
    }

    /// The summary followed by one `- ` line per key point, for Copy.
    var plainText: String {
        ([summary] + keyPoints.map { "- \($0)" }).joined(separator: "\n")
    }
}

/// One recap in the panel. Entries are only appended, except that Retry replaces a failed entry's state.
struct RecapEntry: Identifiable, Equatable {
    enum State: Equatable {
        case done(RecapContent)
        case failed(message: String)
    }

    let id: UUID
    let windowStart: TimeInterval
    let windowEnd: TimeInterval
    /// The segments this entry covers, so Retry can rebuild the same window.
    let segmentIDs: [UUID]
    /// Made when the session ended (Stop, or the last source stopped).
    let isFinal: Bool
    var state: State

    var content: RecapContent? {
        if case .done(let content) = state { content } else { nil }
    }

    var formattedRange: String { Self.formattedRange(windowStart, windowEnd) }

    static func formattedRange(_ start: TimeInterval, _ end: TimeInterval) -> String {
        "\(TranscriptSegment.formatted(start)) – \(TranscriptSegment.formatted(end))"
    }
}

enum RecapInterval: Int, CaseIterable, Identifiable {
    case five = 5
    case ten = 10
    case fifteen = 15

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    var menuLabel: String { "\(rawValue) minutes" }
    var shortLabel: String { "Every \(rawValue) min" }
}

enum RecapAvailability: Equatable {
    case available
    case appleIntelligenceOff
    case deviceNotEligible
    case modelNotReady

    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: self = .appleIntelligenceOff
            case .deviceNotEligible: self = .deviceNotEligible
            case .modelNotReady: self = .modelNotReady
            @unknown default: self = .deviceNotEligible
            }
        }
    }

    var title: String? {
        switch self {
        case .available: nil
        case .appleIntelligenceOff: "Recaps need Apple Intelligence"
        case .deviceNotEligible: "Recaps aren't available on this device"
        case .modelNotReady: "Preparing Apple Intelligence"
        }
    }

    var message: String? {
        switch self {
        case .available: nil
        case .appleIntelligenceOff: "Turn on Apple Intelligence in System Settings to get on-device recaps. Transcription keeps working without it."
        case .deviceNotEligible: "This device doesn't support Apple Intelligence. Transcription keeps working without it."
        case .modelNotReady: "The model is still downloading. Recaps will start when it's ready."
        }
    }
}
```

> If `@Generable` rejects `nonisolated` or the explicit `init`, remove only the part the compiler names, and keep `RecapContent(summary:keyPoints:)` callable. The tests depend on that initializer.

- [ ] **Step 5: Create `Audio Transcribe/RecapGenerator.swift`.**

```swift
import Foundation
import FoundationModels

/// Makes one recap from transcript lines. The scheduler talks to this, so tests can swap in a fake.
protocol RecapGenerating: AnyObject {
    var availability: RecapAvailability { get }
    func recap(lines: [String], earlier: String?, language: TranscriptionLanguage) async throws -> RecapContent
}

/// Recaps with Apple Intelligence's on-device model. Each call uses fresh sessions, so context never builds up.
/// Windows over the language's character budget are recapped in chunks, then merged with one more call.
final class SystemRecapGenerator: RecapGenerating {
    static let minimumChunkCharacters = 500

    var availability: RecapAvailability {
        RecapAvailability(SystemLanguageModel.default.availability)
    }

    func recap(lines: [String], earlier: String?, language: TranscriptionLanguage) async throws -> RecapContent {
        try await recap(lines, budget: Self.budget(for: language), earlier: earlier, language: language)
    }

    private func recap(_ lines: [String], budget: Int, earlier: String?, language: TranscriptionLanguage) async throws -> RecapContent {
        var partials: [RecapContent] = []
        for chunk in Self.chunks(lines, budget: budget) {
            do {
                partials.append(try await respond(
                    instructions: Self.instructions(for: language),
                    prompt: Self.prompt(lines: chunk, earlier: earlier)
                ))
            } catch let error where RecapErrors.isContextOverflow(error) && budget / 2 >= Self.minimumChunkCharacters {
                partials.append(try await recap(chunk, budget: budget / 2, earlier: earlier, language: language))
            }
        }
        guard let first = partials.first else { throw EmptyTranscriptError() }
        if partials.count == 1 { return first }
        return try await respond(instructions: Self.mergeInstructions(for: language), prompt: Self.mergePrompt(partials))
    }

    private func respond(instructions: String, prompt: String) async throws -> RecapContent {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt, generating: RecapContent.self).content
    }

    // MARK: Pure helpers

    static func budget(for language: TranscriptionLanguage) -> Int {
        switch language {
        case .english: 6_000
        case .japanese: 2_500
        }
    }

    /// Packs whole lines into chunks whose newline-joined length is at most `budget`.
    /// A line longer than `budget` is truncated to it and gets a chunk of its own.
    static func chunks(_ lines: [String], budget: Int) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var size = 0
        for original in lines {
            let line = original.count > budget ? String(original.prefix(budget)) : original
            if !current.isEmpty, size + 1 + line.count > budget {
                result.append(current)
                current = []
                size = 0
            }
            size += current.isEmpty ? line.count : 1 + line.count
            current.append(line)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func instructions(for language: TranscriptionLanguage) -> String {
        "You summarize a live conversation transcript. Each line is \"Speaker: text\"; lines without a speaker come from a single source. "
            + "Write a summary of 1 to 3 sentences and up to 6 key points: important names, numbers, dates, decisions and requests. "
            + "Use only what is in the transcript. Respond in \(language.responseLanguageName)."
    }

    static func mergeInstructions(for language: TranscriptionLanguage) -> String {
        "You combine partial recaps of consecutive parts of one conversation into a single recap. "
            + "Write a summary of 1 to 3 sentences and up to 6 key points, keeping the most important names, numbers, dates, decisions and requests. "
            + "Respond in \(language.responseLanguageName)."
    }

    static func prompt(lines: [String], earlier: String?) -> String {
        var parts: [String] = []
        if let earlier {
            parts.append("Earlier: \(earlier)")
            parts.append("")
        }
        parts.append("Transcript:")
        parts.append(contentsOf: lines)
        return parts.joined(separator: "\n")
    }

    static func mergePrompt(_ partials: [RecapContent]) -> String {
        partials.enumerated()
            .map { index, partial in "Part \(index + 1):\n\(partial.plainText)" }
            .joined(separator: "\n\n")
    }
}

struct EmptyTranscriptError: LocalizedError {
    var errorDescription: String? { "There was nothing to summarize." }
}

enum RecapErrors {
    /// Whether the model ran out of context. macOS 26 reports `GenerationError`; 27 reports `LanguageModelError`.
    static func isContextOverflow(_ error: Error) -> Bool {
        if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *),
           let error = error as? LanguageModelError, case .contextSizeExceeded = error {
            return true
        }
        if let error = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = error {
            return true
        }
        return false
    }

    static func isGuardrailViolation(_ error: Error) -> Bool {
        if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *),
           let error = error as? LanguageModelError, case .guardrailViolation = error {
            return true
        }
        if let error = error as? LanguageModelSession.GenerationError, case .guardrailViolation = error {
            return true
        }
        return false
    }

    /// The reason shown after "Couldn't summarize this part."
    static func message(for error: Error) -> String {
        if isContextOverflow(error) { return "This part was too long to summarize." }
        if isGuardrailViolation(error) { return "The on-device model declined the request." }
        return error.localizedDescription
    }
}

extension TranscriptionLanguage {
    /// The language named in the model's instructions.
    nonisolated var responseLanguageName: String {
        switch self {
        case .english: "English"
        case .japanese: "Japanese"
        }
    }
}
```

> Building for iOS (target 27) shows deprecation warnings for the `GenerationError` cases. That's expected: those checks are needed for macOS 26.

- [ ] **Step 6: Run the tests and confirm they pass.**
Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/RecapGeneratorTests"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Add the real-model tests.** Create `Audio TranscribeTests/RecapModelTests.swift`:

```swift
import Foundation
import FoundationModels
import Testing
@testable import Audio_Transcribe

/// Runs the real on-device model. Skipped where Apple Intelligence isn't available, including GitHub's macOS VMs.
@Suite(.timeLimit(.minutes(2)))
struct RecapModelTests {
    static let english = [
        "You: Thanks for joining. We need to pick a ticketing vendor before December 31.",
        "Zoom: The shortlist is Northwind and Larkspur. Larkspur is about 18 percent cheaper.",
        "You: Larkspur only offers business-hours support, which is a problem for the Tokyo team.",
        "Zoom: I'll email Dana at Larkspur today to ask about an overnight support tier.",
        "You: Great. Let's aim for a rollout on February 3 if they say yes.",
    ]

    static let japanese = [
        "You: 本日はありがとうございます。12月31日までにチケット管理ツールを決める必要があります。",
        "Zoom: 候補はノースウィンドとラークスパーの二社です。ラークスパーの方が約18パーセント安いです。",
        "You: ただ、ラークスパーのサポートは平日日中のみで、東京チームには問題です。",
        "Zoom: 今日中にラークスパーの担当者に夜間サポートについて問い合わせます。",
        "You: よろしくお願いします。問題なければ2月3日の導入を目指しましょう。",
    ]

    @Test(.enabled("Apple Intelligence is available") { SystemLanguageModel.default.availability == .available })
    func recapsEnglish() async throws {
        let content = try await SystemRecapGenerator().recap(lines: Self.english, earlier: nil, language: .english)
        #expect(!content.summary.isEmpty)
        #expect(content.keyPoints.count <= 6)
    }

    @Test(.enabled("Apple Intelligence is available") { SystemLanguageModel.default.availability == .available })
    func recapsJapanese() async throws {
        let content = try await SystemRecapGenerator().recap(lines: Self.japanese, earlier: "They opened the vendor review.", language: .japanese)
        #expect(!content.summary.isEmpty)
        #expect(content.keyPoints.count <= 6)
        #expect(content.summary.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) })
    }
}
```

- [ ] **Step 8: Skip the real-model tests on CI.** In `.github/workflows/tests.yml`, replace the comment and `run` block of the "Unit tests" step with:

```yaml
      # TranscriptionEngineTests need the on-device Speech models and RecapModelTests need Apple Intelligence,
      # neither of which GitHub's macOS VMs support (both skip themselves there), so leave them to local runs.
      - name: Unit tests
        run: |
          xcodebuild test-without-building \
            -xctestrun Products/*.xctestrun \
            -destination 'platform=macOS' \
            -skip-testing:"Audio TranscribeTests/TranscriptionEngineTests" \
            -skip-testing:"Audio TranscribeTests/RecapModelTests"
```

- [ ] **Step 9: Run the real-model tests locally.**
Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/RecapModelTests"`
Expected: `** TEST SUCCEEDED **`. Both tests either pass, or are reported as skipped if Apple Intelligence is off on this Mac. Write down which happened.

- [ ] **Step 10: Commit.**

```bash
git add "Audio Transcribe/Recap.swift" "Audio Transcribe/RecapGenerator.swift" "Audio TranscribeTests/RecapTestDoubles.swift" "Audio TranscribeTests/RecapGeneratorTests.swift" "Audio TranscribeTests/RecapModelTests.swift" .github/workflows/tests.yml
git commit -m "Add recap models and the on-device recap generator

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: RecapScheduler

**Files:**
- Create: `Audio Transcribe/RecapScheduler.swift`
- Test: `Audio TranscribeTests/RecapSchedulerTests.swift`

**Interfaces:**
- Consumes: everything Task 2 produces, plus `TranscriptSegment.lines(_:)`.
- Produces: `@Observable final class RecapScheduler`:
  - `init(generator: any RecapGenerating)`
  - read-only: `entries: [RecapEntry]`, `generatingWindow: ClosedRange<TimeInterval>?`, `availability: RecapAvailability`, `hasEnded: Bool`, `lastRecapAt: TimeInterval`
  - computed: `isGenerating: Bool`, `nextRecapAt: TimeInterval?`
  - settable: `interval: RecapInterval`
  - methods: `reset(language:)`, `tick(now:segments:)`, `finish(segments:) async`, `retry(_ id: UUID, segments:)`, `clear()`, `waitForIdle() async`
  - `static func hasEnoughContent(_ window: [TranscriptSegment], language: TranscriptionLanguage) -> Bool`

- [ ] **Step 1: Write the failing tests.** Create `Audio TranscribeTests/RecapSchedulerTests.swift`:

```swift
import Foundation
import Testing
@testable import Audio_Transcribe

@Suite(.timeLimit(.minutes(1)))
struct RecapSchedulerTests {
    private func makeScheduler(_ generator: FakeRecapGenerator, language: TranscriptionLanguage = .english) -> RecapScheduler {
        let scheduler = RecapScheduler(generator: generator)
        scheduler.reset(language: language)
        return scheduler
    }

    @Test func noRecapBeforeTheInterval() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        scheduler.tick(now: 599, segments: [speech(40, at: 0)])
        await scheduler.waitForIdle()
        #expect(generator.calls.isEmpty)
        #expect(scheduler.entries.isEmpty)
        #expect(scheduler.nextRecapAt == 600)
    }

    @Test func recapAtTheIntervalCoversEverySegment() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let segments = [speech(20, at: 0, speaker: "You"), speech(20, at: 300, speaker: "Zoom")]

        scheduler.tick(now: 600, segments: segments)
        await scheduler.waitForIdle()

        #expect(generator.calls.count == 1)
        #expect(generator.calls[0].lines == TranscriptSegment.lines(segments))
        #expect(generator.calls[0].earlier == nil)
        #expect(generator.calls[0].language == .english)
        #expect(scheduler.entries.count == 1)
        let entry = scheduler.entries[0]
        #expect(entry.windowStart == 0)
        #expect(entry.windowEnd == 305)
        #expect(entry.segmentIDs == segments.map(\.id))
        #expect(!entry.isFinal)
        #expect(entry.content == RecapContent(summary: "Summary 1", keyPoints: ["Point"]))
        #expect(scheduler.lastRecapAt == 600)
        #expect(scheduler.nextRecapAt == 1200)
        #expect(!scheduler.isGenerating)
    }

    @Test func coveredSegmentsAreNotRecappedAgain() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await scheduler.waitForIdle()
        scheduler.tick(now: 1200, segments: [a, b])
        await scheduler.waitForIdle()

        #expect(generator.calls.map(\.lines) == [TranscriptSegment.lines([a]), TranscriptSegment.lines([b])])
    }

    @Test func lateSegmentGoesIntoTheNextWindowOnce() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let a = speech(20, at: 0, speaker: "You")
        let b = speech(20, at: 300, speaker: "You")
        scheduler.tick(now: 600, segments: [a, b])
        await scheduler.waitForIdle()

        // `late` finalized after the first recap but starts before `b` on the merged timeline.
        let late = speech(20, at: 290, speaker: "Zoom")
        let d = speech(20, at: 700, speaker: "You")
        scheduler.tick(now: 1200, segments: [a, late, b, d])
        await scheduler.waitForIdle()

        #expect(generator.calls[1].lines == TranscriptSegment.lines([late, d]))
        #expect(scheduler.entries[1].windowStart == 290)
        #expect(scheduler.entries[1].windowEnd == 705)
    }

    @Test func shortWindowsCarryOverUntilThereIsEnough() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let first = speech(10, at: 0)
        let second = speech(10, at: 700)
        let third = speech(10, at: 1300)

        scheduler.tick(now: 600, segments: [first])
        await scheduler.waitForIdle()
        #expect(generator.calls.isEmpty)
        #expect(scheduler.lastRecapAt == 600)

        scheduler.tick(now: 1200, segments: [first, second])
        await scheduler.waitForIdle()
        #expect(generator.calls.isEmpty)

        scheduler.tick(now: 1800, segments: [first, second, third])
        await scheduler.waitForIdle()
        #expect(generator.calls.count == 1)
        #expect(generator.calls[0].lines == TranscriptSegment.lines([first, second, third]))
    }

    @Test(arguments: [(59, false), (60, true)])
    func japaneseMinimumIsSixtyCharacters(count: Int, recaps: Bool) async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator, language: .japanese)
        let segment = TranscriptSegment(start: 0, end: 5, text: String(repeating: "あ", count: count))

        scheduler.tick(now: 600, segments: [segment])
        await scheduler.waitForIdle()

        #expect(generator.calls.count == (recaps ? 1 : 0))
    }

    @Test func tickWhileGeneratingDoesNotStartAnother() async {
        let generator = FakeRecapGenerator()
        generator.holdsCalls = true
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await generator.waitForCalls(1)
        #expect(scheduler.isGenerating)
        #expect(scheduler.generatingWindow == 0...5)

        scheduler.tick(now: 1300, segments: [a, b])
        #expect(generator.calls.count == 1)

        generator.holdsCalls = false
        generator.releaseHeldCalls()
        await scheduler.waitForIdle()
        #expect(scheduler.entries.count == 1)
        #expect(scheduler.lastRecapAt == 600)

        scheduler.tick(now: 1300, segments: [a, b])
        await scheduler.waitForIdle()
        #expect(generator.calls.count == 2)
        #expect(generator.calls[1].lines == TranscriptSegment.lines([b]))
    }

    @Test func finishWaitsForTheInFlightRecapThenCoversTheRest() async {
        let generator = FakeRecapGenerator()
        generator.holdsCalls = true
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await generator.waitForCalls(1)
        let finishing = Task { await scheduler.finish(segments: [a, b]) }
        for _ in 0..<10 { await Task.yield() }
        #expect(generator.calls.count == 1)

        generator.holdsCalls = false
        generator.releaseHeldCalls()
        await finishing.value

        #expect(scheduler.entries.count == 2)
        #expect(!scheduler.entries[0].isFinal)
        #expect(scheduler.entries[1].isFinal)
        #expect(generator.calls[1].lines == TranscriptSegment.lines([b]))
        #expect(scheduler.hasEnded)
        #expect(scheduler.nextRecapAt == nil)
    }

    @Test func finishWithNothingLeftAddsNoEntry() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        scheduler.tick(now: 600, segments: [a])
        await scheduler.waitForIdle()

        await scheduler.finish(segments: [a])

        #expect(scheduler.entries.count == 1)
        #expect(generator.calls.count == 1)
        #expect(scheduler.hasEnded)
    }

    @Test func finishRunsOnlyOnce() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)

        await scheduler.finish(segments: [a])
        await scheduler.finish(segments: [a, speech(40, at: 100)])

        #expect(scheduler.entries.count == 1)
        #expect(generator.calls.count == 1)
    }

    @Test func failureAppendsAFailedEntryAndCoversItsSegments() async {
        let generator = FakeRecapGenerator()
        generator.results = [.failure(FakeRecapError())]
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await scheduler.waitForIdle()
        #expect(scheduler.entries.map(\.state) == [.failed(message: "Boom")])

        scheduler.tick(now: 1200, segments: [a, b])
        await scheduler.waitForIdle()
        #expect(generator.calls[1].lines == TranscriptSegment.lines([b]))
    }

    @Test func retryReplacesTheFailedEntryInPlace() async {
        let generator = FakeRecapGenerator()
        let second = RecapContent(summary: "Second", keyPoints: [])
        let retried = RecapContent(summary: "Retried", keyPoints: [])
        generator.results = [.failure(FakeRecapError()), .success(second), .success(retried)]
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await scheduler.waitForIdle()
        scheduler.tick(now: 1200, segments: [a, b])
        await scheduler.waitForIdle()
        let failedID = scheduler.entries[0].id

        scheduler.retry(failedID, segments: [a, b])
        await scheduler.waitForIdle()

        #expect(scheduler.entries.count == 2)
        #expect(scheduler.entries[0].id == failedID)
        #expect(scheduler.entries[0].content == retried)
        #expect(scheduler.entries[1].content == second)
        #expect(generator.calls[2].lines == TranscriptSegment.lines([a]))
        #expect(generator.calls[2].earlier == nil)
    }

    @Test func laterRecapsGetTheEarlierSummary() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await scheduler.waitForIdle()
        scheduler.tick(now: 1200, segments: [a, b])
        await scheduler.waitForIdle()

        #expect(generator.calls[0].earlier == nil)
        #expect(generator.calls[1].earlier == "Summary 1")
    }

    @Test func changingTheIntervalOnlyMovesTheNextRecap() async {
        let generator = FakeRecapGenerator()
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)
        scheduler.tick(now: 600, segments: [a])
        await scheduler.waitForIdle()
        #expect(scheduler.nextRecapAt == 1200)

        scheduler.interval = .five
        #expect(scheduler.nextRecapAt == 900)
        #expect(scheduler.entries.count == 1)

        scheduler.tick(now: 899, segments: [a, b])
        await scheduler.waitForIdle()
        #expect(generator.calls.count == 1)

        scheduler.tick(now: 900, segments: [a, b])
        await scheduler.waitForIdle()
        #expect(generator.calls.count == 2)
    }

    @Test func clearDropsTheInFlightRecap() async {
        let generator = FakeRecapGenerator()
        generator.holdsCalls = true
        let scheduler = makeScheduler(generator)
        scheduler.tick(now: 600, segments: [speech(40, at: 0)])
        await generator.waitForCalls(1)

        scheduler.clear()
        generator.releaseHeldCalls()
        for _ in 0..<10 { await Task.yield() }

        #expect(scheduler.entries.isEmpty)
        #expect(!scheduler.isGenerating)
        #expect(scheduler.lastRecapAt == 0)
    }

    @Test func resetDuringFinishDropsTheFinalRecap() async {
        let generator = FakeRecapGenerator()
        generator.holdsCalls = true
        let scheduler = makeScheduler(generator)
        let a = speech(40, at: 0)
        let b = speech(40, at: 700)

        scheduler.tick(now: 600, segments: [a])
        await generator.waitForCalls(1)
        let finishing = Task { await scheduler.finish(segments: [a, b]) }
        for _ in 0..<10 { await Task.yield() }

        scheduler.reset(language: .english)
        generator.holdsCalls = false
        generator.releaseHeldCalls()
        await finishing.value

        #expect(scheduler.entries.isEmpty)
        #expect(!scheduler.hasEnded)
        #expect(generator.calls.count == 1)
    }

    @Test func unavailableModelIsNeverCalled() async {
        let generator = FakeRecapGenerator()
        generator.availability = .appleIntelligenceOff
        let scheduler = makeScheduler(generator)

        scheduler.tick(now: 600, segments: [speech(40, at: 0)])
        await scheduler.finish(segments: [speech(40, at: 0)])

        #expect(generator.calls.isEmpty)
        #expect(scheduler.entries.isEmpty)
        #expect(scheduler.availability == .appleIntelligenceOff)
        #expect(scheduler.nextRecapAt == nil)
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail.**
Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/RecapSchedulerTests"`
Expected: build failure, "cannot find 'RecapScheduler' in scope".

- [ ] **Step 3: Create `Audio Transcribe/RecapScheduler.swift`.**

```swift
import Foundation
import Observation

/// Decides when a live session is recapped and what each recap covers, and keeps the list of recaps.
///
/// Coverage is tracked by segment ID rather than by time: a segment from another channel can finalize after a
/// recap but start earlier on the merged timeline, and it must land in the next recap exactly once.
@MainActor
@Observable
final class RecapScheduler {
    private(set) var entries: [RecapEntry] = []
    var interval: RecapInterval = .ten
    /// The window being summarized right now, for the "Summarizing…" row.
    private(set) var generatingWindow: ClosedRange<TimeInterval>?
    private(set) var availability: RecapAvailability
    /// Set once the final recap has been made (or attempted) for this session.
    private(set) var hasEnded = false
    /// Session time of the last tick that made, or skipped, a recap.
    private(set) var lastRecapAt: TimeInterval = 0

    var isGenerating: Bool { generatingWindow != nil }

    var nextRecapAt: TimeInterval? {
        guard availability == .available, !hasEnded else { return nil }
        return lastRecapAt + interval.seconds
    }

    @ObservationIgnored private let generator: any RecapGenerating
    @ObservationIgnored private var language: TranscriptionLanguage = .english
    @ObservationIgnored private var coveredIDs: Set<UUID> = []
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// Bumped by `clear`, so results and `finish` calls from before it are dropped.
    @ObservationIgnored private var generation = 0

    init(generator: any RecapGenerating) {
        self.generator = generator
        availability = generator.availability
    }

    /// Starts a new session.
    func reset(language: TranscriptionLanguage) {
        clear()
        self.language = language
        availability = generator.availability
    }

    /// Removes every recap and drops any recap still being generated.
    func clear() {
        inFlight?.cancel()
        inFlight = nil
        generation += 1
        entries = []
        coveredIDs = []
        lastRecapAt = 0
        generatingWindow = nil
        hasEnded = false
    }

    /// Called periodically while recording. Recaps the uncovered segments once `interval` has passed.
    func tick(now: TimeInterval, segments: [TranscriptSegment]) {
        guard availability == .available, !hasEnded, inFlight == nil,
              now - lastRecapAt >= interval.seconds else { return }
        lastRecapAt = now
        let window = uncovered(in: segments)
        guard Self.hasEnoughContent(window, language: language) else { return }
        startRecap(of: window, isFinal: false, replacing: nil)
    }

    /// Ends the session: waits for any recap in progress, then recaps what's left as the final recap.
    func finish(segments: [TranscriptSegment]) async {
        let generation = self.generation
        await waitForIdle()
        guard generation == self.generation, !hasEnded else { return }
        hasEnded = true
        guard availability == .available else { return }
        let window = uncovered(in: segments)
        guard Self.hasEnoughContent(window, language: language) else { return }
        startRecap(of: window, isFinal: true, replacing: nil)
        await waitForIdle()
    }

    /// Runs a failed entry's window again and replaces that entry with the result.
    func retry(_ id: UUID, segments: [TranscriptSegment]) {
        guard inFlight == nil,
              let entry = entries.first(where: { $0.id == id }),
              case .failed = entry.state else { return }
        let ids = Set(entry.segmentIDs)
        let window = segments.filter { ids.contains($0.id) }
        guard !window.isEmpty else { return }
        startRecap(of: window, isFinal: entry.isFinal, replacing: id)
    }

    /// Waits until no recap is being generated.
    func waitForIdle() async {
        while let task = inFlight {
            await task.value
            if inFlight == task { inFlight = nil }
        }
    }

    static func hasEnoughContent(_ window: [TranscriptSegment], language: TranscriptionLanguage) -> Bool {
        let text = window.map(\.text).joined(separator: " ")
        switch language {
        case .english: return text.split(whereSeparator: \.isWhitespace).count >= 30
        case .japanese: return text.filter { !$0.isWhitespace }.count >= 60
        }
    }

    private func uncovered(in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.filter { !coveredIDs.contains($0.id) }
    }

    private func startRecap(of window: [TranscriptSegment], isFinal: Bool, replacing id: UUID?) {
        let ids = window.map(\.id)
        coveredIDs.formUnion(ids)
        let start = window.map(\.start).min() ?? 0
        let end = max(window.map(\.end).max() ?? start, start)
        let lines = TranscriptSegment.lines(window)
        let earlier = summary(before: id)
        let language = self.language
        let generation = self.generation
        let generator = self.generator
        generatingWindow = start...end

        inFlight = Task {
            let state: RecapEntry.State
            do {
                state = .done(try await generator.recap(lines: lines, earlier: earlier, language: language))
            } catch {
                state = .failed(message: RecapErrors.message(for: error))
            }
            guard generation == self.generation else { return }
            self.generatingWindow = nil
            self.inFlight = nil
            if let id, let index = self.entries.firstIndex(where: { $0.id == id }) {
                self.entries[index].state = state
            } else {
                self.entries.append(RecapEntry(
                    id: UUID(), windowStart: start, windowEnd: end,
                    segmentIDs: ids, isFinal: isFinal, state: state
                ))
            }
        }
    }

    /// The summary of the latest successful recap before `id`, or before the end of the list when `id` is nil.
    private func summary(before id: UUID?) -> String? {
        let end = id.flatMap { id in entries.firstIndex { $0.id == id } } ?? entries.endIndex
        return entries[..<end].reversed().lazy.compactMap(\.content).first?.summary
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass.**
Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/RecapSchedulerTests"`
Expected: `** TEST SUCCEEDED **` (18 test cases: 17 functions, one of which has two arguments). If a test that holds the generator hangs until the 1-minute limit, the in-flight `Task` isn't running on the main actor. Check that `RecapScheduler` is `@MainActor`.

- [ ] **Step 5: Commit.**

```bash
git add "Audio Transcribe/RecapScheduler.swift" "Audio TranscribeTests/RecapSchedulerTests.swift"
git commit -m "Add RecapScheduler for timed, append-only recaps

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Connect recaps to the live session

**Files:**
- Modify: `Audio Transcribe/TranscriptionViewModel.swift`
- Test: `Audio TranscribeTests/TranscriptionViewModelTests.swift`

**Interfaces:**
- Consumes: `RecapScheduler` (Task 3), `SystemRecapGenerator`, `RecapGenerating` (Task 2).
- Produces: `TranscriptionViewModel.init(recapGenerator: any RecapGenerating = SystemRecapGenerator())`, `let recap: RecapScheduler`, `func retryRecap(_ id: UUID)`, and `static let recapTickInterval: Duration = .seconds(30)`.

- [ ] **Step 1: Write the failing tests.** Append to `Audio TranscribeTests/TranscriptionViewModelTests.swift`:

```swift
@Suite(.timeLimit(.minutes(1)))
struct TranscriptionViewModelRecapTests {
    /// A "recording" view model whose transcript has enough words for a recap. With no channels,
    /// `segments` reads `fileSegments`, so the tests can supply a transcript without running audio.
    private func makeViewModel(_ generator: FakeRecapGenerator) -> TranscriptionViewModel {
        let viewModel = TranscriptionViewModel(recapGenerator: generator)
        viewModel.recap.reset(language: .english)
        viewModel.fileSegments = [speech(40, at: 0)]
        viewModel.status = .recording
        return viewModel
    }

    @Test func stopMakesTheFinalRecap() async {
        let generator = FakeRecapGenerator()
        let viewModel = makeViewModel(generator)

        await viewModel.stop()

        #expect(viewModel.status == .idle)
        #expect(viewModel.recap.entries.count == 1)
        #expect(viewModel.recap.entries.first?.isFinal == true)
        #expect(viewModel.recap.hasEnded)
    }

    @Test func recapFailureLeavesStatusAlone() async {
        let generator = FakeRecapGenerator()
        generator.results = [.failure(FakeRecapError())]
        let viewModel = makeViewModel(generator)

        await viewModel.stop()

        #expect(viewModel.status == .idle)
        #expect(viewModel.recap.entries.first?.state == .failed(message: "Boom"))
    }

    @Test func clearRemovesRecaps() async {
        let viewModel = makeViewModel(FakeRecapGenerator())
        await viewModel.stop()

        viewModel.clear()

        #expect(viewModel.recap.entries.isEmpty)
        #expect(!viewModel.recap.hasEnded)
    }

    @Test func retryRecapRerunsTheFailedWindow() async {
        let generator = FakeRecapGenerator()
        let retried = RecapContent(summary: "Retried", keyPoints: [])
        generator.results = [.failure(FakeRecapError()), .success(retried)]
        let viewModel = makeViewModel(generator)
        await viewModel.stop()

        viewModel.retryRecap(viewModel.recap.entries[0].id)
        await viewModel.recap.waitForIdle()

        #expect(viewModel.recap.entries.count == 1)
        #expect(viewModel.recap.entries[0].content == retried)
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail.**
Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -only-testing:"Audio TranscribeTests/TranscriptionViewModelRecapTests"`
Expected: build failure, "extra argument 'recapGenerator' in call".

- [ ] **Step 3: Implement.** In `Audio Transcribe/TranscriptionViewModel.swift`:

(a) Below `var modelDownloadProgress: Progress?`, add:

```swift
    /// Recaps of the live session, made on device while recording.
    let recap: RecapScheduler
    /// How often the recap scheduler is asked whether a recap is due.
    static let recapTickInterval: Duration = .seconds(30)
    @ObservationIgnored private var recapTicker: Task<Void, Never>?

    init(recapGenerator: any RecapGenerating = SystemRecapGenerator()) {
        recap = RecapScheduler(generator: recapGenerator)
    }
```

(b) In `start()`, replace

```swift
            try await LiveChannel.startAll(
                newChannels,
                language: language,
                sessionStart: Date(),
                labelSegments: newChannels.count > 1
            )
            status = Self.statusAfterStarting(current: status, anyChannelRunning: newChannels.contains(where: \.isRunning))
```

with

```swift
            let sessionStart = Date()
            try await LiveChannel.startAll(
                newChannels,
                language: language,
                sessionStart: sessionStart,
                labelSegments: newChannels.count > 1
            )
            status = Self.statusAfterStarting(current: status, anyChannelRunning: newChannels.contains(where: \.isRunning))
            if isRecording {
                startRecaps(sessionStart: sessionStart)
            }
```

(c) Replace `stop()` with:

```swift
    func stop() async {
        do {
            try await LiveChannel.stopAll(channels)
            status = Self.statusAfterStopping(current: status)
        } catch {
            status = .failed(error.localizedDescription)
        }
        // After the channels have drained, so the final recap includes the last segments.
        await endRecaps()
    }
```

(d) In `clear()`, after `channelWarning = nil`, add:

```swift
        recapTicker?.cancel()
        recapTicker = nil
        recap.clear()
```

(e) After `clear()`, add:

```swift
    func retryRecap(_ id: UUID) {
        recap.retry(id, segments: segments)
    }
```

(f) In `channelDidEndUnexpectedly(_:)`, replace

```swift
        if !othersStillRunning, isRecording {
            status = .idle
        }
```

with

```swift
        if !othersStillRunning, isRecording {
            status = .idle
            Task { await endRecaps() }
        }
```

(g) Replace `liveTranscriptionDidFail(_:)` with:

```swift
    private func liveTranscriptionDidFail(_ error: Error) {
        status = .failed(error.localizedDescription)
        let channels = self.channels
        Task {
            try? await LiveChannel.stopAll(channels)
            await endRecaps()
        }
    }
```

(h) Add these private methods before `prepareAssets()`:

```swift
    /// Starts a fresh recap session and asks the scheduler every `recapTickInterval` whether a recap is due.
    private func startRecaps(sessionStart: Date) {
        recap.reset(language: language)
        recapTicker?.cancel()
        recapTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.recapTickInterval)
                guard let self, !Task.isCancelled, self.isRecording else { return }
                self.recap.tick(now: Date().timeIntervalSince(sessionStart), segments: self.segments)
            }
        }
    }

    /// Stops the ticker and makes the final recap. Calling it again does nothing: `finish` runs once per session.
    private func endRecaps() async {
        recapTicker?.cancel()
        recapTicker = nil
        await recap.finish(segments: segments)
    }
```

- [ ] **Step 4: Run all the unit tests and confirm they pass.**
Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -skip-testing:"Audio TranscribeTests/TranscriptionEngineTests" -skip-testing:"Audio TranscribeTests/RecapModelTests"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
git add "Audio Transcribe/TranscriptionViewModel.swift" "Audio TranscribeTests/TranscriptionViewModelTests.swift"
git commit -m "Recap live sessions on a timer and on Stop

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The Recap panel

**Files:**
- Create: `Audio Transcribe/Pasteboard.swift`
- Create: `Audio Transcribe/RecapView.swift`
- Modify: `Audio Transcribe/ContentView.swift`

**Interfaces:**
- Consumes: `RecapScheduler`, `RecapEntry`, `RecapInterval`, `RecapAvailability`, `TranscriptionViewModel.recap`, `.retryRecap(_:)` and `.isRecording`.
- Produces: `RecapView(scheduler: RecapScheduler, isRecording: Bool, onRetry: (UUID) -> Void)` and `enum Pasteboard { static func copy(_ text: String) }`.

SwiftUI layout isn't unit-tested in this project. The verification for this task is a build plus Xcode previews and a manual run (Step 5).

- [ ] **Step 1: Move the copy helper.** Create `Audio Transcribe/Pasteboard.swift`:

```swift
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
```

In `Audio Transcribe/ContentView.swift`, delete the `private func copyToClipboard(_ text: String)` method and the `#if os(macOS) import AppKit #else import UIKit #endif` block at the top. Change the Copy button's action to `Pasteboard.copy(viewModel.fullText)`.

- [ ] **Step 2: Create `Audio Transcribe/RecapView.swift`.**

```swift
import SwiftUI

/// The Recap side panel: recaps of the live session, oldest first, newest appended at the bottom.
struct RecapView: View {
    @Bindable var scheduler: RecapScheduler
    let isRecording: Bool
    let onRetry: (UUID) -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxHeight: .infinity)
            if scheduler.availability == .available {
                Divider()
                footer
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Recap")
                .font(.headline)
            Spacer()
            Menu {
                Picker("Summarize every", selection: $scheduler.interval) {
                    ForEach(RecapInterval.allCases) { interval in
                        Text(interval.menuLabel).tag(interval)
                    }
                }
                .pickerStyle(.inline)
                Text("Applies from the next recap.")
            } label: {
                Text(scheduler.interval.shortLabel)
            }
            .fixedSize()
            .disabled(scheduler.availability != .available)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let title = scheduler.availability.title, let message = scheduler.availability.message {
            ContentUnavailableView {
                Label(title, systemImage: "apple.intelligence")
            } description: {
                Text(message)
            } actions: {
                #if os(macOS)
                if scheduler.availability == .appleIntelligenceOff, let url = URL(string: "x-apple.systempreferences:") {
                    Button("Open System Settings…") { openURL(url) }
                }
                #endif
            }
        } else if scheduler.entries.isEmpty && !scheduler.isGenerating {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "clock")
            } description: {
                Text(emptyMessage)
            }
        } else {
            entryList
        }
    }

    private var emptyTitle: String {
        if isRecording, let next = scheduler.nextRecapAt {
            return "First recap at about \(TranscriptSegment.formatted(next))"
        }
        return "No recaps yet"
    }

    private var emptyMessage: String {
        let minutes = scheduler.interval.rawValue
        return isRecording
            ? "While you record, Apple Intelligence summarizes the conversation on this device every \(minutes) minutes. Earlier recaps stay in the list."
            : "Start a live recording and recaps will appear here every \(minutes) minutes."
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(scheduler.entries) { entry in
                        RecapEntryRow(entry: entry, canRetry: !scheduler.isGenerating) {
                            onRetry(entry.id)
                        }
                        .id(entry.id)
                        Divider()
                    }
                    if let window = scheduler.generatingWindow {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Summarizing \(RecapEntry.formattedRange(window.lowerBound, window.upperBound))…")
                                Text("On-device · Apple Intelligence")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .id("generating")
                    }
                }
            }
            .onChange(of: scheduler.entries.count) {
                withAnimation { proxy.scrollTo(scheduler.entries.last?.id, anchor: .bottom) }
            }
            .onChange(of: scheduler.isGenerating) {
                if scheduler.isGenerating {
                    withAnimation { proxy.scrollTo("generating", anchor: .bottom) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(scheduler.hasEnded ? "Session ended · \(recapCount)" : recapCount)
            Spacer()
            if isRecording, let next = scheduler.nextRecapAt {
                Text("Next recap around \(TranscriptSegment.formatted(next))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var recapCount: String {
        scheduler.entries.count == 1 ? "1 recap" : "\(scheduler.entries.count) recaps"
    }
}

private struct RecapEntryRow: View {
    let entry: RecapEntry
    let canRetry: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(entry.formattedRange)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                if entry.isFinal {
                    Text("FINAL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                }
                Spacer()
                if let content = entry.content {
                    Button {
                        Pasteboard.copy(content.plainText)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy recap")
                    .accessibilityLabel("Copy recap")
                }
            }
            switch entry.state {
            case .done(let content):
                Text(content.summary)
                    .textSelection(.enabled)
                if !content.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(content.keyPoints.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•")
                                Text(point)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label {
                    Text("Couldn't summarize this part. \(message)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                    .disabled(!canRetry)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private final class PreviewRecapGenerator: RecapGenerating {
    var availability: RecapAvailability
    init(_ availability: RecapAvailability) { self.availability = availability }
    func recap(lines: [String], earlier: String?, language: TranscriptionLanguage) async throws -> RecapContent {
        RecapContent(
            summary: "Five vendors were reviewed; three were dropped for lacking SSO or Japanese-language support.",
            keyPoints: ["Shortlist: Northwind, Larkspur", "SSO is a hard requirement", "Northwind demo Thursday 3 pm"]
        )
    }
}

#Preview("Recording") {
    let scheduler = RecapScheduler(generator: PreviewRecapGenerator(.available))
    scheduler.reset(language: .english)
    let segments = (0..<12).map { TranscriptSegment(start: TimeInterval($0 * 50), end: TimeInterval($0 * 50 + 5), text: "We compared the vendor options and agreed on next steps", speaker: "You") }
    scheduler.tick(now: 600, segments: segments)
    return RecapView(scheduler: scheduler, isRecording: true) { _ in }
        .frame(width: 340, height: 600)
}

#Preview("Unavailable") {
    let scheduler = RecapScheduler(generator: PreviewRecapGenerator(.appleIntelligenceOff))
    return RecapView(scheduler: scheduler, isRecording: true) { _ in }
        .frame(width: 340, height: 600)
}
```

- [ ] **Step 3: Add the panel to `ContentView`.** In `Audio Transcribe/ContentView.swift`:

(a) Add state below `@State private var exportFileName = ""`:

```swift
    #if os(macOS)
    @State private var showsRecap = true
    #else
    @State private var showsRecap = false
    #endif
```

(b) In `body`, attach the inspector to the `VStack`, before `#if os(macOS) .frame(minWidth: 520, minHeight: 440)`:

```swift
        .inspector(isPresented: Binding(
            get: { showsRecap && viewModel.mode == .live },
            set: { showsRecap = $0 }
        )) {
            RecapView(scheduler: viewModel.recap, isRecording: viewModel.isRecording) { id in
                viewModel.retryRecap(id)
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
            .presentationDragIndicator(.visible)
        }
```

(c) In `controls`, replace the final `actionButton` line with:

```swift
            HStack {
                actionButton
                Spacer()
                if viewModel.mode == .live {
                    Button {
                        showsRecap.toggle()
                    } label: {
                        Label("Recap", systemImage: "sidebar.trailing")
                    }
                    .help(showsRecap ? "Hide recaps" : "Show recaps")
                }
            }
```

(d) Widen the macOS window so the panel fits. In `Audio Transcribe/MyApp.swift`, change `.defaultSize(width: 640, height: 520)` to `.defaultSize(width: 980, height: 600)`.

- [ ] **Step 4: Build for macOS and iOS.**
Run: `xcodebuild build -scheme "Audio Transcribe" -destination 'platform=macOS'`, then `xcodebuild build -scheme "Audio Transcribe" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **` for both. Deprecation warnings from `RecapErrors` are expected on iOS; nothing else should be new.

- [ ] **Step 5: Manual check on macOS.** Run the app (⌘R). Choose Microphone + System audio (or System audio only), set the interval to **5 min**, play a talk video for about 12 minutes, and press Stop. Check:
  - The panel says "First recap at about 05:00" before the first recap.
  - The "Summarizing…" row appears, then an entry is appended at about 05:00 and again at about 10:00.
  - Stop appends a **FINAL** entry, and the footer reads "Session ended · 3 recaps".
  - Copy puts the summary and `- ` key points on the clipboard.
  - Clear empties the panel.
  - With Apple Intelligence turned off in System Settings, a new session shows "Recaps need Apple Intelligence", and transcription still works.
  - Language 日本語 gives Japanese recaps.
  - In File mode the panel is hidden.

- [ ] **Step 6: Run the whole unit suite again.**
Run: `xcodebuild test -scheme "Audio Transcribe" -destination 'platform=macOS' -skip-testing:"Audio TranscribeTests/TranscriptionEngineTests" -skip-testing:"Audio TranscribeTests/RecapModelTests"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit.**

```bash
git add "Audio Transcribe/Pasteboard.swift" "Audio Transcribe/RecapView.swift" "Audio Transcribe/ContentView.swift" "Audio Transcribe/MyApp.swift"
git commit -m "Show recaps in a side panel

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the feature.** In `README.md`:

(a) In **Features**, after the **Microphone + system audio together** bullet, add:

```markdown
- **Recap (Apple Intelligence)**: while recording live, the on-device model summarizes the conversation every 5, 10 or 15 minutes (10 by default) in a Recap side panel: a short summary plus key names, numbers, dates and decisions. New recaps are appended, so earlier ones stay visible, and Stop adds a final recap of the last few minutes. Recaps stay on the device and are cleared with the transcript. They need a device with Apple Intelligence turned on; without it, the panel says why and transcription works as usual.
```

(b) In **Requirements**, add the bullet:

```markdown
- For recaps: a device that supports Apple Intelligence, with Apple Intelligence turned on.
```

(c) In **Tests**, after the `TranscriptionEngineTests` paragraph, add:

```markdown
`RecapModelTests` runs the real on-device model on short English and Japanese transcripts. It is skipped where Apple Intelligence isn't available, and CI leaves it out for the same reason.
```

Also change the GitHub Actions sentence to: "GitHub's macOS VMs can't run the Speech models or Apple Intelligence, so CI leaves out `TranscriptionEngineTests` and `RecapModelTests`; run them locally."

(d) In the **Project structure** table, add these rows after `TranscriptExporter.swift`:

```markdown
| `Recap.swift` | Recap data: the model's `RecapContent` (`@Generable`), `RecapEntry`, the interval presets, and Apple Intelligence availability. |
| `RecapGenerator.swift` | Makes one recap with the on-device model (`FoundationModels`): a fresh session per call, chunking of long windows, and a merge step. |
| `RecapScheduler.swift` | Decides when a recap is due and which segments it covers (tracked by segment ID), keeps the append-only list, and handles the final recap and Retry. |
| `RecapView.swift` | The Recap side panel. |
| `Pasteboard.swift` | Copies text to the clipboard on each platform. |
```

- [ ] **Step 2: Commit.**

```bash
git add README.md
git commit -m "Document recap mode

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
