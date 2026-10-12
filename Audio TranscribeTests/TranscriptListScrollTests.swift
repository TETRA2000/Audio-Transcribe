#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Audio_Transcribe

/// Hosts the transcript in a real window, with a bottom bar like ContentView's Copy/Share bar, and feeds it through a
/// live channel the way the transcriber does: bursts of in-progress text, then a final line followed straight away
/// by the next line's in-progress text.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TranscriptListScrollTests {
    static let sentences = [
        " What you learn in one field, even abstract mathematics, can pay off in another.",
        " That's it.",
        " What we have learned over hundreds of years is that understanding is the key to power.",
        " And you feel like you're running into answers without understanding more and more.",
        " Yeah, we are.",
    ]

    @Test func followsTheEndOfTheTranscript() async throws {
        let viewModel = TranscriptionViewModel(recapGenerator: FakeRecapGenerator())
        let transcriber = FakeTranscriber()
        let channel = LiveChannel(kind: .systemAudio, label: "All system audio", source: FakeSource().liveAudioSource, transcriber: transcriber)
        try await channel.start(language: .english, sessionStart: Date(), labelSegments: false)
        defer { Task { try? await channel.stop() } }
        viewModel.channels = [channel]
        viewModel.status = .recording

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TranscriptList(viewModel: viewModel)
            .safeAreaInset(edge: .bottom) {
                HStack { Spacer(); Button("Copy") {} }.padding().background(.bar)
            })
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        var hidden: [Int] = []
        var time: TimeInterval = 0
        for round in 0..<30 {
            let sentence = Self.sentences[round % Self.sentences.count]
            let words = sentence.split(separator: " ")
            var count = 1
            while count <= words.count {
                for _ in 0..<3 where count <= words.count {
                    await transcriber.emit(TranscriptUpdate(text: " " + words[..<count].joined(separator: " "), start: time, end: time + 1, isFinal: false))
                    count += 1
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            await transcriber.emit(TranscriptUpdate(text: sentence, start: time, end: time + 3, isFinal: true))
            await transcriber.emit(TranscriptUpdate(text: " And that's why", start: time + 3, end: time + 4, isFinal: false))
            time += 3
            try await Task.sleep(for: .milliseconds(150))
            hidden.append(Int(try hiddenBelow(in: window).rounded()))
        }

        #expect(viewModel.segments.count == 30)
        // Points of content below the visible area, after each line. Early lines fit without scrolling (negative).
        #expect(hidden.allSatisfy { $0 <= 1 }, "content hidden below the view after each line: \(hidden)")
    }

    /// How far the end of the content is below the bottom of the visible area, above the inset bar.
    private func hiddenBelow(in window: NSWindow) throws -> CGFloat {
        let scrollView = try #require(Self.scrollView(in: window.contentView!))
        let documentHeight = try #require(scrollView.documentView).frame.height
        let visible = scrollView.contentView.bounds
        return documentHeight - (visible.maxY - scrollView.contentInsets.bottom)
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }
}
#endif
