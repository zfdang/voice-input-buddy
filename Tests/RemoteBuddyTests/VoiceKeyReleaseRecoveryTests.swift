import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Voice key release recovery")
@MainActor
struct VoiceKeyReleaseRecoveryTests {
    @Test func failedDisconnectReleaseRetriesWithoutAnotherDeviceEvent() throws {
        let name = "voice-release-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        let clock = ControlledTestScheduler()
        model.scheduleVoiceKeyReleaseRetry = clock.voiceSchedule
        _ = model.voiceKeyLatch.transition(streaming: true, owner: .bluetooth)
        model.heldVoiceKeyMode = .leftCommand
        var attempts = 0
        #expect(!model.releaseVoiceKeyIfNeeded { _ in attempts += 1; return attempts >= 3 })
        let old = try #require(clock.tasks.first)
        #expect(!model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, _ in Issue.record("Cleanup must finish before another press"); return true }))
        clock.runNext()
        #expect(model.voiceKeyLatch.isHeld)
        clock.runNext()
        #expect(!model.voiceKeyLatch.isHeld)
        #expect(model.heldVoiceKeyMode == nil)
        #expect(attempts == 3)
        old.fire(includingCancelled: true)
        #expect(attempts == 3)
        #expect(clock.activeCount == 0)
    }
}
