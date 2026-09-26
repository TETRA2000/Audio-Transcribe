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

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            statusBar
            Divider()
            transcriptView
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #endif
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result {
                Task { await viewModel.transcribe(fileURL: url) }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Source", selection: $viewModel.sourceKind) {
                ForEach(viewModel.availableSourceKinds) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isRecording || viewModel.isBusy)

            Picker("Language", selection: $viewModel.language) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isRecording || viewModel.isBusy)

            actionButton
        }
        .padding()
    }

    @ViewBuilder
    private var actionButton: some View {
        switch viewModel.sourceKind {
        case .microphone, .systemAudio:
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
            .disabled(viewModel.isBusy)
        case .file:
            Button {
                isImportingFile = true
            } label: {
                Label("Open File…", systemImage: "folder")
            }
            .disabled(viewModel.isBusy)
        }
    }

    @ViewBuilder
    private var statusBar: some View {
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
                        transcriptRow(timestamp: segment.start, text: segment.text)
                            .id(segment.id)
                    }
                    if !viewModel.volatileText.isEmpty {
                        Text(viewModel.volatileText)
                            .foregroundStyle(.secondary)
                            .id("volatile")
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.segments.count) {
                withAnimation {
                    proxy.scrollTo(viewModel.segments.last?.id, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.volatileText) {
                proxy.scrollTo("volatile", anchor: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.segments.isEmpty {
                HStack {
                    Button("Clear", role: .destructive) {
                        viewModel.clear()
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
        }
    }

    private func transcriptRow(timestamp: TimeInterval, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(formattedTimestamp(timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(text)
        }
    }

    private func formattedTimestamp(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let totalSeconds = Int(seconds)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
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
