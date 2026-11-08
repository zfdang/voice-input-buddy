import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Session and input integration") @MainActor
struct SessionInputIntegrationTests {
    @Test func deactivationDuringInputSourceActivationCannotPostFnAndRequiresAllResumeEvents() throws {
        let name = "session-integration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.setOnboardingVoiceTool(.weixin)
        settings.voiceKeyMode = .function
        let model = BridgeAppModel(settings: settings)
        var source = "previous"
        var posts: [Bool] = []
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin }, prepareInputSource: { _ in .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            waitForInputSourceActivation: { target, _, _, done in
                source = target
                model.handleSystemAudioLifecycle(.sessionDidResignActive)
                model.handleSystemAudioLifecycle(.screenDidSleep)
                done(true) // The external activation succeeded after suspension.
            }, installMonitor: { _ in nil }, logger: { _ in })
        let started = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, down in posts.append(down); return true })
        #expect(!started)
        #expect(posts.isEmpty)
        #expect(!model.voiceKeyLatch.isHeld)
        model.handleSystemAudioLifecycle(.screenDidWake)
        #expect(!model.canAcceptNewVoiceSession(from: .bluetooth))
        #expect(!model.performInternalAction(.openCommonPhrases))
        model.handleSystemAudioLifecycle(.sessionDidBecomeActive)
        #expect(model.canAcceptNewVoiceSession(from: .bluetooth))
        #expect(!model.voiceKeyActivationInProgress)
    }
}
