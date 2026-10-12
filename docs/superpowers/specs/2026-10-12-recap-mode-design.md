# Recap mode: on-device rolling summaries of live sessions

Date: 2026-10-12
Status: Draft, awaiting review
Mockups: https://claude.ai/artifact/Ns3Rsgfk5pEhAXJoqP4b4k

## Goal

During a live session (a call or a meeting), Apple Intelligence's on-device model summarizes the conversation every few minutes. The summaries go in a dedicated Recap panel. New recaps are **appended**, so earlier ones stay visible and the session reads as a running timeline of summaries.

### Success criteria

- Partway through a meeting the user opens the Recap panel and sees a short, accurate digest of each past interval: a 1–3 sentence summary plus key points (names, numbers, dates, decisions, requests).
- Recaps appear automatically every 5, 10 or 15 minutes (default 10) while recording, with no user action.
- Pressing Stop produces a final recap of whatever came after the last one.
- Earlier recaps are never rewritten or replaced. The only exception is retrying a failed entry.
- Transcription works exactly as before, whatever the state of Apple Intelligence.

### Non-goals

- Recaps for File mode.
- A manual "Recap now" button.
- Persisting recaps to disk, or exporting recaps. Recaps live as long as the transcript and are cleared with it. Each entry has its own Copy button.
- Meeting-style sections (separate Decisions, Action items and Questions lists).
- Recaps in a language other than the transcription language.
- Cloud models. Everything stays on device.

## Decisions

| Question | Decision |
|---|---|
| Trigger | Automatic, on a timer, while recording. Plus one final recap on Stop. |
| Interval | Presets: 5, 10 or 15 minutes. Default 10. Can be changed during a recording; the change applies from the next recap. |
| Where | A side panel: SwiftUI `.inspector`. A trailing column on macOS and iPad, a sheet on iPhone. A toolbar button toggles it. |
| Content | `summary` (1–3 sentences) plus `keyPoints` (at most 6). |
| Model sessions | A fresh `LanguageModelSession` for each recap. Continuity comes from passing the previous recap's summary as an `Earlier:` line. |
| Language | Same as the transcription language (English or Japanese). |
| Lifetime | In memory. Reset on Start and on Clear, like the transcript. |

## Approach

The on-device model's context window is small (about 4K tokens, prompt and output together), and 15 minutes of busy conversation can approach that, especially in Japanese. So every recap is a self-contained call with a bounded input:

- a fresh session per recap (no conversation history builds up);
- an input split into chunks on segment boundaries when it is over a character budget;
- a merge call that combines the per-chunk recaps.

Approaches considered and rejected:
- **One long-lived session for the whole meeting.** It overflows the context window after a couple of recaps and then needs history trimming or restarts.
- **Rolling one-minute summaries rolled up at the interval.** Many model calls, more battery use, and detail lost through summaries of summaries.

## Components

Four new files in `Audio Transcribe/`, each with one job.

### `Recap.swift`: data model

```swift
struct RecapContent: Equatable, Sendable {
    var summary: String       // 1–3 sentences
    var keyPoints: [String]   // at most 6
}

struct RecapEntry: Identifiable, Equatable {
    enum State: Equatable {
        case done(RecapContent)
        case failed(message: String)
    }
    let id: UUID
    /// The window on the session timeline, shown as `MM:SS – MM:SS`.
    let windowStart: TimeInterval
    let windowEnd: TimeInterval
    /// The IDs of the segments this entry covers, kept so Retry can rebuild the same window.
    let segmentIDs: [UUID]
    let isFinal: Bool
    var state: State
}
```

### `RecapGenerator.swift`: talks to the model

```swift
protocol RecapGenerating: Sendable {
    func recap(lines: [String], earlier: String?, language: TranscriptionLanguage) async throws -> RecapContent
}

enum RecapAvailability: Equatable {
    case available
    case appleIntelligenceOff     // "Turn on Apple Intelligence in System Settings…" + Open System Settings button
    case deviceNotEligible        // "This device doesn't support Apple Intelligence."
    case modelNotReady            // "The model is still downloading. Recaps will start when it's ready."
}
```

- `SystemRecapGenerator` maps `SystemLanguageModel.default.availability` to `RecapAvailability`.
- It creates a new `LanguageModelSession` for each call, on `SystemLanguageModel(guardrails: .permissiveContentTransformations)`, and asks for a **plain-text reply** in a fixed format (`Summary: …` / `Key points:` / `- …`). `parse` reads that reply into `RecapContent`. It accepts the Japanese labels the model uses when answering in Japanese (`概要`, `キーポイント`, …), and a reply without a summary label becomes the summary as a whole.
- *Revised 2026-10-12:* the first version used guided generation (`@Generable`, `respond(to:generating:)`). On real conversations that path refused ordinary content ("May contain sensitive content", `LanguageModelError.refusal`) about half the time, and the permissive guardrails apply only to plain-text replies. Refusals and guardrail violations are both reported as "The on-device model declined the request."
- **Instructions:** "You summarize a live conversation transcript. Lines are `Speaker: text`. Write a 1–3 sentence summary and up to 6 key points: important names, numbers, dates, decisions and requests. Use only what's in the transcript. Respond in {English | Japanese}."
- **Prompt:** an optional `Earlier: <previous summary>` line, followed by the window's lines.
- **Chunking:** `static func chunks(_ lines: [String], budget: Int) -> [[String]]` packs whole lines up to the budget: **6,000 characters for English, 2,500 for Japanese**. A single line longer than the budget becomes a chunk of its own, truncated to the budget. With more than one chunk, each chunk is recapped, then one merge call summarizes the partial recaps. The merge call's prompt lists each part's summary and key points, and its instructions say "combine these partial recaps into one".
- If the model throws `exceededContextWindowSize`, the chunk is halved and retried. The minimum chunk size is 500 characters; below that, the error is rethrown.
- The pure parts (`chunks`, building the prompt, mapping availability) are `static`, so they can be tested without the model.

### `RecapScheduler.swift`: decides when, and what

`@MainActor @Observable final class RecapScheduler`

State:
- `entries: [RecapEntry]`, appended in order.
- `interval: RecapInterval` (`.five`, `.ten`, `.fifteen`; default `.ten`).
- `isGenerating: Bool` and `generatingWindow: (start, end)?`, for the "Summarizing…" row.
- `availability: RecapAvailability`.
- `nextRecapAt: TimeInterval?`, for the "Next recap around MM:SS" footer.
- `hasEnded: Bool`, for the "Session ended" footer.
- Private: `coveredIDs: Set<UUID>`, `lastRecapAt: TimeInterval`, the in-flight `Task`.

API:
- `reset(language:)` clears everything, records the language and reads availability.
- `tick(now: TimeInterval, segments: [TranscriptSegment])`: if `now − lastRecapAt ≥ interval` and nothing is generating, run a recap of the uncovered segments.
- `finish(segments:) async` waits for any in-flight recap, then recaps the uncovered remainder as `isFinal: true` and sets `hasEnded`.
- `retry(_ id: UUID, segments:)` reruns a failed entry's window in place.
- `clear()` cancels in-flight work and empties `entries`.

Windowing rules:
- **Coverage is tracked by segment ID, not by a cutoff time.** A segment from another channel can finalize late and be merged earlier in the timeline than segments that have already been recapped. Tracking IDs means it is neither lost nor counted twice.
- The window is every segment whose ID isn't in `coveredIDs`. `windowStart` is the minimum start and `windowEnd` the maximum end.
- **Minimum content:** if the window has fewer than 30 words (English, counted on whitespace) or 60 characters (Japanese), no recap is made. `lastRecapAt` still advances, but the segments stay uncovered and carry over to the next window. For `finish`, a remainder below the minimum produces no final entry.
- When a recap starts, the window's segment IDs are added to `coveredIDs` and `lastRecapAt = now`. They stay covered even if the recap fails, so a persistent failure doesn't snowball into ever-larger windows.
- `earlier` is the summary of the most recent `.done` entry, if there is one.
- Changing `interval` only moves `nextRecapAt` (`lastRecapAt + interval`).
- If the model isn't available, `tick` and `finish` do nothing. Availability is checked again on each `reset`.

### `RecapView.swift`: the panel

- **Header:** "Recap", plus an interval menu ("Every 10 min"; options 5, 10 and 15 minutes; the note "Applies from the next recap."). The menu is disabled when the model is unavailable.
- **List:** entries oldest first, auto-scrolled to the newest. Each entry shows:
  - its `MM:SS – MM:SS` range in a small, secondary, tabular-digit label;
  - a **FINAL** badge when `isFinal`;
  - a Copy button that copies the summary followed by the key points as `- ` lines;
  - the summary and the key-point bullets.
- **Failed entry:** the range, a warning icon, the message "Couldn't summarize this part." plus the reason, and a **Retry** button.
- **Generating row:** a spinner and "Summarizing MM:SS – MM:SS…", plus "On-device · Apple Intelligence".
- **Empty, while recording:** "First recap at about MM:SS" and a one-line explanation.
- **Unavailable:** the message for that `RecapAvailability` case. For `appleIntelligenceOff` there is also an "Open System Settings…" button.
- **Footer:** "N recaps · Next recap around MM:SS" while recording, and "Session ended · N recaps" after Stop.

## Changes to existing code

- **Shared transcript formatting.** Extract the `Speaker: text` line formatting from `TranscriptionViewModel.fullText` into `TranscriptSegment` (`static func lines(_:) -> [String]`). `fullText` and the recap prompt both use it. For a single source with no speaker, the lines are the trimmed segment texts.
- **`TranscriptionViewModel`**
  - Owns `let recap = RecapScheduler(generator: SystemRecapGenerator())`. Tests inject a fake.
  - `start()`: `recap.reset(language:)` once channels are running, then start a ticker `Task` that calls `recap.tick(now: elapsed, segments: segments)` every 30 seconds while recording.
  - `stop()`: cancel the ticker, then `await recap.finish(segments: segments)`. This runs after the channels have drained, so the last segments are included.
  - `clear()`: `recap.clear()`.
  - Recap errors never touch `status`.
  - Records `sessionStart` to compute `elapsed`.
- **`ContentView`:** `.inspector(isPresented: $showsRecap) { RecapView(scheduler: viewModel.recap) }` and a toolbar toggle (sidebar icon). Hidden in File mode. On macOS it is shown by default; on iPhone it opens on demand.

## Error handling

| Case | Behavior |
|---|---|
| Apple Intelligence off, device not eligible, model downloading | No recaps are attempted. The panel shows the reason. Transcription is unaffected. |
| A generation fails (guardrail violation, unsupported language, other) | A `.failed` entry is appended with Retry. Its segments still count as covered. |
| `exceededContextWindowSize` | Halve the chunk and retry, down to 500 characters, then fail the entry. |
| Stop while a recap is generating | `finish` waits for the in-flight recap, then covers the remainder. |
| Clear or Start while a recap is generating | The in-flight task is cancelled and its result discarded. |
| A tick while a recap is generating | Skipped. The next tick picks up everything uncovered. |

## Testing

Swift Testing in `Audio TranscribeTests`.

**`RecapSchedulerTests`** use a `FakeRecapGenerator`, which records its calls and returns canned content or throws. The clock is passed in through `tick(now:)`.
- No recap before the interval. At the interval, exactly one recap covers all uncovered segments.
- Windows under the minimum are skipped; `lastRecapAt` advances and the text carries over.
- A late-finalized segment with an earlier start time is included in the next window and never counted twice.
- A tick during generation doesn't start a second recap.
- `finish` waits for the in-flight recap, then covers the remainder with `isFinal`. With no remainder, it adds nothing.
- A failure appends a `.failed` entry with its segments covered. Retry replaces it in place.
- The second recap receives the first recap's summary as `earlier`.
- Changing the interval only affects `nextRecapAt`.
- `clear` empties entries and cancels in-flight work.
- When unavailable, `tick` and `finish` never call the generator.

**`RecapGeneratorTests`**
- `chunks` respects the English and Japanese budgets, never splits a line, and truncates an oversized single line.
- Prompt building includes the `Earlier:` line only when there is a previous summary.
- Each availability case maps to the expected `RecapAvailability`.
- Real model: one English and one Japanese transcript (from the existing fixtures' text) produce a non-empty summary and at most 6 key points. Skipped when `SystemLanguageModel.default.availability != .available`.

**`TranscriptionViewModelTests` additions:** Start resets recaps, Stop calls `finish`, Clear clears recaps, and a recap failure leaves `status` unchanged.

**`TranscriptModelTests` addition:** `TranscriptSegment.lines` formats labeled and unlabeled segments, and `fullText` output is unchanged.

**CI:** exclude the real-model test the same way `TranscriptionEngineTests` is excluded. GitHub's macOS VMs don't have Apple Intelligence.

**Manual check:** a live session with system audio playing a 15-minute talk, interval 5 minutes. Recaps append; the final recap appears on Stop; the panel shows the unavailable state with Apple Intelligence turned off; Japanese produces Japanese recaps.

## Documentation

- README: a **Recap** feature bullet, a note on the Apple Intelligence requirement, and the new files in the project-structure table.
