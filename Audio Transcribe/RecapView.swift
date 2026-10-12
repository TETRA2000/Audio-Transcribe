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
                Text(content.headline)
                    .fontWeight(.semibold)
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
            headline: "Shortlist down to Northwind and Larkspur",
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
