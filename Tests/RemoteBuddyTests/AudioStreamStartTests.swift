import Foundation
import Testing
@testable import RemoteBuddy

@Suite("ATVV stream start ordering")
struct AudioStreamStartTests {
    @Test func onlyDistinctExplicitIdentifiersReplaceAnActiveStream() {
        #expect(!ATVVStreamStartPolicy.shouldReplaceStream(isStreaming: true, activeSessionID: nil, incomingSessionID: 7))
        #expect(!ATVVStreamStartPolicy.shouldReplaceStream(isStreaming: true, activeSessionID: 7, incomingSessionID: 7))
        #expect(!ATVVStreamStartPolicy.shouldReplaceStream(isStreaming: true, activeSessionID: 7, incomingSessionID: nil))
        #expect(!ATVVStreamStartPolicy.shouldReplaceStream(isStreaming: false, activeSessionID: 7, incomingSessionID: 8))
        #expect(ATVVStreamStartPolicy.shouldReplaceStream(isStreaming: true, activeSessionID: 7, incomingSessionID: 8))
    }

    @Test func lateControlStartPreservesPartialFramesPredictorAndFilterHistory() {
        let decoder = ATVVAudioDecoder()
        let reference = ATVVAudioDecoder()
        #expect(decoder.beginStream())
        #expect(reference.beginStream())
        let first = Data(repeating: 0x37, count: 120)
        #expect(decoder.append(first, frameSize: 120, gainDB: 0) == reference.append(first, frameSize: 120, gainDB: 0))
        let partial = Data(repeating: 0x24, count: 37)
        #expect(decoder.append(partial, frameSize: 120, gainDB: 0).isEmpty)
        _ = reference.append(partial, frameSize: 120, gainDB: 0)
        #expect(!decoder.beginStream()) // late or duplicate 0x04
        #expect(decoder.pendingByteCount == 37)
        let tail = Data(repeating: 0x56, count: 83)
        #expect(decoder.append(tail, frameSize: 120, gainDB: 0) == reference.append(tail, frameSize: 120, gainDB: 0))
        decoder.reset()
        #expect(decoder.beginStream())
        let clean = ATVVAudioDecoder()
        #expect(clean.beginStream())
        #expect(decoder.append(first, frameSize: 120, gainDB: 0) == clean.append(first, frameSize: 120, gainDB: 0))
    }
}
