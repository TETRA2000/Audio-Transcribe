import AVFoundation
import Speech

/// Turns captured live audio into analyzer input in the format the `SpeechAnalyzer` asked for.
nonisolated protocol LiveAudioConverter: AnyObject {
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput]
    /// Returns whatever audio the converter is still holding. Call once, after the last buffer.
    func flush() throws -> [AnalyzerInput]
}

/// Uses the Speech framework's own converter, available from the 27 releases.
@available(macOS 27, iOS 27, visionOS 27, *)
nonisolated final class SystemAnalyzerInputConverter: LiveAudioConverter {
    private let converter: AnalyzerInputConverter

    init(analyzerFormat: AVAudioFormat) {
        converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput] {
        Array(try converter.convert(buffer, at: nil))
    }

    func flush() throws -> [AnalyzerInput] {
        Array(try converter.flush())
    }
}

/// Converts with `AVAudioConverter`, for macOS 26, which has no `AnalyzerInputConverter`.
nonisolated final class AVAudioAnalyzerInputConverter: LiveAudioConverter {
    private let analyzerFormat: AVAudioFormat
    /// Kept across buffers so the resampler's state carries over. Rebuilt when the input format changes,
    /// e.g. when the system default input device changes.
    private var converter: AVAudioConverter?

    init(analyzerFormat: AVAudioFormat) {
        self.analyzerFormat = analyzerFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput] {
        var inputs: [AnalyzerInput] = []
        if let converter, converter.inputFormat != buffer.format {
            inputs = try drain(converter)
            self.converter = nil
        }
        if converter == nil {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: analyzerFormat) else {
                throw TranscriptionError.audioFormatUnavailable
            }
            converter = newConverter
        }
        return inputs + (try run(converter!, input: buffer, then: .noDataNow))
    }

    func flush() throws -> [AnalyzerInput] {
        guard let converter else { return [] }
        self.converter = nil
        return try drain(converter)
    }

    private func drain(_ converter: AVAudioConverter) throws -> [AnalyzerInput] {
        try run(converter, input: nil, then: .endOfStream)
    }

    /// Feeds `input` (if any) to `converter`, then reports `status` once it has been consumed, and collects
    /// everything the converter produces until it needs more input.
    private func run(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, then status: AVAudioConverterInputStatus) throws -> [AnalyzerInput] {
        var pending = input
        var inputs: [AnalyzerInput] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: 4_096) else {
                throw TranscriptionError.audioFormatUnavailable
            }
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { _, inputStatus in
                if let buffer = pending {
                    pending = nil
                    inputStatus.pointee = .haveData
                    return buffer
                }
                inputStatus.pointee = status
                return nil
            }
            if let error { throw error }
            if output.frameLength > 0 {
                inputs.append(AnalyzerInput(buffer: output))
            }
            switch result {
            case .haveData: continue
            case .inputRanDry, .endOfStream: return inputs
            case .error: throw TranscriptionError.audioFormatUnavailable
            @unknown default: return inputs
            }
        }
    }
}
