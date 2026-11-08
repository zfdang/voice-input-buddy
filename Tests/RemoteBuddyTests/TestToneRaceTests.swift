import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Test tone configuration race")
@MainActor
struct TestToneRaceTests {
    @Test(arguments: [false, true])
    func voiceWinsBeforeTheAudioReadyCallback(streaming: Bool) throws {
        let name = "test-tone-race-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let device = AudioDeviceInfo(id: 123, uid: BuddyMicrophoneDevicePolicy.deviceUID, name: "Test")
        let model = BridgeAppModel(settings: AppSettings(defaults: values), initialAudioDevices: [device])
        model.isStreaming = streaming
        model.voiceSession.isActive = !streaming
        let generation = model.testToneGeneration
        model.startTestToneAfterAudioReady(true)
        #expect(model.testToneGeneration == generation)
        #expect(!model.isPlayingTestTone)
        #expect(model.testToneStatus.key == "audio.test_tone.blocked_voice_active")
    }
}
