import Foundation
import SwiftData

/// A saved session in History. Every property has a default value and there are no unique constraints or
/// relationships, so the model can sync through CloudKit later. Today it is stored on this device only.
@Model
final class HistorySession {
    var id = UUID()
    var startedAt = Date.distantPast
    var duration: TimeInterval = 0
    /// `SessionKind.rawValue`.
    var kindRaw = "live"
    /// `TranscriptionLanguage.rawValue`.
    var languageRaw = "english"
    /// The live channels' labels in order. Empty for files.
    var sourceLabels: [String] = []
    var fileName: String?
    /// The summary's headline, kept here so the list never decodes the content.
    var headline: String?
    /// JSON-encoded `SessionContent`.
    @Attribute(.externalStorage) var contentData = Data()
    /// `HistorySearch.searchKey`: folded text the list's predicate searches.
    var searchKey = ""

    init(id: UUID) {
        self.id = id
    }

    var kind: SessionKind { SessionKind(rawValue: kindRaw) ?? .live }
    var language: TranscriptionLanguage { TranscriptionLanguage(rawValue: languageRaw) ?? .english }

    /// The line under the date: the headline, else the file name, else the sources.
    var subtitle: String { headline ?? fileName ?? sourceLabels.joined(separator: " + ") }

    /// Throws when the stored content can't be decoded.
    func content() throws -> SessionContent {
        try JSONDecoder().decode(SessionContent.self, from: contentData)
    }
}
