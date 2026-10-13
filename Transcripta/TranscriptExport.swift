import SwiftUI
import UniformTypeIdentifiers

/// An export the user asked for. Combined goes through a save panel. Separate and both go into a folder the user picks.
struct ExportRequest: Identifiable, Equatable {
    let id = UUID()
    let kind: ExportKind
}

/// The Export menu items: one for a single-source transcript, three for a multi-source one.
struct ExportMenuItems: View {
    let hasSeparateSources: Bool
    @Binding var request: ExportRequest?

    var body: some View {
        if hasSeparateSources {
            Button("Export Combined…", systemImage: "square.and.arrow.down") { request = ExportRequest(kind: .combined) }
            Button("Export Separate…") { request = ExportRequest(kind: .separate) }
            Button("Export Combined + Separate…") { request = ExportRequest(kind: .combinedAndSeparate) }
        } else {
            Button("Export…", systemImage: "square.and.arrow.down") { request = ExportRequest(kind: .combined) }
        }
    }
}

extension View {
    /// Presents the save panel or folder picker for each `request`, then writes the files `makeFiles(kind, baseName)`
    /// returns. Existing files are never overwritten.
    func transcriptExporter(
        request: Binding<ExportRequest?>,
        makeFiles: @escaping (ExportKind, String) -> [ExportFile],
        onFailure: @escaping (Error) -> Void
    ) -> some View {
        modifier(TranscriptExporterModifier(request: request, makeFiles: makeFiles, onFailure: onFailure))
    }
}

private struct TranscriptExporterModifier: ViewModifier {
    @Binding var request: ExportRequest?
    let makeFiles: (ExportKind, String) -> [ExportFile]
    let onFailure: (Error) -> Void

    @State private var isExportingFile = false
    @State private var document = PlainTextDocument(text: "")
    @State private var fileName = ""
    @State private var isChoosingFolder = false
    @State private var folderKind = ExportKind.separate

    func body(content: Content) -> some View {
        content
            .onChange(of: request) {
                guard let request else { return }
                self.request = nil
                if request.kind == .combined {
                    guard let file = makeFiles(.combined, TranscriptExporter.defaultBaseName(for: Date())).first else { return }
                    document = PlainTextDocument(text: file.text)
                    fileName = (file.name as NSString).deletingPathExtension
                    isExportingFile = true
                } else {
                    folderKind = request.kind
                    isChoosingFolder = true
                }
            }
            .fileExporter(isPresented: $isExportingFile, document: document, contentType: .plainText, defaultFilename: fileName) { result in
                if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                    onFailure(error)
                }
            }
            .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
                guard case .success(let folder) = result else { return }
                do {
                    _ = try TranscriptExporter.write(
                        makeFiles(folderKind, TranscriptExporter.defaultBaseName(for: Date())),
                        toPickedFolder: folder
                    )
                } catch {
                    onFailure(error)
                }
            }
    }
}
