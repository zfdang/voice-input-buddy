import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Long recording startup cancellation")
@MainActor
struct LongRecordingStartupTests {
    @Test func cancelledRequestCannotBeReopenedByLateAudioStartup() throws {
        let name = UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values), initialAudioDevices: [])
        model.longRecordingRequested = true
        model.longRecordingGeneration = 12
        model.stopLongRecording(reason: "button_toggle")
        #expect(!model.startLongRecordingAfterAudioReady(true, generation: 12))
        #expect(!model.longRecordingRequested)
        model.longRecordingRequested = true
        #expect(!model.startLongRecordingAfterAudioReady(false, generation: model.longRecordingGeneration))
        #expect(!model.longRecordingRequested)
    }
}
