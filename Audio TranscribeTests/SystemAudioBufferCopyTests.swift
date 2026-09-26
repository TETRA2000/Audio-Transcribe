#if os(macOS)
import AVFoundation
import Testing
@testable import Audio_Transcribe

/// `SystemAudioSource.copyBuffer` must deep-copy Core Audio's buffer list, because the IOProc's
/// `inputData` is only valid for the duration of the callback.
struct SystemAudioBufferCopyTests {
    private let frameCount: AVAudioFrameCount = 256

    @Test func copiesNonInterleavedStereo() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try assertCopyIsIndependent(format: format)
    }

    @Test func copiesInterleavedStereo() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        try assertCopyIsIndependent(format: format)
    }

    @Test func returnsNilForEmptyBuffer() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        source.frameLength = 0
        #expect(SystemAudioSource.copyBuffer(source.audioBufferList, format: format) == nil)
    }

    private func assertCopyIsIndependent(format: AVAudioFormat) throws {
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        source.frameLength = frameCount
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let expected = sourceBuffers.enumerated().map { index, buffer in
            let samples = floats(in: buffer)
            for i in samples.indices { samples[i] = Float(index * 10_000 + i) }
            return Array(samples)
        }

        let copy = try #require(SystemAudioSource.copyBuffer(source.audioBufferList, format: format))

        // Overwrite the source, as Core Audio would when it reuses the buffer for the next callback.
        for buffer in sourceBuffers {
            let samples = floats(in: buffer)
            for i in samples.indices { samples[i] = -1 }
        }

        #expect(copy.frameLength == frameCount)
        #expect(copy.format == format)
        let copied = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList).map { Array(floats(in: $0)) }
        #expect(copied == expected)
    }

    private func floats(in buffer: AudioBuffer) -> UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(
            start: buffer.mData?.assumingMemoryBound(to: Float.self),
            count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        )
    }
}
#endif
