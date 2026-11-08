import Foundation
import Testing
@testable import RemoteBuddy
@Suite("Voice source exclusion") @MainActor
struct VoiceSourceExclusionTests {
    @Test func pendingReleaseBlocksAnotherVoiceStart() throws {
        let suite = "voice-exclusion-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: suite))
        defer { values.removePersistentDomain(forName: suite) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        #expect(model.canAcceptNewVoiceSession(from: .bluetooth))
        model.voiceKeyReleaseRetry = ScheduledOperation {}
        #expect(!model.canAcceptNewVoiceSession(from: .bluetooth))
        model.voiceKeyReleaseRetry = nil
        #expect(model.canAcceptNewVoiceSession(from: .bluetooth))
    }
}
