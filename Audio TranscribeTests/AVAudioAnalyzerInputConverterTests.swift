import AVFoundation
import Speech
import Testing
@testable import Transcripta

/// `AVAudioAnalyzerInputConverter` stands in for `AnalyzerInputConverter` on macOS 26, so it must hand the
/// analyzer every captured frame, resampled into the analyzer's format.
struct AVAudioAnalyzerInputConverterTests {
    /// The format `SpeechAnalyzer.bestAvailableAudioFormat` typically asks for.
    private let analyzerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    @Test func convertsBuffersIntoTheAnalyzerFormat() throws {
        let converter = AVAudioAnalyzerInputConverter(analyzerFormat: analyzerFormat)
        let inputs = try converter.convert(try sineBuffer(sampleRate: 48_000, channels: 2, frames: 4_800))
        #expect(!inputs.isEmpty)
        #expect(inputs.allSatisfy { $0.buffer.format == analyzerFormat })
    }

    @Test func preservesDurationAcrossBuffersAndFlush() throws {
        let converter = AVAudioAnalyzerInputConverter(analyzerFormat: analyzerFormat)
        var inputs: [AnalyzerInput] = []
        for _ in 0..<10 {
            inputs += try converter.convert(try sineBuffer(sampleRate: 48_000, channels: 2, frames: 4_800))
        }
        inputs += try converter.flush()

        // One second of 48 kHz audio is 16,000 frames at 16 kHz; allow for the resampler's edge effects.
        let frames = inputs.reduce(0) { $0 + Int($1.buffer.frameLength) }
        #expect(abs(frames - 16_000) <= 64)
    }

    @Test func handlesAnInputFormatChange() throws {
        let converter = AVAudioAnalyzerInputConverter(analyzerFormat: analyzerFormat)
        var inputs = try converter.convert(try sineBuffer(sampleRate: 48_000, channels: 2, frames: 4_800))
        inputs += try converter.convert(try sineBuffer(sampleRate: 44_100, channels: 1, frames: 4_410))
        inputs += try converter.flush()

        let frames = inputs.reduce(0) { $0 + Int($1.buffer.frameLength) }
        #expect(abs(frames - 3_200) <= 64)
        #expect(inputs.allSatisfy { $0.buffer.format == analyzerFormat })
    }

    @Test func flushWithoutInputProducesNothing() throws {
        let converter = AVAudioAnalyzerInputConverter(analyzerFormat: analyzerFormat)
        #expect(try converter.flush().isEmpty)
    }

    private func sineBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                samples[i] = 0.5 * sin(2 * .pi * 440 * Float(i) / Float(sampleRate))
            }
        }
        return buffer
    }
}
