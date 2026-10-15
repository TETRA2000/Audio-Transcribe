# Transcripta

## Known platform bugs

### Recap panel layout loop (macOS 26 hang, macOS 27 abort)

On macOS, presenting the Recap panel with `.inspector` sends SwiftUI and AppKit into an endless layout loop on the
main thread. On macOS 27 AppKit aborts the app (seen in narrow windows, below about 1050 pt, with the inspector in a
`NavigationSplitView` detail column). On macOS 26 the app doesn't abort: it hangs and its memory keeps growing (a
spindump from macOS 26.7.1 showed an 18 GB footprint after 75 minutes).

- **Signature in a spindump:** the main thread never returns from one `NSHostingView.beginTransaction` →
  `GraphHost.runTransaction` → `AG::Subgraph::update` pass. The work repeats in
  `SelectionOverlay.updateNSView(_:context:)` (the NSTextField SwiftUI builds for `.textSelection(.enabled)`) and in
  `measureMin:max:ideal:` adding and removing NSLayoutConstraints. No audio I/O thread is involved.
- **Trigger:** the selectable recap text (`RecapContentView` in `RecapView.swift`) shown inside an inspector.
- **Fix:** on macOS the panel is a fixed-width trailing column (`recapPanel` in `RecapPanel.swift`); only iOS uses
  `.inspector`. Don't bring `.inspector` back on macOS. `NarrowWindowLayoutTests` crashes the test host if the loop
  returns, but it runs on macOS 27 only. Check macOS 26 by hand: narrow window, Recap panel open, recaps showing.
- **Not yet confirmed:** that the column layout fixes the macOS 26 hang. Builds up to 31a66f4 still use the
  inspector.
