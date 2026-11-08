import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Device audio format lifetime")
struct AudioFormatLifetimeTests {
    @Test func arn9FormatSurvivesStreamResetAndSyncButNotPeripheralReset() {
        let decoder = ATVVAudioDecoder()
        decoder.configureFormat(lowNibbleFirst: true)
        #expect(decoder.beginStream())
        decoder.reset()
        #expect(decoder.beginStream())
        decoder.synchronize(predictor: 0, stepIndex: 0)
        let bytes = Data([0x12, 0x34, 0x56])
        let reference = ATVVAudioDecoder()
        reference.configureFormat(lowNibbleFirst: true)
        #expect(decoder.append(bytes, frameSize: 3, gainDB: 0) == reference.append(bytes, frameSize: 3, gainDB: 0))
        decoder.resetPeripheral()
        #expect(decoder.beginStream())
        let high = ATVVAudioDecoder()
        #expect(decoder.append(bytes, frameSize: 3, gainDB: 0) == high.append(bytes, frameSize: 3, gainDB: 0))
        decoder.configureFormat(lowNibbleFirst: true)
        decoder.configureFormat(lowNibbleFirst: false)
        decoder.reset()
        let newHigh = ATVVAudioDecoder()
        #expect(decoder.append(bytes, frameSize: 3, gainDB: 0) == newHigh.append(bytes, frameSize: 3, gainDB: 0))
    }
}
