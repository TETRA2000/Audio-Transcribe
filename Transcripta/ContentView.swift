import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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

    let history: Result<HistoryStore, any Error>
    @State private var viewModel: TranscriptionViewModel
    @State private var pendingDelete: Set<UUID> = []
    #if os(macOS)
    @State private var sidebarSelection: Set<HistorySelection> = [.currentSession]
    @State private var historyQuery = ""
    #else
    @State private var showsHistory = false
    #endif

    init(history: Result<HistoryStore, any Error>) {
        self.history = history
        _viewModel = State(initialValue: TranscriptionViewModel(history: try? history.get()))
    }

    private var historyStore: HistoryStore? { try? history.get() }

    private var historyError: String? {
        if case .failure(let error) = history { error.localizedDescription } else { nil }
    }
    @State private var isImporting = false
    @State private var importPurpose = ImportPurpose.audioFile
    @State private var isExportingFile = false
    @State private var exportDocument = PlainTextDocument(text: "")
    @State private var exportFileName = ""
    #if os(macOS)
    @State private var showsRecap = true
    #else
    @State private var showsRecap = false
    #endif

    private var isLocked: Bool { viewModel.isRecording || viewModel.isBusy }

    var body: some View {
        layout
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 440)
        #endif
        .historyDeleteConfirmation(pending: $pendingDelete, store: historyStore) { ids in
            #if os(macOS)
            sidebarSelection.subtract(ids.map(HistorySelection.session))
            if sidebarSelection.isEmpty { sidebarSelection = [.currentSession] }
            #endif
        }
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

    /// The live session's Recap panel.
    private func withLiveRecap(_ content: some View) -> some View {
        content.inspector(isPresented: $showsRecap) {
            RecapView(
                scheduler: viewModel.recap,
                isRecording: viewModel.isRecording,
                isFileMode: viewModel.mode == .file,
                onRetry: { id in viewModel.retryRecap(id) },
                onSummarizeAgain: { Task { await viewModel.summarizeAgain() } }
            )
            .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
            .presentationDragIndicator(.visible)
        }
    }

    #if os(macOS)
    /// macOS: the sidebar lists the current session, then History. The detail shows whichever is selected.
    private var layout: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Label {
                    Text("Current Session")
                } icon: {
                    Image(systemName: viewModel.isRecording ? "record.circle.fill" : "waveform")
                        .foregroundStyle(viewModel.isRecording ? Color.red : Color.accentColor)
                }
                .tag(HistorySelection.currentSession)
                if historyStore != nil {
                    HistorySections(query: historyQuery, onDelete: { pendingDelete = $0 })
                } else {
                    Section("History") {
                        Text("History couldn't be opened. \(historyError ?? "")")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $historyQuery, placement: .sidebar, prompt: "Search History")
            .onDeleteCommand {
                if !selectedSessionIDs.isEmpty { pendingDelete = selectedSessionIDs }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .historyContainer(historyStore)
    }

    private var selectedSessionIDs: Set<UUID> {
        Set(sidebarSelection.compactMap { item -> UUID? in
            if case .session(let id) = item { return id }
            return nil
        })
    }

    @ViewBuilder
    private var detail: some View {
        let ids = selectedSessionIDs
        if ids.count == 1, let id = ids.first, let session = try? historyStore?.session(id: id) {
            HistoryDetail(session: session, query: historyQuery, onDelete: { pendingDelete = [id] })
                .id(id)
        } else if ids.count > 1 {
            ContentUnavailableView {
                Label("\(ids.count) Sessions Selected", systemImage: "doc.on.doc")
            } actions: {
                Button("Delete \(ids.count) Sessions", role: .destructive) { pendingDelete = ids }
            }
        } else {
            withLiveRecap(
                VStack(spacing: 0) {
                    controls
                    Divider()
                    statusBar
                    Divider()
                    transcriptView
                }
            )
        }
    }
    #else
    /// iOS: the settings that frame a session (mode, language) and the recap live in the navigation bar, the
    /// transcript fills the screen, and the one primary action sits at the bottom within thumb reach.
    private var layout: some View {
        withLiveRecap(iOSStack)
            .sheet(isPresented: $showsHistory) {
                HistoryScreen(store: historyStore, storeError: historyError)
            }
    }

    private var iOSStack: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                if viewModel.segments.isEmpty && viewModel.volatileLines.isEmpty {
                    emptyTranscript
                } else {
                    TranscriptList(viewModel: viewModel)
                }
            }
            .safeAreaBar(edge: .bottom) {
                bottomBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $viewModel.mode) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 116)
                    .disabled(isLocked)
                }
                ToolbarItem(placement: .topBarLeading) {
                    languageMenu
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showsHistory = true
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        showsRecap.toggle()
                    } label: {
                        Label("Recap", systemImage: "apple.intelligence")
                    }
                    transcriptMenu
                }
            }
        }
    }

    private var languageMenu: some View {
        Menu {
            Picker("Language", selection: $viewModel.language) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
        } label: {
            Label(viewModel.language.displayName, systemImage: "globe")
        }
        .disabled(isLocked)
        .accessibilityLabel("Language: \(viewModel.language.displayName)")
    }

    /// Copy, share, export and clear: everything that acts on the finished transcript.
    private var transcriptMenu: some View {
        Menu {
            Button {
                Pasteboard.copy(viewModel.fullText)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            ShareLink(item: viewModel.fullText) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            if !viewModel.isRecording {
                exportControl
                Divider()
                Button("Clear Transcript", systemImage: "trash", role: .destructive) {
                    viewModel.clear()
                }
            }
        } label: {
            Label("Transcript", systemImage: "ellipsis")
        }
        .disabled(viewModel.segments.isEmpty)
    }

    private var emptyTranscript: some View {
        ContentUnavailableView {
            switch viewModel.mode {
            case .live: Label("Ready to Listen", systemImage: "waveform")
            case .file: Label("Transcribe a File", systemImage: "doc.badge.plus")
            }
        } description: {
            switch viewModel.mode {
            case .live: Text("Tap Start to transcribe from the microphone in \(viewModel.language.displayName).")
            case .file: Text("Choose an audio or video file to transcribe it in \(viewModel.language.displayName).")
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if viewModel.mode == .live {
                LiveSourcesView(viewModel: viewModel)
                    .font(.footnote)
            }
            primaryButton
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var primaryButton: some View {
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
                      systemImage: viewModel.isRecording ? "stop.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(viewModel.isRecording ? .red : .accentColor)
            .disabled(viewModel.isBusy || (!viewModel.isRecording && !viewModel.canStart))
        case .file:
            Button {
                importPurpose = .audioFile
                isImporting = true
            } label: {
                Label("Open File…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isBusy)
        }
    }
    #endif

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

            HStack {
                actionButton
                Spacer()
                Button {
                    showsRecap.toggle()
                } label: {
                    Label("Recap", systemImage: "sidebar.trailing")
                }
                .help(showsRecap ? "Hide recaps" : "Show recaps")
            }
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
            if let warning = viewModel.historyWarning {
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
        TranscriptList(viewModel: viewModel)
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
                Pasteboard.copy(viewModel.fullText)
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
}

private extension View {
    /// Puts History's container in the environment, when History could be opened.
    @ViewBuilder
    func historyContainer(_ store: HistoryStore?) -> some View {
        if let store {
            modelContainer(store.container)
        } else {
            self
        }
    }
}

#Preview {
    ContentView(history: Result { try HistoryStore(inMemory: true) })
}
