# History: keep past transcripts and summaries, and search them

Date: 2026-10-12
Status: Draft, awaiting review

## Goal

Every live session and every transcribed file is saved automatically on the device, with its recaps and summary. The user can browse past sessions, open one to reread it, copy, share or export it, and **search across all of them** to find the session where something was said.

### Success criteria

- After Stop (or when a file finishes transcribing) the session appears in History with no user action. If the app crashes or quits during a recording, at most the last 30 seconds are lost.
- A summary that arrives or is regenerated after the session was saved updates the same History entry.
- Typing a word or phrase in History's search field narrows the list to sessions that contain it anywhere (transcript, summary, recaps, file name, speaker labels), each with a snippet around the match. This works for English and Japanese.
- Opening a session from a search highlights the matches and steps through them.
- Browsing History never disturbs the current session, including while recording.
- Transcription works exactly as before if History can't be opened or a save fails.

### Non-goals

- Saving audio. History holds text only. For files, the file name is kept but not the file.
- Sync between devices. Data stays on this device. The model follows CloudKit's rules so sync can be added later.
- Renaming sessions.
- Automatic deletion (keep N days, size limits).
- Loading a past session back into the main screen, or continuing it.
- Ranked or fuzzy search. Search is a substring match.

## Decisions

| Question | Decision |
|---|---|
| Purpose | Reread and reuse past sessions, with search across them as a core feature. |
| When saved | Automatically, always. Sessions with no final text are not saved. |
| Sync | None. On this device only, CloudKit-compatible model. |
| Opening a session | A separate read-only view. The current session is never touched. |
| Row title | Date and time, with the summary headline under it (falling back to the file name or the sources). |
| Search | Matches transcript, summary, recaps, file name and speakers. List rows show a snippet. The opened session highlights matches with next/previous. |
| Deleting | Manual only: swipe, context menu, ⌫, multi-select. Always confirmed. |
| Clear Transcript | Clears the screen only. The session stays in History. |
| Storage | SwiftData. |

## Approach

SwiftData with one `@Model` per session. Bulky content (segments, recaps, summary) is one encoded blob in external storage, so the list never decodes transcripts. A denormalized, pre-folded `searchKey` makes list search a plain `contains` predicate that behaves the same everywhere.

Approaches considered and rejected:
- **One JSON file per session plus an index file.** Simple and transparent, but the store (atomic writes, caching, change notification to the UI, migration) would be hand-written, and adding sync later would mean a rewrite.
- **SQLite with FTS5.** Real indexing and ranking, but it needs a dependency or C glue. The default tokenizer doesn't segment Japanese, and the trigram tokenizer can't match queries under 3 characters. CloudKit sync would be hard. A linear scan is fast enough at personal scale (hundreds of hour-long sessions is megabytes of text).

## Components

New files in `Transcripta/`, each with one job.

### `HistorySession.swift`: model and payload

```swift
@Model final class HistorySession {
    var id = UUID()
    var startedAt = Date.distantPast
    var duration: TimeInterval = 0
    var kindRaw = "live"              // "live" | "file"
    var languageRaw = "english"       // TranscriptionLanguage.rawValue
    var sourceLabels: [String] = []   // live channel labels in order, e.g. ["You", "Zoom"]
    var fileName: String?
    var headline: String?             // summary headline, cached for the list row
    @Attribute(.externalStorage) var contentData = Data()   // JSON-encoded SessionContent
    var searchKey = ""                // folded searchable text, see HistorySearch
}

struct SessionContent: Codable, Equatable {
    struct Segment: Codable, Equatable { var start, end: TimeInterval; var text: String; var speaker: String? }
    struct Recap: Codable, Equatable { var windowStart, windowEnd: TimeInterval; var isFinal: Bool; var headline: String; var keyPoints: [String] }
    var segments: [Segment]
    var recaps: [Recap]               // finished recaps only; failed ones are not saved
    var overview: RecapContent?       // RecapContent becomes Codable
}
```

Every property has a default and there are no unique constraints or required relationships, which keeps the model CloudKit-compatible. Typed accessors (`kind`, `language`, `content`) wrap the raw fields. Decoding `contentData` throws rather than returning empty content, so a damaged entry can be reported.

### `SessionSnapshot.swift`: current state to History content

A pure function from the view model's state (segments, channels, recap entries, overview, language, mode, file name, session start and duration) to the metadata plus `SessionContent`. It returns `nil` when there are no final segments. It also produces the `searchKey` via `HistorySearch`.

### `HistoryStore.swift`: persistence

`@MainActor` wrapper around a `ModelContainer`/`ModelContext`:

- `init(inMemory: Bool = false) throws`
- `upsert(id: UUID, snapshot: SessionSnapshot) throws`: inserts the session the first time, updates it after that.
- `delete(_ ids: [UUID]) throws`
- `container` for the views' `@Query`.

The app builds one on-disk store at launch. If that fails, the app keeps the error to show in History and passes `nil` to the view model.

### `HistorySearch.swift`: search helpers

Pure functions:

- `fold(_:)`: case-, diacritic- and width-insensitive folding (`folding(options:locale:)`), so ＡＢＣ matches abc.
- `searchKey(for:)`: the folded concatenation of the transcript, summary, recaps, file name and speaker labels.
- `snippet(in:query:)`: about 80 characters around the first match in the **original** text, with ellipses where it was cut and the match range for bolding. Uses `range(of:options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])`.
- `matches(in:query:)`: every match in a session's segments and recaps, in display order, for highlighting and next/previous.

The list predicate is `searchKey.contains(fold(query))`. An empty query shows every session.

### `HistoryList.swift` and `HistoryDetail.swift`: views

- **List.** `@Query` sorted by `startedAt` descending, fetching without `contentData`. Grouped into Today, Yesterday, This Week, Earlier. Each row:
  - the date and time ("Oct 12, 14:30");
  - the headline, or the file name, or the sources;
  - the duration and sources in secondary text. While searching, this line is the snippet instead, built only for visible rows by decoding that session's content.
- **Detail.** Read-only transcript plus summary and recaps, through the shared views below. The toolbar has Copy, Share, Export (combined / separate / both, as today) and Delete. When opened from a search, matches are highlighted and a small bar ("3 of 12" with previous/next) scrolls to each.
- **Empty states.** No sessions: "Transcripts you record or transcribe appear here." No results: "No sessions match “query”." Store unavailable: "History couldn't be opened" with the reason.

## Platform layout

**macOS.** The window becomes a `NavigationSplitView`.

- The sidebar's first row is **Current Session**: today's controls, status bar and transcript, unchanged. It shows a red dot while recording.
- Below it is the searchable history list.
- Selecting a saved session shows its detail in the detail column. The Recap inspector shows that session's summary and recaps.
- Delete is in the toolbar, in the context menu and on ⌫, with multi-select.

**iOS / iPadOS / visionOS.**

- The navigation bar gets a **History** button (`clock.arrow.circlepath`) next to Recap. It presents a sheet with its own `NavigationStack` and the searchable list.
- Swipe deletes a row. Edit turns on multi-select.
- Tapping a row pushes the detail. Its Recap button opens the summary and recaps as a sheet, and its ⋯ menu holds Copy, Share, Export and Delete.
- Recording continues under the sheet.

## Changes to existing code

- **`TranscriptionViewModel`**
  - Gets `history: HistoryStore?` and `historyID: UUID?`, and records the session start date and file name.
  - Calls `upsert` at these points:
    - each recap tick while recording (checkpoint);
    - after the channels drain on Stop or when the last source ends;
    - after `endRecaps` / the final recap and overview;
    - after a file transcription finishes, and after its summary;
    - after `summarizeAgain` and `retryRecap` finish.
  - `clear()` resets `historyID`. A failed save sets a non-blocking `historyWarning` and never changes `status`.
- **`TranscriptList`** becomes a plain view that takes segments, volatile lines and optional highlight ranges and current match. A thin wrapper keeps today's call sites.
- **`RecapView`** is split the same way. A plain view takes entries, overview and availability, with optional Retry and Summarize Again actions. Saved sessions pass none, so they're read-only.
- **`TranscriptExporter`** gets a way to export from `SessionContent`. "Separate" regroups segments by `speaker` in `sourceLabels` order, because each channel's label is its segments' speaker.
- **`RecapContent`** conforms to `Codable`.
- **`ContentView` / `MyApp`**
  - `MyApp` creates the `HistoryStore` and attaches its container with `.modelContainer`.
  - On macOS, `ContentView`'s layout moves into the split view.
  - On iOS, the toolbar gets the History button and sheet.

## Error handling

| Failure | Behavior |
|---|---|
| Store can't be opened at launch | The app works normally without History. The History list explains why. The store file is never deleted automatically. |
| A save fails | Logged, plus a non-blocking warning. Transcription and recaps carry on. The next save point retries. |
| A session's content can't be decoded | Its detail says "This session couldn't be read". It can still be deleted. Its row still shows the stored metadata. |
| Delete fails | An alert with the reason. The row stays. |

## Testing

Swift Testing, with an in-memory `HistoryStore` and the existing recap test doubles.

- **`SessionSnapshotTests`**
  - multi-source live, single-source live and file sessions map correctly;
  - failed recaps are left out;
  - the overview is included when done;
  - no final segments gives `nil`.
- **`HistoryStoreTests`**
  - upsert inserts once, then updates the same id;
  - delete removes the session;
  - the folded `contains` predicate returns the expected sessions.
- **View model integration**
  - Stop saves the session;
  - a later overview updates the same entry;
  - Summarize Again updates it;
  - `clear()` makes the next session a new entry;
  - a recap tick writes a checkpoint;
  - an empty session isn't saved;
  - a failing store sets `historyWarning` and leaves `status` alone.
- **`HistorySearchTests`**
  - folding: case, accents, full-width and half-width;
  - a Japanese substring;
  - snippet trimming at the start and end of the text and the reported match range;
  - matches found across segments and recaps, in order.
- **Export parity.** Exporting a saved session produces the same files as exporting the identical live session, for combined and separate.

## Documentation

The README Features section gets a **History** entry: sessions are saved automatically on this device with their recaps and summary, can be searched, reread, exported and deleted, and never leave the device.
