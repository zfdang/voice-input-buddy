import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("ATVV protocol")
struct ATVVProtocolTests {
    @Test func invalidFrameSizesCannotStartOrAccumulateAudio() {
        for size in [513, 65_535] {
            let bytes: [UInt8] = [0x0B, 1, 0, 2, 3, UInt8(size >> 8), UInt8(size & 255)]
            #expect(ATVVCapabilities.parse(Data(bytes)).map { ATVVProtocol.supportsFrameSize($0.frameSize) } == false)
            var accumulator = FrameAccumulator()
            #expect(accumulator.append(Data(repeating: 1, count: 4_000), frameSize: size).isEmpty)
            #expect(accumulator.pending.isEmpty)
        }
        for size in [0, 1, 512] {
            let bytes: [UInt8] = [0x0B, 1, 0, 2, 3, UInt8(size >> 8), UInt8(size & 255)]
            #expect(ATVVCapabilities.parse(Data(bytes))?.frameSize == (size == 0 ? 120 : size))
        }
    }

    @Test func parsesVersionOneCapabilities() {
        let data = Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0x78])
        let capabilities = ATVVCapabilities.parse(data)

        #expect(capabilities?.version == 0x0100)
        #expect(capabilities?.selectedCodec == 0x02)
        #expect(capabilities?.sampleRate == 16_000)
        #expect(capabilities?.frameSize == 120)
    }

    @Test func acceptsLegacyCodecLayoutAdvertisedAsVersionOne() {
        let data = Data([0x0B, 0x01, 0x00, 0x00, 0x02, 0x00, 0x78, 0x00, 0x00])
        let capabilities = ATVVCapabilities.parse(data)

        #expect(capabilities?.selectedCodec == 0x02)
        #expect(capabilities?.interaction == 0x03)
    }

    @Test func rejectsMalformedCapabilities() {
        #expect(ATVVCapabilities.parse(Data()) == nil)
        #expect(ATVVCapabilities.parse(Data([0x0B, 0x01])) == nil)
        #expect(ATVVCapabilities.parse(Data([0x00, 0x01, 0x00, 0x02, 3, 0, 120])) == nil)
    }

    @Test func versionSpecificMicrophoneCommands() {
        #expect(ATVVProtocol.microphoneOpen(version: 0x0100, codec: 0x02) == Data([0x0C, 0x00]))
        #expect(ATVVProtocol.microphoneOpen(version: 0x0001, codec: 0x02) == Data([0x0C, 0x00, 0x02]))
        #expect(ATVVProtocol.microphoneClose(version: 0x0100, sessionID: 7) == Data([0x0D, 0x07]))
        #expect(ATVVProtocol.microphoneClose(version: 0x0001, sessionID: 7) == Data([0x0D]))
        #expect(ATVVProtocol.microphoneExtend(version: 0x0100, sessionID: 7) == Data([0x0E, 0x07]))
        #expect(ATVVProtocol.microphoneExtend(version: 0x0001, sessionID: 7) == nil)
    }

    @Test func audioRateGateOnlyAccepts16kHz() {
        #expect(ATVVProtocol.supportsAudio(sampleRate: 16_000))
        #expect(!ATVVProtocol.supportsAudio(sampleRate: 8_000))
    }

    @Test func decoderUsesHighNibbleBeforeLowNibble() {
        let decoder = IMAADPCMDecoder()
        #expect(decoder.decode(Data([0x11])) == [1, 2])

        decoder.reset()
        #expect(decoder.decode(Data([0x7F])) == [11, -19])
    }

    @Test func decoderClampsState() {
        let decoder = IMAADPCMDecoder()
        decoder.reset(predictor: 100_000, stepIndex: 1_000)
        #expect(decoder.predictor == 32_767)
        #expect(decoder.stepIndex == 88)
    }

    @Test func postprocessorAppliesSmoothingAndClampedGain() {
        let unchanged = PCMPostprocessor().process([0, 1000, 0], gainDB: 0)
        #expect(unchanged == [0, 250, 500])

        let clipped = PCMPostprocessor().process([20_000], gainDB: 24)
        #expect(clipped == [Int16.max])
        #expect(PCMPostprocessor().process([20_000], gainDB: .infinity) == [20_000])
    }

    @Test func smoothingIsIndependentOfFrameBoundariesAndResetClearsHistory() {
        let signal: [Int16] = (0..<960).map { Int16(($0 * 997) % 60000 - 30000) }
        let reference = PCMPostprocessor().process(signal, gainDB: 3)
        let processor = PCMPostprocessor()
        var chunks: [Int16] = []
        for offset in stride(from: 0, to: signal.count, by: 240) {
            chunks += processor.process(Array(signal[offset..<(offset + 240)]), gainDB: 3)
        }
        #expect(chunks == reference)
        processor.reset()
        #expect(processor.process(signal, gainDB: 3) == reference)
    }

    @Test func syncDuringPartialFramePreservesBytesAndAppliesAtNextFrame() {
        let pipeline = ATVVAudioDecoder()
        let reference = IMAADPCMDecoder()
        let smoothing = PCMPostprocessor()
        let first = Data(repeating: 0x11, count: 120)
        let second = Data(repeating: 0x22, count: 120)
        #expect(pipeline.append(first.prefix(40), frameSize: 120, gainDB: 0).isEmpty)
        pipeline.synchronize(predictor: 1000, stepIndex: 10)
        #expect(pipeline.pendingByteCount == 40)
        let expectedFirst = smoothing.process(reference.decode(first), gainDB: 0)
        reference.reset(predictor: 1000, stepIndex: 10)
        let expectedSecond = smoothing.process(reference.decode(second), gainDB: 0)
        let actual = pipeline.append(first.dropFirst(40) + second, frameSize: 120, gainDB: 0)
        #expect(actual == [expectedFirst, expectedSecond])
        #expect(pipeline.pendingByteCount == 0)
        pipeline.reset()
        pipeline.synchronize(predictor: 1000, stepIndex: 10)
        reference.reset(predictor: 1000, stepIndex: 10)
        #expect(pipeline.append(first, frameSize: 120, gainDB: 0) == [PCMPostprocessor().process(reference.decode(first), gainDB: 0)])
    }

    @Test func frameAccumulatorPreservesPartialData() {
        var accumulator = FrameAccumulator()
        #expect(accumulator.append(Data([1, 2]), frameSize: 3).isEmpty)
        #expect(accumulator.pending == Data([1, 2]))

        let frames = accumulator.append(Data([3, 4, 5, 6, 7]), frameSize: 3)
        #expect(frames == [Data([1, 2, 3]), Data([4, 5, 6])])
        #expect(accumulator.pending == Data([7]))
    }

    @Test func frameAccumulatorHandlesRepeatedSlicedPacketsAndRebasesOutput() {
        let bytes = (0..<1003).map { UInt8($0 % 256) }
        let storage = Data([0xFF]) + Data(bytes)
        var accumulator = FrameAccumulator()
        var frames: [Data] = []
        for offset in stride(from: 0, to: bytes.count, by: 7) {
            let end = min(offset + 7, bytes.count)
            frames += accumulator.append(storage[(offset + 1)..<(end + 1)], frameSize: 120)
            #expect(accumulator.pending.startIndex == 0)
            #expect(accumulator.pending.count < 120)
        }
        #expect(frames.count == 8)
        #expect(frames.allSatisfy { $0.startIndex == 0 && $0.count == 120 })
        #expect(frames.reduce(into: Data()) { $0.append($1) } == Data(bytes.prefix(960)))
        #expect(accumulator.pending == Data(bytes.suffix(43)))

        // Invalid sizes must not ingest bytes or disturb a partial frame.
        #expect(accumulator.append(Data([0xFF]), frameSize: 0).isEmpty)
        #expect(accumulator.append(Data([0xFF]), frameSize: -1).isEmpty)
        #expect(accumulator.pending == Data(bytes.suffix(43)))
        accumulator.reset()
        #expect(accumulator.pending.isEmpty)
        #expect(accumulator.append(Data([1, 2, 3]), frameSize: 3) == [Data([1, 2, 3])])
        #expect(accumulator.pending.isEmpty)
        #expect(accumulator.pending.startIndex == 0)
    }

    @Test func commandVoiceJourneyFlushesPreRollBeforeRemainingAudioAndClearsOnStop() {
        var buffer = CommandVoiceActivationAudioBuffer(maximumSampleCount: 4)
        var routedSamples: [Int16] = []
        var events: [String] = []

        // STREAM_START → early AUDIO while the Command DOWN is pending.
        events.append("stream_start")
        buffer.begin()
        let bufferedEarlyAudio = buffer.appendIfWaiting([1, 2])
        events.append("early_audio_buffered")
        #expect(bufferedEarlyAudio)
        #expect(routedSamples.isEmpty)

        // Confirmed DOWN → session start → flush pre-roll → remaining AUDIO routes directly.
        events.append("command_down_confirmed")
        events.append("session_started")
        routedSamples.append(contentsOf: buffer.drain())
        events.append("pre_roll_routed")
        let bufferedRemainingAudio = buffer.appendIfWaiting([3, 4])
        #expect(!bufferedRemainingAudio)
        routedSamples.append(contentsOf: [3, 4])
        events.append("remaining_audio_routed")

        // STREAM_STOP leaves no buffered audio for a later session.
        buffer.cancel()
        events.append("stream_stop")
        #expect(routedSamples == [1, 2, 3, 4])
        #expect(buffer.drain().isEmpty)
        #expect(events == [
            "stream_start",
            "early_audio_buffered",
            "command_down_confirmed",
            "session_started",
            "pre_roll_routed",
            "remaining_audio_routed",
            "stream_stop"
        ])
    }

    @Test func commandActivationPreRollEnforcesCapacityAndCancellation() {
        var buffer = CommandVoiceActivationAudioBuffer(maximumSampleCount: 4)

        buffer.begin()
        let acceptedFirst = buffer.appendIfWaiting([1, 2])
        let acceptedSecond = buffer.appendIfWaiting([3, 4, 5])
        #expect(acceptedFirst)
        #expect(acceptedSecond)
        #expect(buffer.drain() == [2, 3, 4, 5])

        buffer.begin()
        let acceptedCancelled = buffer.appendIfWaiting([7, 8])
        #expect(acceptedCancelled)
        buffer.cancel()
        #expect(buffer.drain().isEmpty)
    }
}

@Suite("Bluetooth voice tail diagnostics")
struct BluetoothVoiceTailDiagnosticsTests {
    @Test func keepsOnlyTheLatestThreeHundredMillisecondsWithoutAudioContentLogging() {
        var diagnostics = BluetoothVoiceTailDiagnostics()
        diagnostics.append(Array(repeating: 1, count: 4_000), at: 10)
        diagnostics.append(Array(repeating: 2, count: 2_000), at: 10.25)

        let snapshot = diagnostics.snapshot(at: 10.30)

        #expect(snapshot.sampleCount == 4_800)
        #expect(snapshot.durationMilliseconds == 300)
        #expect(snapshot.nonZeroSampleCount == 4_800)
        #expect(snapshot.peak == 2)
        #expect(snapshot.rms == 1)
        #expect(snapshot.finalWindowSampleCount == 1_600)
        #expect(snapshot.finalWindowDurationMilliseconds == 100)
        #expect(snapshot.finalWindowNonZeroSampleCount == 1_600)
        #expect(snapshot.finalWindowPeak == 2)
        #expect(snapshot.finalWindowRMS == 2)
        #expect(snapshot.lastAudioAgeMilliseconds == 50)
    }

    @Test func distinguishesTheFinalHundredMillisecondsFromEarlierTailSignal() {
        var diagnostics = BluetoothVoiceTailDiagnostics()
        diagnostics.append(Array(repeating: 10, count: 3_200), at: 10)
        diagnostics.append(Array(repeating: 0, count: 1_600), at: 10.20)

        let snapshot = diagnostics.snapshot(at: 10.30)

        #expect(snapshot.peak == 10)
        #expect(snapshot.nonZeroSampleCount == 3_200)
        #expect(snapshot.finalWindowSampleCount == 1_600)
        #expect(snapshot.finalWindowNonZeroSampleCount == 0)
        #expect(snapshot.finalWindowPeak == 0)
        #expect(snapshot.finalWindowRMS == 0)
    }

    @Test func tailRingPreservesLatestSignalAndFinalWindowAcrossManyWraps() {
        var diagnostics = BluetoothVoiceTailDiagnostics()
        var allSamples: [Int16] = []
        for batch in 0..<250 {
            let samples = Array(repeating: Int16(batch - 125), count: 241)
            allSamples += samples
            diagnostics.append(samples, at: Double(batch))
        }
        var expected = VoiceAudioSignalMetrics()
        expected.append(Array(allSamples.suffix(4800)))
        var final = VoiceAudioSignalMetrics()
        final.append(Array(allSamples.suffix(1600)))
        let result = diagnostics.snapshot(at: 250)
        #expect(result.sampleCount == 4800)
        #expect(result.nonZeroSampleCount == expected.nonZeroSampleCount)
        #expect(result.peak == expected.peak)
        #expect(result.rms == expected.rms)
        #expect(result.finalWindowRMS == final.rms)
        #expect(result.finalWindowPeak == final.peak)
        #expect(result.lastAudioAgeMilliseconds == 1000)
    }

    @Test func resetRemovesPriorSessionSignalAndTiming() {
        var diagnostics = BluetoothVoiceTailDiagnostics()
        diagnostics.append([1, 2, 3], at: 10)
        diagnostics.reset()

        let snapshot = diagnostics.snapshot(at: 20)

        #expect(snapshot.sampleCount == 0)
        #expect(snapshot.durationMilliseconds == 0)
        #expect(snapshot.finalWindowSampleCount == 0)
        #expect(snapshot.finalWindowDurationMilliseconds == 0)
        #expect(snapshot.lastAudioAgeMilliseconds == nil)
    }
}
