import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Inactive session input isolation") @MainActor
struct InactiveSessionInputTests {
    @Test(arguments: [SystemAudioLifecycleEvent.sessionDidResignActive, .screenDidSleep, .systemWillSleep])
    func suspensionRejectsNewInputAndAllowsKeyCleanup(event: SystemAudioLifecycleEvent) throws {
        let suite = "inactive-input-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BridgeAppModel(settings: AppSettings(defaults: defaults))
        var edges: [Bool] = []
        #expect(model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, down in edges.append(down); return true }))
        model.audio.suspensionState.apply(event)
        #expect(!model.canAcceptNewVoiceSession(from: .bluetooth))
        #expect(!model.performExternalConfiguredAction(.init(action: .arrowRight, shortcut: nil)))
        #expect(!model.performInternalAction(.openCommonPhrases))
        #expect(model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, down in edges.append(down); return true }))
        #expect(!model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, down in edges.append(down); return true }))
        #expect(edges == [true, false])
        let resume: SystemAudioLifecycleEvent = event == .sessionDidResignActive ? .sessionDidBecomeActive
            : (event == .screenDidSleep ? .screenDidWake : .systemDidWake)
        model.audio.suspensionState.apply(resume)
        #expect(model.canAcceptNewVoiceSession(from: .bluetooth))
    }
}
