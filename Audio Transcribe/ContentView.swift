import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ContentView: View {
    private enum ImportPurpose {
        case audioFile
        case exportFolder(ExportKind)

        var contentTypes: [UTType] {
            switch self {
            case .audioFile: [.audio, .movie]
            case .exportFolder: [.folder]
            }
        }
    }

    @State private var viewModel = TranscriptionViewModel()
    @State private var isImporting = false
    @State private var importPurpose = ImportPurpose.audioFile
    @State private var isExportingFile = false
    @State private var exportDocument = PlainTextDocument(text: "")
    @State private var exportFileName = ""

    private var isLocked: Bool { viewModel.isRecording || viewModel.isBusy }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            statusBar
            Divider()
            transcriptView
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        #endif
        .fileImporter(isPresented: $isImporting, allowedContentTypes: importPurpose.contentTypes) { result in
            guard case .success(let url) = result else { return }
            switch importPurpose {
            case .audioFile:
                Task { await viewModel.transcribe(fileURL: url) }
            case .exportFolder(let kind):
                viewModel.export(kind, toFolder: url)
            }
        }
        .fileExporter(
            isPresented: $isExportingFile,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportFileName
        ) { result in
            if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                viewModel.status = .failed(error.localizedDescription)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $viewModel.mode) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isLocked)

            if viewModel.mode == .live {
                LiveSourcesView(viewModel: viewModel)
                    .disabled(isLocked)
            }

            Picker("Language", selection: $viewModel.language) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isLocked)

            actionButton
        }
        .padding()
    }

    @ViewBuilder
    private var actionButton: some View {
        switch viewModel.mode {
        case .live:
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
            .disabled(viewModel.isBusy || (!viewModel.isRecording && !viewModel.canStart))
        case .file:
            Button {
                importPurpose = .audioFile
                isImporting = true
            } label: {
                Label("Open File…", systemImage: "folder")
            }
            .disabled(viewModel.isBusy)
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusContent
            if let warning = viewModel.channelWarning {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
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
                        transcriptRow(segment)
                            .id(segment.id)
                    }
                    ForEach(viewModel.volatileLines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let label = line.label {
                                speakerTag(label)
                            }
                            Text(line.text.trimmingCharacters(in: .whitespaces))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Color.clear
                        .frame(height: 0)
                        .id("volatile")
                }
                .padding()
            }
            .onChange(of: viewModel.segments.count) {
                withAnimation {
                    proxy.scrollTo(viewModel.segments.last?.id, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.volatileLines) {
                proxy.scrollTo("volatile", anchor: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.segments.isEmpty {
                transcriptActions
            }
        }
    }

    private var transcriptActions: some View {
        HStack {
            if !viewModel.isRecording {
                Button("Clear", role: .destructive) {
                    viewModel.clear()
                }
            }
            Spacer()
            if !viewModel.isRecording {
                exportControl
            }
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

    @ViewBuilder
    private var exportControl: some View {
        if viewModel.hasSeparateSources {
            Menu {
                Button("Combined…") { exportCombinedFile() }
                Button("Separate…") { chooseExportFolder(for: .separate) }
                Button("Combined + Separate…") { chooseExportFolder(for: .combinedAndSeparate) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .fixedSize()
        } else {
            Button {
                exportCombinedFile()
            } label: {
                Label("Export…", systemImage: "square.and.arrow.down")
            }
        }
    }

    private func exportCombinedFile() {
        let baseName = TranscriptExporter.defaultBaseName(for: Date())
        guard let file = viewModel.exportFiles(.combined, baseName: baseName).first else { return }
        exportDocument = PlainTextDocument(text: file.text)
        exportFileName = (file.name as NSString).deletingPathExtension
        isExportingFile = true
    }

    private func chooseExportFolder(for kind: ExportKind) {
        importPurpose = .exportFolder(kind)
        isImporting = true
    }

    private func transcriptRow(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(segment.formattedStart)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            if let speaker = segment.speaker {
                speakerTag(speaker)
            }
            Text(segment.text.trimmingCharacters(in: .whitespaces))
        }
    }

    /// A small colored label: the first source (the microphone when enabled) uses the accent color, others orange.
    private func speakerTag(_ speaker: String) -> some View {
        let color: Color = speaker == viewModel.channels.first?.label ? .accentColor : .orange
        return Text(speaker)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
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
