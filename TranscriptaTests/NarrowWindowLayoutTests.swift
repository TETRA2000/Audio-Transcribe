#if os(macOS)
import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Transcripta

/// Lays out the window at the narrow widths a small screen forces (the CI runner's screen is 1024 pt wide) with the
/// Recap panel open. An `.inspector` inside the split view's detail column made AppKit loop on its constraints there
/// and abort the app, so these tests crash the test host if that comes back.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct NarrowWindowLayoutTests {
    @Test(arguments: [1024.0, 760.0])
    func liveSessionLaysOut(width: Double) async throws {
        try await layOut(ContentView(history: Result { try HistoryStore(inMemory: true) }), width: width)
    }

    @Test(arguments: [1024.0, 760.0])
    func savedSessionLaysOut(width: Double) async throws {
        let store = try HistoryStore(inMemory: true)
        let id = UUID()
        try store.upsert(id: id, snapshot: SessionSnapshot.make(
            kind: .file, language: .english, startedAt: Date(), fileName: "a.m4a", sourceLabels: [],
            segments: [TranscriptSegment(start: 0, end: 1, text: "Hello")], recaps: [], overview: nil
        )!)
        let session = try #require(try store.session(id: id))
        let splitView = NavigationSplitView {
            List { Text("Sidebar") }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            HistoryDetail(session: session, onDelete: {})
        }
        .frame(minWidth: 760, minHeight: 440)
        .modelContainer(store.container)
        try await layOut(splitView, width: width)
    }

    private func layOut(_ view: some View, width: Double) async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 80, width: width, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Give AppKit several display cycles to run its constraint passes.
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(window.frame.width >= width)
    }
}
#endif
