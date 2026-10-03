import Foundation

/// Which files an export produces for a multi-source transcript.
enum ExportKind: Hashable, CaseIterable {
    /// One file with every source on one timeline, each line labeled with its speaker.
    case combined
    /// One file per source.
    case separate
    case combinedAndSeparate
}

/// A text file to export: its file name and contents.
struct ExportFile: Equatable {
    let name: String
    let text: String
}

/// Formats transcripts as plain text and writes export files.
enum TranscriptExporter {
    /// One line per segment: `[MM:SS] Speaker: text`, or `[MM:SS] text` when the segment has no speaker.
    static func combined(_ segments: [TranscriptSegment]) -> String {
        segments.map { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let speaker = segment.speaker {
                return "[\(segment.formattedStart)] \(speaker): \(text)"
            }
            return "[\(segment.formattedStart)] \(text)"
        }
        .joined(separator: "\n")
    }

    /// One text per channel, in the same line format as `combined(_:)` but without speaker labels.
    static func separate(_ channels: [(label: String, segments: [TranscriptSegment])]) -> [(label: String, text: String)] {
        channels.map { channel in
            let unlabeled = channel.segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text) }
            return (label: channel.label, text: combined(unlabeled))
        }
    }

    /// The files for `kind`: the combined timeline first, then one file per channel.
    static func files(
        _ kind: ExportKind,
        baseName: String,
        combined segments: [TranscriptSegment],
        channels: [(label: String, segments: [TranscriptSegment])]
    ) -> [ExportFile] {
        var files: [ExportFile] = []
        if kind != .separate {
            files.append(ExportFile(name: fileName(base: baseName, label: nil), text: combined(segments)))
        }
        if kind != .combined {
            files += separate(channels).map { ExportFile(name: fileName(base: baseName, label: $0.label), text: $0.text) }
        }
        return files
    }

    /// `<base>.txt`, or `<base>-<label>.txt` with `/` and `:` in the label replaced so it stays one file name.
    static func fileName(base: String, label: String?) -> String {
        guard let label else { return "\(base).txt" }
        let safeLabel = label
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(base)-\(safeLabel).txt"
    }

    /// `Transcript yyyy-MM-dd HH.mm` in the local time zone.
    static func defaultBaseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Transcript \(formatter.string(from: date))"
    }

    /// Writes each file into `folder` as UTF-8. Instead of overwriting an existing file, a number is added before
    /// the extension (`T 2.txt`, `T 3.txt`, …). Returns the URLs written, in order.
    ///
    /// Each write refuses to replace an existing file (`.withoutOverwriting`), so a file that appears while
    /// exporting is never overwritten: the next number is tried instead. `beforeWriting` is called with each
    /// candidate URL just before writing it (tests use it to simulate such a file).
    static func write(
        _ files: [ExportFile],
        to folder: URL,
        beforeWriting: (URL) -> Void = { _ in }
    ) throws -> [URL] {
        try files.map { file in
            let data = Data(file.text.utf8)
            for url in candidateURLs(for: file.name, in: folder) {
                beforeWriting(url)
                do {
                    try data.write(to: url, options: .withoutOverwriting)
                    return url
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
            }
            preconditionFailure("candidateURLs is unbounded")
        }
    }

    /// `name`, then `name` with ` 2`, ` 3`, … added before the extension.
    private static func candidateURLs(for name: String, in folder: URL) -> some Sequence<URL> {
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        return (1...).lazy.map { counter in
            guard counter > 1 else { return folder.appending(path: name) }
            return folder.appending(path: pathExtension.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(pathExtension)")
        }
    }
}
